-- MiEje Market Independiente
-- Solicitudes de bloqueo de membresías: el administrador solicita y el propietario técnico resuelve.
-- BORRADOR: aplicar solo en un entorno de ensayo autorizado.

CREATE TABLE IF NOT EXISTS public.access_block_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid REFERENCES public.businesses(id) ON DELETE SET NULL,
  requested_by uuid NOT NULL,
  target_user_id uuid NOT NULL,
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 5 AND 2000),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected')),
  technician_note text,
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT access_block_requests_distinct_users
    CHECK (requested_by <> target_user_id),
  CONSTRAINT access_block_requests_resolution_fields
    CHECK (
      (status = 'pending' AND resolved_by IS NULL AND resolved_at IS NULL)
      OR
      (status IN ('approved','rejected') AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS access_block_requests_business_created_idx
  ON public.access_block_requests (business_id, created_at DESC);

CREATE INDEX IF NOT EXISTS access_block_requests_pending_created_idx
  ON public.access_block_requests (created_at DESC)
  WHERE status = 'pending';

ALTER TABLE public.access_block_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.access_block_requests FROM PUBLIC, anon, authenticated, service_role;
GRANT INSERT (business_id, requested_by, target_user_id, reason)
  ON TABLE public.access_block_requests TO authenticated;

DROP POLICY IF EXISTS access_block_requests_admin_submit ON public.access_block_requests;
CREATE POLICY access_block_requests_admin_submit
ON public.access_block_requests
FOR INSERT TO authenticated
WITH CHECK (
  business_id IS NOT NULL
  AND requested_by = (SELECT auth.uid())
  AND target_user_id <> (SELECT auth.uid())
  AND status = 'pending'
  AND resolved_by IS NULL
  AND resolved_at IS NULL
  AND private.business_is_active(business_id)
  AND private.has_business_role(business_id, ARRAY['business_admin']::text[])
  AND EXISTS (
    SELECT 1
    FROM public.business_memberships target
    WHERE target.business_id = access_block_requests.business_id
      AND target.user_id = access_block_requests.target_user_id
      AND target.status = 'active'
  )
);

-- La resolución es atómica: suspende solo la membresía del negocio solicitado,
-- conserva el acceso del usuario a otros negocios y registra auditoría.
CREATE OR REPLACE FUNCTION public.resolve_access_block_request(
  p_request_id uuid,
  p_decision text,
  p_technician_note text,
  p_technician_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_request public.access_block_requests%ROWTYPE;
  v_membership public.business_memberships%ROWTYPE;
  v_admin_count integer;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_decision NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'La decisión debe ser approved o rejected.';
  END IF;
  IF pg_catalog.length(pg_catalog.btrim(coalesce(p_technician_note,''))) > 2000 THEN
    RAISE EXCEPTION 'La nota técnica supera el máximo de 2000 caracteres.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = p_technician_id
      AND p.platform_role = 'platform_owner'
      AND coalesce(p.is_blocked,false) = false
  ) THEN
    RAISE EXCEPTION 'Solo el propietario técnico puede resolver solicitudes.';
  END IF;

  SELECT * INTO v_request
  FROM public.access_block_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la solicitud de bloqueo.';
  END IF;
  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'La solicitud ya fue resuelta. Actualiza la lista.';
  END IF;

  IF p_decision = 'approved' THEN
    IF v_request.business_id IS NULL THEN
      RAISE EXCEPTION 'El negocio de la solicitud ya no existe; no se puede bloquear la membresía.';
    END IF;

    SELECT * INTO v_membership
    FROM public.business_memberships
    WHERE business_id = v_request.business_id
      AND user_id = v_request.target_user_id
      AND status = 'active'
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La cuenta ya no tiene una membresía activa en ese negocio.';
    END IF;

    IF v_membership.role = 'business_admin' THEN
      SELECT pg_catalog.count(*)::integer INTO v_admin_count
      FROM public.business_memberships
      WHERE business_id = v_request.business_id
        AND role = 'business_admin'
        AND status = 'active';
      IF v_admin_count <= 1 THEN
        RAISE EXCEPTION 'No se puede bloquear al último administrador activo del negocio.';
      END IF;
    END IF;

    UPDATE public.business_memberships
    SET status = 'suspended',
        blocked_reason = pg_catalog.left(
          'Solicitud técnica aprobada: ' || v_request.reason,
          2000
        )
    WHERE id = v_membership.id
      AND status = 'active';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La membresía cambió durante la operación. Actualiza la lista.';
    END IF;
  END IF;

  UPDATE public.access_block_requests
  SET status = p_decision,
      technician_note = nullif(pg_catalog.btrim(coalesce(p_technician_note,'')), ''),
      resolved_by = p_technician_id,
      resolved_at = v_now,
      updated_at = v_now
  WHERE id = v_request.id;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_request.business_id,
    p_technician_id,
    CASE WHEN p_decision = 'approved'
      THEN 'access.block_request_approved'
      ELSE 'access.block_request_rejected'
    END,
    'access_block_request',
    v_request.id,
    pg_catalog.jsonb_build_object(
      'target_user_id', v_request.target_user_id,
      'requested_by', v_request.requested_by,
      'reason', v_request.reason,
      'technician_note', nullif(pg_catalog.btrim(coalesce(p_technician_note,'')), '')
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'request_id', v_request.id,
    'status', p_decision,
    'target_user_id', v_request.target_user_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_access_block_request(uuid,text,text,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_access_block_request(uuid,text,text,uuid)
  TO service_role;

-- PRUEBAS OBLIGATORIAS EN ENSAYO:
-- 1) Administrador A puede solicitar bloqueo de un miembro activo de A.
-- 2) Empleado, cliente y administrador B no pueden crear solicitudes para A.
-- 3) El propietario técnico con MFA puede listar y resolver solicitudes vía Edge Function.
-- 4) Aprobación suspende solo la membresía del negocio solicitado, no la cuenta global.
-- 5) No se puede suspender al último administrador activo.
-- 6) Rechazo no modifica la membresía.
-- 7) Dos resoluciones concurrentes no pueden procesar la misma solicitud dos veces.
-- 8) Cada resolución genera auditoría y se revierte completa si falla la auditoría.
