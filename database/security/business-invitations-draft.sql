-- MiEje Market — invitaciones individuales y onboarding seguro
-- BORRADOR: ejecutar solo en un proyecto de ensayo después de revisar el paquete completo.
-- No aplicar en Supabase activo desde esta auditoría.
--
-- Diseño:
-- 1) Cada invitación tiene un token aleatorio generado por la Edge Function.
--    En esta tabla solo se almacena SHA-256(token), nunca el token original.
-- 2) La membresía se crea como suspended con una marca interna exacta hasta
--    que el servidor confirme la aceptación. has_business_role debe exigir
--    status='active', por lo que esta membresía no concede acceso.
-- 3) Solo service_role puede operar estas tablas/RPC. La Edge Function valida
--    JWT, identidad, email confirmado y MFA del técnico antes de llamar RPC.
-- 4) La aceptación/revocación bloquean primero el negocio y luego la invitación,
--    para serializarse y proteger el último administrador activo.

CREATE TABLE IF NOT EXISTS public.business_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  membership_id uuid NULL REFERENCES public.business_memberships(id) ON DELETE SET NULL,
  user_id uuid NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
  email_normalized text NOT NULL
    CHECK (email_normalized = lower(btrim(email_normalized))
      AND char_length(email_normalized) BETWEEN 5 AND 254),
  role text NOT NULL CHECK (role IN ('business_admin','employee')),
  job_title text NOT NULL CHECK (char_length(btrim(job_title)) BETWEEN 2 AND 100),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','accepted','revoked','expired','failed')),
  token_hash text NOT NULL UNIQUE
    CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  accepted_at timestamptz NULL,
  revoked_at timestamptz NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_invitations_lifecycle_check CHECK (
    (status = 'accepted' AND accepted_at IS NOT NULL AND revoked_at IS NULL)
    OR (status = 'revoked' AND revoked_at IS NOT NULL AND accepted_at IS NULL)
    OR (status IN ('pending','expired','failed') AND accepted_at IS NULL AND revoked_at IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS business_invitations_one_pending_email_idx
  ON public.business_invitations (business_id, email_normalized)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS business_invitations_pending_expiry_idx
  ON public.business_invitations (expires_at)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS business_invitations_user_status_idx
  ON public.business_invitations (user_id, status)
  WHERE user_id IS NOT NULL;

ALTER TABLE public.business_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.business_invitations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.business_invitations TO service_role;

-- La marca evita confundir una membresía pendiente con una suspensión administrativa.
-- No se expone al cliente y solo se modifica desde las RPC de servicio.
CREATE OR REPLACE FUNCTION public.prepare_business_invitation(
  p_business_id uuid,
  p_email text,
  p_role text,
  p_job_title text,
  p_token_hash text,
  p_actor_id uuid,
  p_expires_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_business_status text;
  v_email text := pg_catalog.lower(pg_catalog.btrim(p_email));
  v_job_title text := pg_catalog.btrim(p_job_title);
  v_invitation public.business_invitations%ROWTYPE;
BEGIN
  IF p_business_id IS NULL OR p_actor_id IS NULL
     OR p_email IS NULL OR p_role IS NULL OR p_job_title IS NULL
     OR p_token_hash IS NULL OR p_expires_at IS NULL
     OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     OR p_role NOT IN ('business_admin','employee')
     OR pg_catalog.char_length(v_job_title) NOT BETWEEN 2 AND 100
     OR p_token_hash !~ '^[0-9a-f]{64}$'
     OR p_expires_at <= pg_catalog.now()
     OR p_expires_at > pg_catalog.now() + interval '7 days' THEN
    RAISE EXCEPTION 'Datos de invitación no válidos.' USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM public.profiles p
  WHERE p.id = p_actor_id
    AND p.platform_role = 'platform_owner'
    AND coalesce(p.is_blocked,false) = false
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Solo el propietario técnico puede crear invitaciones.'
      USING ERRCODE = '42501';
  END IF;

  SELECT b.status INTO v_business_status
  FROM public.businesses b
  WHERE b.id = p_business_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el negocio.' USING ERRCODE = 'P0002';
  END IF;
  IF v_business_status <> 'active' THEN
    RAISE EXCEPTION 'No se pueden invitar usuarios a un negocio inactivo.'
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.business_invitations (
    business_id, email_normalized, role, job_title,
    token_hash, created_by, expires_at
  ) VALUES (
    p_business_id, v_email, p_role, v_job_title,
    p_token_hash, p_actor_id, p_expires_at
  )
  RETURNING * INTO v_invitation;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    p_business_id, p_actor_id, 'business.invitation_created',
    'business_invitation', v_invitation.id::text,
    pg_catalog.jsonb_build_object(
      'email', v_email, 'role', p_role, 'expires_at', p_expires_at
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true, 'invitation_id', v_invitation.id, 'status', v_invitation.status
  );
END;
$function$;

-- Vincula la cuenta Auth devuelta por inviteUserByEmail con la invitación.
-- La membresía se crea suspendida y no concede permisos mientras está pendiente.
CREATE OR REPLACE FUNCTION public.attach_business_invitation_user(
  p_invitation_id uuid,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_business_id uuid;
  v_business_status text;
  v_invitation public.business_invitations%ROWTYPE;
  v_membership public.business_memberships%ROWTYPE;
BEGIN
  SELECT i.business_id INTO v_business_id
  FROM public.business_invitations i
  WHERE i.id = p_invitation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la invitación.' USING ERRCODE = 'P0002';
  END IF;

  SELECT b.status INTO v_business_status
  FROM public.businesses b
  WHERE b.id = v_business_id
  FOR UPDATE;
  IF NOT FOUND OR v_business_status <> 'active' THEN
    RAISE EXCEPTION 'El negocio no está activo.' USING ERRCODE = '23514';
  END IF;

  SELECT i.* INTO v_invitation
  FROM public.business_invitations i
  WHERE i.id = p_invitation_id AND i.business_id = v_business_id
  FOR UPDATE;
  IF NOT FOUND OR v_invitation.status <> 'pending'
     OR v_invitation.expires_at <= pg_catalog.now()
     OR v_invitation.user_id IS NOT NULL THEN
    RAISE EXCEPTION 'La invitación ya no está disponible para vincularse.'
      USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = p_user_id AND coalesce(p.is_blocked,false) = false
  ) THEN
    RAISE EXCEPTION 'La cuenta no tiene perfil válido o está bloqueada.'
      USING ERRCODE = '42501';
  END IF;

  SELECT m.* INTO v_membership
  FROM public.business_memberships m
  WHERE m.business_id = v_business_id AND m.user_id = p_user_id
  FOR UPDATE;

  IF FOUND THEN
    -- Solo se puede reutilizar una membresía suspendida por una invitación
    -- anterior/revocada/expirada; nunca una suspensión administrativa normal.
    IF v_membership.status <> 'suspended'
       OR v_membership.blocked_reason NOT IN (
         'Invitación pendiente de aceptación',
         'Invitación revocada'
       ) THEN
      RAISE EXCEPTION 'La cuenta ya tiene una membresía que no puede reutilizarse como invitación.'
        USING ERRCODE = '23505';
    END IF;

    UPDATE public.business_memberships
    SET role = v_invitation.role,
        job_title = v_invitation.job_title,
        status = 'suspended',
        blocked_reason = 'Invitación pendiente de aceptación',
        created_by = v_invitation.created_by
    WHERE id = v_membership.id
    RETURNING * INTO v_membership;
  ELSE
    INSERT INTO public.business_memberships (
      business_id, user_id, role, job_title, status, blocked_reason, created_by
    ) VALUES (
      v_business_id, p_user_id, v_invitation.role, v_invitation.job_title,
      'suspended', 'Invitación pendiente de aceptación', v_invitation.created_by
    )
    RETURNING * INTO v_membership;
  END IF;

  UPDATE public.business_invitations
  SET user_id = p_user_id, membership_id = v_membership.id, updated_at = pg_catalog.now()
  WHERE id = v_invitation.id;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_business_id, v_invitation.created_by, 'business.invitation_user_attached',
    'business_invitation', v_invitation.id::text,
    pg_catalog.jsonb_build_object(
      'target_user_id', p_user_id, 'membership_id', v_membership.id
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true, 'invitation_id', v_invitation.id,
    'membership_id', v_membership.id, 'status', 'pending'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_business_invitation_failed(
  p_invitation_id uuid,
  p_actor_id uuid,
  p_failure_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_invitation public.business_invitations%ROWTYPE;
BEGIN
  PERFORM 1 FROM public.profiles p
  WHERE p.id = p_actor_id AND p.platform_role = 'platform_owner'
    AND coalesce(p.is_blocked,false) = false
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Técnico no autorizado.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_invitation
  FROM public.business_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la invitación.' USING ERRCODE = 'P0002';
  END IF;
  IF v_invitation.status <> 'pending' OR v_invitation.user_id IS NOT NULL THEN
    RAISE EXCEPTION 'La invitación ya no puede marcarse como fallida.'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.business_invitations
  SET status = 'failed', updated_at = pg_catalog.now()
  WHERE id = v_invitation.id;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_invitation.business_id, p_actor_id, 'business.invitation_failed',
    'business_invitation', v_invitation.id::text,
    pg_catalog.jsonb_build_object('failure_code', pg_catalog.left(coalesce(p_failure_code,'unknown'),80))
  );

  RETURN pg_catalog.jsonb_build_object('ok', true, 'status', 'failed');
END;
$function$;

-- Solo la Edge Function de aceptación llama esta RPC después de validar el JWT,
-- el correo confirmado, la identidad y la contraseña mediante Auth Admin.
CREATE OR REPLACE FUNCTION public.accept_business_invitation(
  p_invitation_id uuid,
  p_user_id uuid,
  p_token_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_business_id uuid;
  v_business_status text;
  v_invitation public.business_invitations%ROWTYPE;
  v_membership public.business_memberships%ROWTYPE;
BEGIN
  IF p_invitation_id IS NULL OR p_user_id IS NULL OR p_token_hash IS NULL
     OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Datos de aceptación no válidos.' USING ERRCODE = '22023';
  END IF;

  SELECT i.business_id INTO v_business_id
  FROM public.business_invitations i
  WHERE i.id = p_invitation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitación no encontrada.' USING ERRCODE = 'P0002';
  END IF;

  SELECT b.status INTO v_business_status
  FROM public.businesses b
  WHERE b.id = v_business_id
  FOR UPDATE;
  IF NOT FOUND OR v_business_status <> 'active' THEN
    RAISE EXCEPTION 'El negocio no está activo; no se puede completar la invitación.'
      USING ERRCODE = '23514';
  END IF;

  SELECT i.* INTO v_invitation
  FROM public.business_invitations i
  WHERE i.id = p_invitation_id AND i.business_id = v_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_invitation.status <> 'pending'
     OR v_invitation.user_id IS DISTINCT FROM p_user_id
     OR v_invitation.token_hash IS DISTINCT FROM p_token_hash THEN
    RAISE EXCEPTION 'La invitación no corresponde a esta cuenta o ya no está pendiente.'
      USING ERRCODE = '42501';
  END IF;

  IF v_invitation.expires_at <= pg_catalog.now() THEN
    UPDATE public.business_invitations
    SET status = 'expired', updated_at = pg_catalog.now()
    WHERE id = v_invitation.id;
    INSERT INTO public.audit_logs (
      business_id, actor_id, action, entity_type, entity_id, details
    ) VALUES (
      v_business_id, p_user_id, 'business.invitation_expired',
      'business_invitation', v_invitation.id::text, '{}'::jsonb
    );
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 'expired');
  END IF;

  SELECT m.* INTO v_membership
  FROM public.business_memberships m
  WHERE m.id = v_invitation.membership_id
    AND m.business_id = v_business_id
    AND m.user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_membership.status <> 'suspended'
     OR v_membership.blocked_reason IS DISTINCT FROM 'Invitación pendiente de aceptación' THEN
    RAISE EXCEPTION 'La asignación pendiente fue modificada o revocada.'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.business_memberships
  SET status = 'active', blocked_reason = NULL
  WHERE id = v_membership.id
    AND status = 'suspended'
    AND blocked_reason = 'Invitación pendiente de aceptación';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se pudo activar la membresía pendiente.'
      USING ERRCODE = '40001';
  END IF;

  UPDATE public.business_invitations
  SET status = 'accepted', accepted_at = pg_catalog.now(), updated_at = pg_catalog.now()
  WHERE id = v_invitation.id;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_business_id, p_user_id, 'business.invitation_accepted',
    'business_invitation', v_invitation.id::text,
    pg_catalog.jsonb_build_object('membership_id', v_membership.id)
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true, 'status', 'accepted', 'business_id', v_business_id,
    'membership_id', v_membership.id
  );
END;
$function$;

-- Revoca únicamente la invitación/membresía de este negocio. Nunca elimina auth.users.
CREATE OR REPLACE FUNCTION public.revoke_business_invitation(
  p_invitation_id uuid,
  p_actor_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_business_id uuid;
  v_business_status text;
  v_invitation public.business_invitations%ROWTYPE;
  v_membership public.business_memberships%ROWTYPE;
  v_reason text := pg_catalog.btrim(p_reason);
BEGIN
  IF p_invitation_id IS NULL OR p_actor_id IS NULL OR p_reason IS NULL
     OR pg_catalog.char_length(v_reason) NOT BETWEEN 5 AND 1000 THEN
    RAISE EXCEPTION 'Invitación, técnico y motivo válido son obligatorios.'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM public.profiles p
  WHERE p.id = p_actor_id AND p.platform_role = 'platform_owner'
    AND coalesce(p.is_blocked,false) = false
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Solo el propietario técnico puede revocar invitaciones.'
      USING ERRCODE = '42501';
  END IF;

  SELECT i.business_id INTO v_business_id
  FROM public.business_invitations i
  WHERE i.id = p_invitation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la invitación.' USING ERRCODE = 'P0002';
  END IF;

  SELECT b.status INTO v_business_status
  FROM public.businesses b
  WHERE b.id = v_business_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el negocio.' USING ERRCODE = 'P0002';
  END IF;

  SELECT i.* INTO v_invitation
  FROM public.business_invitations i
  WHERE i.id = p_invitation_id AND i.business_id = v_business_id
  FOR UPDATE;

  IF NOT FOUND OR v_invitation.status <> 'pending' THEN
    RAISE EXCEPTION 'La invitación ya no está pendiente; no se realizaron cambios.'
      USING ERRCODE = '23514';
  END IF;

  IF v_invitation.membership_id IS NOT NULL THEN
    SELECT m.* INTO v_membership
    FROM public.business_memberships m
    WHERE m.id = v_invitation.membership_id
      AND m.business_id = v_business_id
      AND m.user_id = v_invitation.user_id
    FOR UPDATE;

    IF FOUND THEN
      IF v_membership.status <> 'suspended'
         OR v_membership.blocked_reason IS DISTINCT FROM 'Invitación pendiente de aceptación' THEN
        RAISE EXCEPTION 'La membresía ya no es una asignación pendiente; no se eliminó.'
          USING ERRCODE = '23514';
      END IF;
      UPDATE public.business_memberships
      SET status = 'suspended',
          blocked_reason = 'Invitación revocada'
      WHERE id = v_membership.id
        AND status = 'suspended'
        AND blocked_reason = 'Invitación pendiente de aceptación';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La membresía cambió durante la revocación.'
          USING ERRCODE = '40001';
      END IF;
    END IF;
  END IF;

  UPDATE public.business_invitations
  SET status = 'revoked', revoked_at = pg_catalog.now(), updated_at = pg_catalog.now()
  WHERE id = v_invitation.id;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_business_id, p_actor_id, 'business.invitation_revoked',
    'business_invitation', v_invitation.id::text,
    pg_catalog.jsonb_build_object(
      'target_user_id', v_invitation.user_id,
      'membership_id', v_invitation.membership_id,
      'reason', v_reason,
      'auth_user_deleted', false
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true, 'status', 'revoked', 'auth_user_deleted', false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.prepare_business_invitation(uuid,text,text,text,text,uuid,timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.attach_business_invitation_user(uuid,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_business_invitation_failed(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_business_invitation(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.revoke_business_invitation(uuid,uuid,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.prepare_business_invitation(uuid,text,text,text,text,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.attach_business_invitation_user(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_business_invitation_failed(uuid,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.accept_business_invitation(uuid,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.revoke_business_invitation(uuid,uuid,text) TO service_role;

-- Verificación manual posterior en staging:
-- 1) Una invitación pendiente produce membresía suspended con la marca exacta.
-- 2) resolve-my-access no devuelve esa membresía (solo status='active').
-- 3) Aceptar token correcto activa solo esa membresía.
-- 4) Token incorrecto, vencido, revocado o de otro usuario no activa nada.
-- 5) Revocar elimina solo la membresía pendiente y conserva auth.users/otras membresías.
-- 6) Aceptación y revocación concurrentes producen exactamente un resultado válido.
