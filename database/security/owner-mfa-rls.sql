-- MiEje Market: exigir MFA al propietario en las políticas RLS.
-- PREPARACIÓN SOLAMENTE: no ejecutar hasta publicar la interfaz MFA y desplegar
-- la Edge Function protegida en una misma ventana de mantenimiento.
-- No modifica datos de negocio; actualiza helper y expresiones de políticas.

CREATE OR REPLACE FUNCTION private.is_platform_owner_mfa()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = (SELECT auth.uid())
        AND p.platform_role = 'platform_owner'
        AND p.is_blocked = false
    )
    AND (SELECT auth.jwt() ->> 'aal') = 'aal2';
$function$;

REVOKE ALL ON FUNCTION private.is_platform_owner_mfa() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.is_platform_owner_mfa() TO authenticated;

-- Cambia solo las políticas que ya conceden acceso al propietario.
-- Conserva intactas las demás condiciones de cada política.
DO $migration$
DECLARE
  policy_row record;
  using_expression text;
  check_expression text;
  alter_statement text;
BEGIN
  FOR policy_row IN
    SELECT
      ns.nspname AS schema_name,
      cls.relname AS table_name,
      pol.polname AS policy_name,
      pg_get_expr(pol.polqual, pol.polrelid) AS using_expression,
      pg_get_expr(pol.polwithcheck, pol.polrelid) AS check_expression
    FROM pg_policy pol
    JOIN pg_class cls ON cls.oid = pol.polrelid
    JOIN pg_namespace ns ON ns.oid = cls.relnamespace
    WHERE ns.nspname = 'public'
      AND (
        COALESCE(pg_get_expr(pol.polqual, pol.polrelid), '') LIKE '%private.is_platform_owner()%'
        OR COALESCE(pg_get_expr(pol.polwithcheck, pol.polrelid), '') LIKE '%private.is_platform_owner()%'
      )
  LOOP
    using_expression := CASE
      WHEN policy_row.using_expression IS NULL THEN NULL
      ELSE replace(policy_row.using_expression, 'private.is_platform_owner()', 'private.is_platform_owner_mfa()')
    END;
    check_expression := CASE
      WHEN policy_row.check_expression IS NULL THEN NULL
      ELSE replace(policy_row.check_expression, 'private.is_platform_owner()', 'private.is_platform_owner_mfa()')
    END;

    alter_statement := format(
      'ALTER POLICY %I ON %I.%I',
      policy_row.policy_name,
      policy_row.schema_name,
      policy_row.table_name
    );

    IF using_expression IS NOT NULL THEN
      alter_statement := alter_statement || format(' USING (%s)', using_expression);
    END IF;
    IF check_expression IS NOT NULL THEN
      alter_statement := alter_statement || format(' WITH CHECK (%s)', check_expression);
    END IF;

    EXECUTE alter_statement;
  END LOOP;
END
$migration$;
