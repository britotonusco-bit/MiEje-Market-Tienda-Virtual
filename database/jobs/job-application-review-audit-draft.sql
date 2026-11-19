-- MiEje Market — auditoría segura de revisión de postulaciones.
-- Requiere que public.job_applications ya exista con:
-- status, admin_notes, reviewed_by (uuid) y reviewed_at (timestamptz).
-- Aplicar después de instalar y verificar el esquema base de vacantes.
-- No despliega Edge Functions ni modifica postulaciones históricas.

-- Evita que un permiso UPDATE a nivel de tabla permita modificar columnas
-- sensibles aunque exista una concesión más limitada por columna.
REVOKE UPDATE ON TABLE public.job_applications
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
