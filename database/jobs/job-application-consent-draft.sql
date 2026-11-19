-- MiEje Market — evidencia versionada del consentimiento en postulaciones.
-- Aplicar después de confirmar el esquema base de job_applications en staging.
-- No modifica filas históricas ni despliega funciones Edge.

ALTER TABLE public.job_applications
  ADD COLUMN IF NOT EXISTS privacy_consent_version text,
  ADD COLUMN IF NOT EXISTS privacy_consent_at timestamptz;

ALTER TABLE public.job_applications
  DROP CONSTRAINT IF EXISTS job_applications_privacy_consent_evidence_check;

ALTER TABLE public.job_applications
  ADD CONSTRAINT job_applications_privacy_consent_evidence_check
  CHECK (
    (privacy_consent_version IS NULL AND privacy_consent_at IS NULL)
    OR (
      privacy_consent IS TRUE
      AND privacy_consent_version = 'job-application-2026-11-19-v1'
      AND privacy_consent_at IS NOT NULL
    )
  );

COMMENT ON COLUMN public.job_applications.privacy_consent_version IS
  'Identificador inmutable de la versión del aviso de privacidad aceptada al postularse; NULL identifica registros históricos sin evidencia versionada.';
COMMENT ON COLUMN public.job_applications.privacy_consent_at IS
  'Fecha/hora de PostgreSQL en que se registró la aceptación del aviso de privacidad de la postulación.';
