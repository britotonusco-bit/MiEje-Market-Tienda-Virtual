-- Devuelve solo sesiones vencidas cuyo path coincide exactamente con el
-- negocio, la sesión y un nombre de archivo UUID permitido. Las rutas
-- malformadas quedan fuera de la limpieza automática para revisión manual.
CREATE OR REPLACE FUNCTION public.list_expired_job_application_upload_sessions(
  p_limit integer DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  business_id uuid,
  content_page_id uuid,
  resume_path text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    s.id,
    s.business_id,
    s.content_page_id,
    s.resume_path
  FROM public.job_application_upload_sessions s
  WHERE s.consumed_at IS NULL
    AND s.expires_at <= now()
    AND s.resume_path ~* (
      '^' || s.business_id::text || '/' || s.id::text ||
      '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](pdf|doc|docx)$'
    )
  ORDER BY s.expires_at ASC, s.id ASC
  LIMIT greatest(1, least(coalesce(p_limit, 100), 100));
$function$;

REVOKE ALL ON FUNCTION public.list_expired_job_application_upload_sessions(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_expired_job_application_upload_sessions(integer)
  TO service_role;

-- PROPUESTA: limpieza segura de sesiones de postulación.
-- No ejecutar en producción hasta revisar y aprobar el paquete completo.
--
-- La función pública conserva SECURITY DEFINER, search_path vacío y EXECUTE
-- únicamente para service_role, igual que la definición observada en el proyecto.
-- La sesión de carga se elimina dentro de la misma transacción en la que se
-- registra la postulación. El archivo y su ruta permanecen vinculados a
-- job_applications.resume_path; solo se elimina el registro temporal de sesión.

CREATE OR REPLACE FUNCTION public.submit_public_job_application(
  p_application_id uuid,
  p_business_id uuid,
  p_content_page_id uuid,
  p_applicant_name text,
  p_applicant_contact text,
  p_applicant_message text,
  p_form_responses jsonb,
  p_privacy_consent boolean,
  p_privacy_consent_version text,
  p_resume_path text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  session_id uuid;
BEGIN
  IF p_application_id IS NULL
     OR p_business_id IS NULL
     OR p_content_page_id IS NULL
     OR nullif(btrim(p_applicant_name), '') IS NULL
     OR length(p_applicant_name) > 120
     OR nullif(btrim(p_applicant_contact), '') IS NULL
     OR length(p_applicant_contact) > 180
     OR length(coalesce(p_applicant_message, '')) > 2000
     OR p_privacy_consent IS DISTINCT FROM true
     OR p_privacy_consent_version IS DISTINCT FROM 'job-application-2026-11-19-v1'
     OR jsonb_typeof(coalesce(p_form_responses, '{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'Datos de postulación inválidos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_content_pages p
    JOIN public.businesses b ON b.id = p.business_id
    WHERE p.id = p_content_page_id
      AND p.business_id = p_business_id
      AND p.content_type = 'job_form'
      AND p.is_published = true
      AND p.moderation_status = 'approved'
      AND b.status = 'active'
  ) THEN
    RAISE EXCEPTION 'La vacante ya no está disponible.';
  END IF;

  IF p_resume_path IS NOT NULL THEN
    SELECT s.id INTO session_id
    FROM public.job_application_upload_sessions s
    WHERE s.id = p_application_id
      AND s.business_id = p_business_id
      AND s.content_page_id = p_content_page_id
      AND s.resume_path = p_resume_path
      AND s.expires_at > now()
      AND s.consumed_at IS NULL
    FOR UPDATE;

    IF session_id IS NULL THEN
      RAISE EXCEPTION 'El archivo adjunto no es válido o ha expirado.';
    END IF;

    UPDATE public.job_application_upload_sessions
      SET consumed_at = now()
    WHERE id = session_id;
  END IF;

  INSERT INTO public.job_applications (
    id, business_id, content_page_id, applicant_name, applicant_contact,
    applicant_message, form_responses, privacy_consent,
    privacy_consent_version, privacy_consent_at, resume_path
  ) VALUES (
    p_application_id, p_business_id, p_content_page_id, btrim(p_applicant_name),
    btrim(p_applicant_contact), nullif(btrim(coalesce(p_applicant_message, '')), ''),
    coalesce(p_form_responses, '{}'::jsonb), true,
    p_privacy_consent_version, pg_catalog.transaction_timestamp(), p_resume_path
  );

  -- La postulación ya conserva la ruta del archivo. La sesión temporal ya no
  -- se necesita; borrar su fila dentro de esta transacción evita huérfanos SQL.
  -- Si el INSERT anterior falla, toda la transacción revierte y la sesión queda.
  IF session_id IS NOT NULL THEN
    DELETE FROM public.job_application_upload_sessions
    WHERE id = session_id
      AND business_id = p_business_id
      AND resume_path = p_resume_path;
  END IF;

  RETURN p_application_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_public_job_application(
  uuid, uuid, uuid, text, text, text, jsonb, boolean, text, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.submit_public_job_application(
  uuid, uuid, uuid, text, text, text, jsonb, boolean, text
) TO service_role;

COMMENT ON FUNCTION public.submit_public_job_application(
  uuid, uuid, uuid, text, text, text, jsonb, boolean, text, text
) IS 'Registra una postulación y elimina su sesión temporal de carga en la misma transacción. La hoja de vida permanece en Storage y vinculada por resume_path.';
