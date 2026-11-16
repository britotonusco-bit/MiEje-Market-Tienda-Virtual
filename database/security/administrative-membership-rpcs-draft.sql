-- MiEje Market
-- Borrador NO aplicado: operaciones transaccionales de membresías administrativas.
-- Rama: correcciones-funcionales
-- Requiere revisión final y entorno aislado antes de ejecutar.
--
-- Orden previsto:
-- 1) Aplicar/revisar database/security/business-admin-boundaries.sql
-- 2) Aplicar este archivo para añadir job_title y crear las RPC.
-- 3) Adaptar technical-business-management/index.ts para invocar estas RPC.
--
-- Este archivo no envía correos ni realiza cambios en Supabase mientras permanezca
-- en GitHub como borrador.

-- La Edge Function ya lee/escribe job_title, pero la tabla inspeccionada en el
-- proyecto independiente todavía no contiene esa columna.
ALTER TABLE public.business_memberships
  ADD COLUMN IF NOT EXISTS job_title text;

COMMENT ON COLUMN public.business_memberships.job_title IS
  'Cargo descriptivo de la persona dentro del negocio; no sustituye el rol de acceso.';


-- Cambiar rol/cargo con bloqueo del negocio, validación de último administrador
-- y auditoría en una sola transacción.
CREATE OR REPLACE FUNCTION public.update_business_membership_assignment(
  p_membership_id uuid,
  p_role text,
  p_job_title text,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_business_id uuid;
  v_business_status text;
  v_actor_role text;
  v_actor_blocked boolean;
  v_target_blocked boolean;
  v_before public.business_memberships%ROWTYPE;
  v_after public.business_memberships%ROWTYPE;
  v_remaining_admins integer;
  v_job_title text := NULLIF(pg_catalog.btrim(p_job_title), '');
BEGIN
  IF p_membership_id IS NULL OR p_actor_id IS NULL
     OR p_role IS NULL OR p_role NOT IN ('business_admin', 'employee')
     OR v_job_title IS NULL OR pg_catalog.char_length(v_job_title) < 2
     OR pg_catalog.char_length(v_job_title) > 100 THEN
    RAISE EXCEPTION 'Datos de asignación no válidos.' USING ERRCODE = '22023';
  END IF;

  SELECT p.platform_role, p.is_blocked
    INTO v_actor_role, v_actor_blocked
  FROM public.profiles AS p
  WHERE p.id = p_actor_id
  FOR SHARE;

  IF NOT FOUND OR v_actor_role IS DISTINCT FROM 'platform_owner'
     OR v_actor_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Actor técnico no autorizado.' USING ERRCODE = '42501';
  END IF;

  -- Lectura inicial solo para descubrir el negocio; todavía no bloquea la membresía.
  SELECT m.business_id INTO v_business_id
  FROM public.business_memberships AS m
  WHERE m.id = p_membership_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la membresía.' USING ERRCODE = 'P0002';
  END IF;

  -- Orden global de bloqueo: negocio primero, membresía después.
  SELECT b.status INTO v_business_status
  FROM public.businesses AS b
  WHERE b.id = v_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el negocio de la membresía.' USING ERRCODE = 'P0002';
  END IF;

  SELECT m.* INTO v_before
  FROM public.business_memberships AS m
  WHERE m.id = p_membership_id
    AND m.business_id = v_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La membresía cambió durante la operación.' USING ERRCODE = '40001';
  END IF;

  SELECT p.is_blocked INTO v_target_blocked
  FROM public.profiles AS p
  WHERE p.id = v_before.user_id
  FOR SHARE;

  IF NOT FOUND OR v_target_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'No se puede asignar un rol a una cuenta inexistente o bloqueada globalmente.'
      USING ERRCODE = '42501';
  END IF;

  IF v_before.role IS NOT DISTINCT FROM p_role
     AND v_before.job_title IS NOT DISTINCT FROM v_job_title THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', true,
      'unchanged', true,
      'membership', pg_catalog.jsonb_build_object(
        'id', v_before.id,
        'business_id', v_before.business_id,
        'user_id', v_before.user_id,
        'role', v_before.role,
        'status', v_before.status,
        'job_title', v_before.job_title
      )
    );
  END IF;

  IF v_before.role = 'business_admin'
     AND v_before.status = 'active'
     AND p_role <> 'business_admin' THEN
    SELECT pg_catalog.count(*)::integer INTO v_remaining_admins
    FROM public.business_memberships AS m
    WHERE m.business_id = v_business_id
      AND m.role = 'business_admin'
      AND m.status = 'active'
      AND m.id <> v_before.id;

    IF v_remaining_admins = 0 THEN
      RAISE EXCEPTION 'No se puede retirar el rol del último administrador activo.'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  UPDATE public.business_memberships
  SET role = p_role,
      job_title = v_job_title
  WHERE id = v_before.id
  RETURNING * INTO v_after;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_business_id,
    p_actor_id,
    'business.member_assignment_updated',
    'business_membership',
    v_after.id::text,
    pg_catalog.jsonb_build_object(
      'target_user_id', v_after.user_id,
      'previous_role', v_before.role,
      'role', v_after.role,
      'previous_job_title', v_before.job_title,
      'job_title', v_after.job_title,
      'business_status_at_change', v_business_status
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'membership', pg_catalog.jsonb_build_object(
      'id', v_after.id,
      'business_id', v_after.business_id,
      'user_id', v_after.user_id,
      'role', v_after.role,
      'status', v_after.status,
      'job_title', v_after.job_title
    )
  );
END;
$function$;


-- Suspender una membresía sin permitir que el negocio pierda su último administrador.
CREATE OR REPLACE FUNCTION public.suspend_business_membership(
  p_membership_id uuid,
  p_reason text,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_business_id uuid;
  v_actor_role text;
  v_actor_blocked boolean;
  v_before public.business_memberships%ROWTYPE;
  v_after public.business_memberships%ROWTYPE;
  v_remaining_admins integer;
  v_reason text := NULLIF(pg_catalog.btrim(p_reason), '');
BEGIN
  IF p_membership_id IS NULL OR p_actor_id IS NULL
     OR v_reason IS NULL OR pg_catalog.char_length(v_reason) > 2000 THEN
    RAISE EXCEPTION 'La membresía, el actor y un motivo válido son obligatorios.'
      USING ERRCODE = '22023';
  END IF;

  SELECT p.platform_role, p.is_blocked
    INTO v_actor_role, v_actor_blocked
  FROM public.profiles AS p
  WHERE p.id = p_actor_id
  FOR SHARE;

  IF NOT FOUND OR v_actor_role IS DISTINCT FROM 'platform_owner'
     OR v_actor_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Actor técnico no autorizado.' USING ERRCODE = '42501';
  END IF;

  SELECT m.business_id INTO v_business_id
  FROM public.business_memberships AS m
  WHERE m.id = p_membership_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la membresía.' USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1
  FROM public.businesses AS b
  WHERE b.id = v_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el negocio de la membresía.' USING ERRCODE = 'P0002';
  END IF;

  SELECT m.* INTO v_before
  FROM public.business_memberships AS m
  WHERE m.id = p_membership_id
    AND m.business_id = v_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La membresía cambió durante la operación.' USING ERRCODE = '40001';
  END IF;

  IF v_before.status = 'suspended' THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', true,
      'already_suspended', true,
      'membership', pg_catalog.jsonb_build_object(
        'id', v_before.id, 'business_id', v_before.business_id,
        'user_id', v_before.user_id, 'role', v_before.role,
        'status', v_before.status, 'job_title', v_before.job_title
      )
    );
  END IF;

  IF v_before.role = 'business_admin' AND v_before.status = 'active' THEN
    SELECT pg_catalog.count(*)::integer INTO v_remaining_admins
    FROM public.business_memberships AS m
    WHERE m.business_id = v_business_id
      AND m.role = 'business_admin'
      AND m.status = 'active'
      AND m.id <> v_before.id;

    IF v_remaining_admins = 0 THEN
      RAISE EXCEPTION 'No se puede suspender al último administrador activo del negocio.'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  UPDATE public.business_memberships
  SET status = 'suspended',
      blocked_reason = v_reason
  WHERE id = v_before.id
  RETURNING * INTO v_after;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_business_id,
    p_actor_id,
    'business.member_suspended',
    'business_membership',
    v_after.id::text,
    pg_catalog.jsonb_build_object(
      'target_user_id', v_after.user_id,
      'role', v_after.role,
      'reason', v_reason,
      'previous_status', v_before.status,
      'status', v_after.status
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'membership', pg_catalog.jsonb_build_object(
      'id', v_after.id, 'business_id', v_after.business_id,
      'user_id', v_after.user_id, 'role', v_after.role,
      'status', v_after.status, 'job_title', v_after.job_title
    )
  );
END;
$function$;


-- Reactivar solo si el negocio sigue activo y el perfil global no está bloqueado.
CREATE OR REPLACE FUNCTION public.reactivate_business_membership(
  p_membership_id uuid,
  p_reason text,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_business_id uuid;
  v_business_status text;
  v_actor_role text;
  v_actor_blocked boolean;
  v_target_blocked boolean;
  v_before public.business_memberships%ROWTYPE;
  v_after public.business_memberships%ROWTYPE;
  v_reason text := NULLIF(pg_catalog.btrim(p_reason), '');
BEGIN
  IF p_membership_id IS NULL OR p_actor_id IS NULL
     OR v_reason IS NULL OR pg_catalog.char_length(v_reason) < 5
     OR pg_catalog.char_length(v_reason) > 2000 THEN
    RAISE EXCEPTION 'La membresía, el actor y un motivo válido (mínimo 5 caracteres) son obligatorios.'
      USING ERRCODE = '22023';
  END IF;

  SELECT p.platform_role, p.is_blocked
    INTO v_actor_role, v_actor_blocked
  FROM public.profiles AS p
  WHERE p.id = p_actor_id
  FOR SHARE;

  IF NOT FOUND OR v_actor_role IS DISTINCT FROM 'platform_owner'
     OR v_actor_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Actor técnico no autorizado.' USING ERRCODE = '42501';
  END IF;

  SELECT m.business_id INTO v_business_id
  FROM public.business_memberships AS m
  WHERE m.id = p_membership_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la membresía.' USING ERRCODE = 'P0002';
  END IF;

  SELECT b.status INTO v_business_status
  FROM public.businesses AS b
  WHERE b.id = v_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el negocio de la membresía.' USING ERRCODE = 'P0002';
  END IF;

  IF v_business_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Primero debes reactivar el negocio; no se puede activar una membresía en un negocio suspendido o cerrado.'
      USING ERRCODE = '23514';
  END IF;

  SELECT m.* INTO v_before
  FROM public.business_memberships AS m
  WHERE m.id = p_membership_id
    AND m.business_id = v_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La membresía cambió durante la operación.' USING ERRCODE = '40001';
  END IF;

  SELECT p.is_blocked INTO v_target_blocked
  FROM public.profiles AS p
  WHERE p.id = v_before.user_id;

  IF NOT FOUND OR v_target_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'No se puede reactivar una cuenta inexistente o bloqueada globalmente.'
      USING ERRCODE = '42501';
  END IF;

  IF v_before.status = 'active' THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', true,
      'already_active', true,
      'membership', pg_catalog.jsonb_build_object(
        'id', v_before.id, 'business_id', v_before.business_id,
        'user_id', v_before.user_id, 'role', v_before.role,
        'status', v_before.status, 'job_title', v_before.job_title
      )
    );
  END IF;

  UPDATE public.business_memberships
  SET status = 'active',
      blocked_reason = NULL
  WHERE id = v_before.id
  RETURNING * INTO v_after;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_business_id,
    p_actor_id,
    'business.member_reactivated',
    'business_membership',
    v_after.id::text,
    pg_catalog.jsonb_build_object(
      'target_user_id', v_after.user_id,
      'role', v_after.role,
      'reason', v_reason,
      'previous_status', v_before.status,
      'status', v_after.status
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'membership', pg_catalog.jsonb_build_object(
      'id', v_after.id, 'business_id', v_after.business_id,
      'user_id', v_after.user_id, 'role', v_after.role,
      'status', v_after.status, 'job_title', v_after.job_title
    )
  );
END;
$function$;


-- Las RPC solo se invocarán desde la Edge Function usando service_role.
REVOKE ALL ON FUNCTION public.update_business_membership_assignment(uuid, text, text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.suspend_business_membership(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reactivate_business_membership(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.update_business_membership_assignment(uuid, text, text, uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.suspend_business_membership(uuid, text, uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.reactivate_business_membership(uuid, text, uuid)
  TO service_role;

-- FIN DEL BORRADOR. No ejecutar en el proyecto activo sin staging y revisión.



-- Cambiar el estado de un negocio y auditar el cambio en la misma transacción.
CREATE OR REPLACE FUNCTION public.set_technical_business_status(
  p_business_id uuid,
  p_status text,
  p_reason text,
  p_public_message text,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_actor_role text;
  v_actor_blocked boolean;
  v_before public.businesses%ROWTYPE;
  v_after public.businesses%ROWTYPE;
  v_reason text := NULLIF(pg_catalog.btrim(p_reason), '');
  v_public_message text := NULLIF(pg_catalog.btrim(p_public_message), '');
BEGIN
  IF p_business_id IS NULL OR p_actor_id IS NULL
     OR p_status IS NULL
     OR p_status NOT IN ('active', 'suspended', 'closed')
     OR (p_status = 'suspended' AND v_reason IS NULL)
     OR pg_catalog.char_length(COALESCE(v_reason, '')) > 2000
     OR pg_catalog.char_length(COALESCE(v_public_message, '')) > 1000 THEN
    RAISE EXCEPTION 'Datos de estado del negocio no válidos.'
      USING ERRCODE = '22023';
  END IF;

  SELECT p.platform_role, p.is_blocked
    INTO v_actor_role, v_actor_blocked
  FROM public.profiles AS p
  WHERE p.id = p_actor_id
  FOR SHARE;

  IF NOT FOUND OR v_actor_role IS DISTINCT FROM 'platform_owner'
     OR v_actor_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Actor técnico no autorizado.'
      USING ERRCODE = '42501';
  END IF;

  SELECT b.* INTO v_before
  FROM public.businesses AS b
  WHERE b.id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el negocio.'
      USING ERRCODE = 'P0002';
  END IF;

  IF p_status = 'suspended' THEN
    v_public_message := COALESCE(
      v_public_message,
      'Este negocio está temporalmente suspendido.'
    );
  ELSE
    v_reason := NULL;
    v_public_message := NULL;
  END IF;

  IF v_before.status IS NOT DISTINCT FROM p_status
     AND v_before.suspension_reason IS NOT DISTINCT FROM v_reason
     AND v_before.public_suspension_message IS NOT DISTINCT FROM v_public_message THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', true,
      'unchanged', true,
      'business', pg_catalog.jsonb_build_object(
        'id', v_before.id,
        'name', v_before.name,
        'slug', v_before.slug,
        'status', v_before.status,
        'suspension_reason', v_before.suspension_reason,
        'public_suspension_message', v_before.public_suspension_message
      )
    );
  END IF;

  UPDATE public.businesses
  SET status = p_status,
      suspension_reason = v_reason,
      public_suspension_message = v_public_message
  WHERE id = p_business_id
  RETURNING * INTO v_after;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    p_business_id,
    p_actor_id,
    'business.status_changed',
    'business',
    p_business_id::text,
    pg_catalog.jsonb_build_object(
      'previous_status', v_before.status,
      'new_status', v_after.status,
      'previous_reason', v_before.suspension_reason,
      'reason', v_after.suspension_reason,
      'previous_public_message', v_before.public_suspension_message,
      'public_message', v_after.public_suspension_message
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'unchanged', false,
    'business', pg_catalog.jsonb_build_object(
      'id', v_after.id,
      'name', v_after.name,
      'slug', v_after.slug,
      'status', v_after.status,
      'suspension_reason', v_after.suspension_reason,
      'public_suspension_message', v_after.public_suspension_message
    )
  );
END;
$function$;


-- Moderar contenido con bloqueo de fila y auditoría atómica.
CREATE OR REPLACE FUNCTION public.moderate_business_content_transactionally(
  p_content_id uuid,
  p_decision text,
  p_moderation_note text,
  p_actor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_actor_role text;
  v_actor_blocked boolean;
  v_before public.business_content_pages%ROWTYPE;
  v_after public.business_content_pages%ROWTYPE;
  v_note text := NULLIF(pg_catalog.btrim(p_moderation_note), '');
BEGIN
  IF p_content_id IS NULL OR p_actor_id IS NULL
     OR p_decision IS NULL
     OR p_decision NOT IN ('approved', 'rejected')
     OR pg_catalog.char_length(COALESCE(v_note, '')) > 2000 THEN
    RAISE EXCEPTION 'Datos de moderación no válidos.'
      USING ERRCODE = '22023';
  END IF;

  SELECT p.platform_role, p.is_blocked
    INTO v_actor_role, v_actor_blocked
  FROM public.profiles AS p
  WHERE p.id = p_actor_id
  FOR SHARE;

  IF NOT FOUND OR v_actor_role IS DISTINCT FROM 'platform_owner'
     OR v_actor_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Actor técnico no autorizado.'
      USING ERRCODE = '42501';
  END IF;

  SELECT c.* INTO v_before
  FROM public.business_content_pages AS c
  WHERE c.id = p_content_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la publicación.'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_before.moderation_status = p_decision
     AND v_before.moderation_note IS NOT DISTINCT FROM v_note
     AND (p_decision <> 'rejected' OR v_before.is_published = false) THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', true,
      'unchanged', true,
      'content', pg_catalog.jsonb_build_object(
        'id', v_before.id,
        'business_id', v_before.business_id,
        'title', v_before.title,
        'content_type', v_before.content_type,
        'is_published', v_before.is_published,
        'moderation_status', v_before.moderation_status,
        'moderation_note', v_before.moderation_note,
        'moderated_at', v_before.moderated_at
      )
    );
  END IF;

  UPDATE public.business_content_pages
  SET moderation_status = p_decision,
      moderation_note = v_note,
      moderated_by = p_actor_id,
      moderated_at = pg_catalog.now(),
      is_published = CASE
        WHEN p_decision = 'rejected' THEN false
        ELSE is_published
      END
  WHERE id = p_content_id
  RETURNING * INTO v_after;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_after.business_id,
    p_actor_id,
    CASE
      WHEN p_decision = 'approved' THEN 'business.content_approved'
      ELSE 'business.content_rejected'
    END,
    'business_content_page',
    v_after.id::text,
    pg_catalog.jsonb_build_object(
      'title', v_after.title,
      'content_type', v_after.content_type,
      'previous_moderation_status', v_before.moderation_status,
      'moderation_status', v_after.moderation_status,
      'previous_is_published', v_before.is_published,
      'is_published', v_after.is_published,
      'moderation_note', v_after.moderation_note
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'unchanged', false,
    'content', pg_catalog.jsonb_build_object(
      'id', v_after.id,
      'business_id', v_after.business_id,
      'title', v_after.title,
      'content_type', v_after.content_type,
      'is_published', v_after.is_published,
      'moderation_status', v_after.moderation_status,
      'moderation_note', v_after.moderation_note,
      'moderated_at', v_after.moderated_at
    )
  );
END;
$function$;


REVOKE ALL ON FUNCTION public.set_technical_business_status(uuid, text, text, text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderate_business_content_transactionally(uuid, text, text, uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.set_technical_business_status(uuid, text, text, text, uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.moderate_business_content_transactionally(uuid, text, text, uuid)
  TO service_role;
