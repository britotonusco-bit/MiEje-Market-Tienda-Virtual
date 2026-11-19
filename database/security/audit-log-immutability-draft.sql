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
