-- MiEje Market — auditoría segura de revisión de postulaciones.
-- Requiere que public.job_applications ya exista con:
-- status, admin_notes, reviewed_by (uuid) y reviewed_at (timestamptz).
-- Aplicar después de instalar y verificar el esquema base de vacantes.
-- No despliega Edge Functions ni modifica postulaciones históricas.

-- El estado solo puede usar los valores que ofrece el flujo del panel.
-- El preflight evita convertir silenciosamente datos históricos desconocidos.
DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.job_applications
    WHERE status IS NOT NULL
      AND status NOT IN ('pending','reviewing','contacted','accepted','rejected')
  ) THEN
    RAISE EXCEPTION 'Hay estados históricos de postulaciones fuera del catálogo permitido. Revisarlos antes de continuar.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.job_applications'::regclass
      AND conname='job_applications_status_allowed_check'
  ) THEN
    ALTER TABLE public.job_applications
      ADD CONSTRAINT job_applications_status_allowed_check
      CHECK (status IN ('pending','reviewing','contacted','accepted','rejected'))
      NOT VALID;
  END IF;
END;
$migration$;

ALTER TABLE public.job_applications
  VALIDATE CONSTRAINT job_applications_status_allowed_check;

-- Evita que un permiso UPDATE a nivel de tabla permita modificar columnas
-- sensibles aunque exista una concesión más limitada por columna.
REVOKE UPDATE ON TABLE public.job_applications
  FROM PUBLIC, anon, authenticated;

-- Revoca también concesiones UPDATE por columna que pudieran existir de
-- instalaciones anteriores. No se presupone una lista fija de columnas.
DO $permissions$
DECLARE
  v_columns text;
BEGIN
  SELECT string_agg(pg_catalog.format('%I', a.attname), ', ' ORDER BY a.attnum)
    INTO v_columns
  FROM pg_catalog.pg_attribute a
  WHERE a.attrelid = 'public.job_applications'::regclass
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attname NOT IN ('status', 'admin_notes');

  IF v_columns IS NOT NULL THEN
    EXECUTE pg_catalog.format(
      'REVOKE UPDATE (%s) ON TABLE public.job_applications FROM PUBLIC, anon, authenticated',
      v_columns
    );
  END IF;
END;
$permissions$;

REVOKE UPDATE (status, admin_notes)
  ON TABLE public.job_applications
  FROM PUBLIC, anon, authenticated;

GRANT UPDATE (status, admin_notes)
  ON TABLE public.job_applications
  TO authenticated;


-- Los metadatos de auditoría se generan en PostgreSQL. El cliente no puede
-- elegir qué usuario aparece como revisor ni falsificar la fecha.
CREATE OR REPLACE FUNCTION public.set_job_application_review_audit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Se requiere una sesión autenticada para revisar postulaciones.';
  END IF;

  NEW.reviewed_by := auth.uid();
  NEW.reviewed_at := pg_catalog.transaction_timestamp();
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_job_application_review_audit()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_job_application_review_audit
  ON public.job_applications;

CREATE TRIGGER trg_job_application_review_audit
BEFORE UPDATE OF status, admin_notes
ON public.job_applications
FOR EACH ROW
EXECUTE FUNCTION public.set_job_application_review_audit();

COMMENT ON FUNCTION public.set_job_application_review_audit() IS
  'Asigna reviewed_by desde auth.uid() y reviewed_at desde PostgreSQL cuando un administrador actualiza status o admin_notes.';
