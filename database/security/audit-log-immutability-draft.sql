-- MiEje Market
-- Borrador NO aplicado: historial de auditoría append-only.
-- Aplicar después de verificar la tabla public.audit_logs y su política de lectura.
-- No ejecutar en el proyecto activo sin staging y autorización.

CREATE OR REPLACE FUNCTION private.prevent_audit_log_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION 'El historial de auditoría es inmutable; no se permite %.', TG_OP
    USING ERRCODE = '42501';
END;
$function$;

DROP TRIGGER IF EXISTS audit_logs_no_update_delete ON public.audit_logs;
CREATE TRIGGER audit_logs_no_update_delete
BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW
EXECUTE FUNCTION private.prevent_audit_log_mutation();

DROP TRIGGER IF EXISTS audit_logs_no_truncate ON public.audit_logs;
CREATE TRIGGER audit_logs_no_truncate
BEFORE TRUNCATE ON public.audit_logs
FOR EACH STATEMENT
EXECUTE FUNCTION private.prevent_audit_log_mutation();

-- Mantener SELECT/INSERT según las policies y flujos existentes.
REVOKE UPDATE, DELETE, TRUNCATE
ON TABLE public.audit_logs
FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION private.prevent_audit_log_mutation()
FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION private.prevent_audit_log_mutation()
IS 'Impide UPDATE, DELETE y TRUNCATE sobre audit_logs, incluso desde service_role.';

-- Validar los metadatos nuevos y fijar la hora desde PostgreSQL.
-- No se exige actor_id NOT NULL para permitir eventos de sistema; la FK
-- histórica usa ON DELETE SET NULL si una cuenta se elimina.
CREATE OR REPLACE FUNCTION private.guard_audit_log_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF NEW.action IS NULL
     OR pg_catalog.btrim(NEW.action) = ''
     OR pg_catalog.char_length(NEW.action) > 120
     OR NEW.entity_type IS NULL
     OR pg_catalog.btrim(NEW.entity_type) = ''
     OR pg_catalog.char_length(NEW.entity_type) > 80
     OR (NEW.entity_id IS NOT NULL AND pg_catalog.char_length(NEW.entity_id) > 200)
     OR NEW.details IS NULL
     OR pg_catalog.jsonb_typeof(NEW.details) IS DISTINCT FROM 'object'
     OR pg_catalog.octet_length(NEW.details::text) > 16384 THEN
    RAISE EXCEPTION 'Los metadatos del evento de auditoría no cumplen el formato permitido.'
      USING ERRCODE = '22023';
  END IF;

  NEW.created_at := pg_catalog.transaction_timestamp();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS audit_logs_validate_insert ON public.audit_logs;
CREATE TRIGGER audit_logs_validate_insert
BEFORE INSERT ON public.audit_logs
FOR EACH ROW
EXECUTE FUNCTION private.guard_audit_log_insert();

REVOKE ALL ON FUNCTION private.guard_audit_log_insert()
FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON COLUMN public.audit_logs.details
IS 'Metadatos operativos JSON. No almacenar contraseñas, tokens, documentos, teléfonos, correos ni datos personales innecesarios. Límite de 16 KiB por evento.';
