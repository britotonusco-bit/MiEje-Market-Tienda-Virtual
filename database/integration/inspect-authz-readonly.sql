-- MiEje Market — inspección de autorización y permisos
-- SOLO LECTURA: no crea objetos, no cambia grants, no modifica políticas ni datos.
-- Ejecutar únicamente en staging después de aplicar el paquete de seguridad.
-- Revisar los resultados; una fila sospechosa requiere análisis manual.

-- 1) Estado RLS de tablas sensibles.
SELECT
  n.nspname AS schema_name,
  c.relname AS table_name,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS rls_forced,
  pg_get_userbyid(c.relowner) AS table_owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public','private')
  AND c.relkind IN ('r','p')
  AND c.relname = ANY (ARRAY[
    'orders','order_items','profiles','business_memberships',
    'financial_transactions','business_expenses','refund_details',
    'payments','refunds','product_costs','order_item_costs',
    'payroll_records','platform_financial_records','inventory_movements',
    'job_applications','job_application_upload_sessions',
    'business_invitations','audit_logs','customer_favorites'
  ])
ORDER BY n.nspname, c.relname;

-- 2) Todas las políticas de esas tablas. Buscar expresiones globales,
-- condiciones demasiado amplias, roles inesperados o WITH CHECK ausente.
SELECT
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
FROM pg_policies
WHERE schemaname IN ('public','private')
  AND tablename = ANY (ARRAY[
    'orders','order_items','profiles','business_memberships',
    'financial_transactions','business_expenses','refund_details',
    'payments','refunds','product_costs','order_item_costs',
    'payroll_records','platform_financial_records','inventory_movements',
    'job_applications','job_application_upload_sessions',
    'business_invitations','audit_logs','customer_favorites'
  ])
ORDER BY schemaname, tablename, policyname;

-- 3) Privilegios de tabla para roles expuestos por la API.
SELECT
  table_schema,
  table_name,
  grantee,
  privilege_type,
  is_grantable
FROM information_schema.role_table_grants
WHERE table_schema IN ('public','private')
  AND grantee IN ('anon','authenticated','service_role')
  AND table_name = ANY (ARRAY[
    'orders','order_items','profiles','business_memberships',
    'financial_transactions','business_expenses','refund_details',
    'payments','refunds','product_costs','order_item_costs',
    'payroll_records','platform_financial_records','inventory_movements',
    'job_applications','job_application_upload_sessions',
    'business_invitations','audit_logs','customer_favorites'
  ])
ORDER BY table_schema, table_name, grantee, privilege_type;

-- 4) Privilegios por columna en pedidos, perfiles y datos de personal.
-- Es importante porque un REVOKE/GRANT por tabla no muestra el detalle
-- de permisos heredados o concedidos sobre columnas específicas.
SELECT
  table_schema,
  table_name,
  column_name,
  grantee,
  privilege_type,
  is_grantable
FROM information_schema.column_privileges
WHERE table_schema = 'public'
  AND grantee IN ('anon','authenticated','service_role')
  AND table_name = ANY (ARRAY[
    'orders','order_items','profiles','business_memberships',
    'job_applications','product_costs','order_item_costs',
    'payroll_records','platform_financial_records'
  ])
ORDER BY table_name, column_name, grantee, privilege_type;

-- 5) Funciones SECURITY DEFINER en esquemas de aplicación.
-- Inspeccionar manualmente search_path, validación de auth.uid()/rol,
-- autorización de negocio y EXECUTE concedido a anon/authenticated.
SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  pg_get_userbyid(p.proowner) AS owner_name,
  p.prosecdef AS security_definer,
  p.proconfig AS function_settings,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('public','private')
  AND p.prosecdef
ORDER BY n.nspname, p.proname, pg_get_function_identity_arguments(p.oid);

-- 6) Políticas que mencionan explícitamente al propietario técnico en
-- tablas con datos de clientes, operaciones o finanzas. La aparición no
-- demuestra por sí sola una vulnerabilidad; cada caso debe revisarse.
SELECT
  schemaname,
  tablename,
  policyname,
  cmd,
  roles,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = ANY (ARRAY[
    'orders','order_items','profiles','business_memberships',
    'financial_transactions','business_expenses','refund_details',
    'payments','refunds','product_costs','order_item_costs',
    'payroll_records','platform_financial_records','inventory_movements',
    'job_applications','customer_favorites'
  ])
  AND (
    coalesce(qual,'') ILIKE '%platform_owner%'
    OR coalesce(with_check,'') ILIKE '%platform_owner%'
    OR coalesce(qual,'') ILIKE '%is_platform_owner%'
    OR coalesce(with_check,'') ILIKE '%is_platform_owner%'
  )
ORDER BY schemaname, tablename, policyname;

-- Este informe es diagnóstico, no certifica la seguridad de RLS.
-- Debe complementarse con llamadas reales al Data API, RPC y Edge Functions
-- autenticadas como cada rol de staging.
