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
  WHERE p.id = p_actor_id;

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
  WHERE p.id = v_before.user_id;

  IF NOT FOUND OR v_target_blocked IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'No se puede asignar un rol a una cuenta inexistente o bloqueada globalmente.'
      USING ERRCODE = '42501';
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
  WHERE p.id = p_actor_id;

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
  WHERE p.id = p_actor_id;

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
