-- MiEje Market — preflight de integración
-- SOLO LECTURA. Ejecutar primero en el proyecto de ENSAYO, antes de migrar.
-- No devuelve correos, tokens, datos de clientes ni secretos.

SELECT current_database() AS database_name,
       current_setting('server_version') AS postgres_version,
       now() AS checked_at;

-- Tablas base que las migraciones posteriores esperan encontrar.
SELECT x.object_name,
       to_regclass(x.object_name) IS NOT NULL AS exists
FROM (VALUES
 ('public.businesses'),
 ('public.platform_financial_records'),
 ('public.payroll_records'),
 ('public.profiles'),
 ('public.audit_logs'),
 ('public.business_memberships'),
 ('public.products'),
 ('public.orders'),
 ('public.order_items'),
 ('public.business_payment_methods'),
 ('public.financial_transactions'),
 ('public.refund_details'),
 ('public.order_cancellation_requests'),
 ('public.business_expenses'),
 ('public.order_item_costs'),
 ('public.business_content_pages'),
 ('public.access_block_requests'),
 ('public.job_applications'),
 ('storage.buckets'),
 ('storage.objects')
) AS x(object_name)
ORDER BY x.object_name;

-- Columnas y funciones base.
SELECT x.object_name,
       EXISTS (
         SELECT 1 FROM information_schema.columns c
         WHERE c.table_schema = split_part(x.object_name,'.',1)
           AND c.table_name = split_part(x.object_name,'.',2)
           AND c.column_name = x.column_name
       ) AS exists
FROM (VALUES
 ('public.orders','id'),
 ('public.orders','created_at'),
 ('public.orders','business_id'),
 ('public.orders','payment_status'),
 ('public.products','inventory'),
 ('public.products','business_id'),
 ('public.businesses','status'),
 ('public.platform_financial_records','id'),
 ('public.platform_financial_records','business_id'),
 ('public.platform_financial_records','record_type'),
 ('public.platform_financial_records','description'),
 ('public.platform_financial_records','amount'),
 ('public.platform_financial_records','currency'),
 ('public.platform_financial_records','occurred_at'),
 ('public.platform_financial_records','created_by'),
 ('public.payroll_records','id'),
 ('public.payroll_records','business_id'),
 ('public.payroll_records','payee_name'),
 ('public.payroll_records','description'),
 ('public.payroll_records','amount'),
 ('public.payroll_records','currency'),
 ('public.payroll_records','status'),
 ('public.payroll_records','paid_at'),
 ('public.payroll_records','created_by'),
 ('public.payroll_records','updated_by'),
 ('public.business_memberships','role'),
 ('public.business_memberships','status'),
 ('public.business_memberships','blocked_reason'),
 ('public.profiles','platform_role'),
 ('public.profiles','is_blocked'),
 ('public.audit_logs','business_id'),
 ('public.audit_logs','actor_id'),
 ('public.audit_logs','action'),
 ('public.audit_logs','entity_type'),
 ('public.audit_logs','entity_id'),
 ('public.audit_logs','details')
) AS x(object_name,column_name)
ORDER BY x.object_name,x.column_name;

SELECT x.signature,
       to_regprocedure(x.signature) IS NOT NULL AS exists
FROM (VALUES
 ('public.create_public_order(uuid,text,text,text,text,text,text,jsonb)'),
 ('private.business_is_active(uuid)'),
 ('private.has_business_role(uuid,text[])'),
 ('public.resolve_access_block_request(uuid,text,text,uuid)'),
 ('private.guard_business_expense_update()'),
 ('private.enforce_order_status_transition()'),
 ('extensions.digest(text,text)')
) AS x(signature)
ORDER BY x.signature;

-- Buckets y restricciones configuradas; no lista objetos ni nombres de archivos.
SELECT id AS bucket_id,
       public,
       file_size_limit,
       allowed_mime_types
FROM storage.buckets
WHERE id IN ('business-assets','job-applications-private')
ORDER BY id;

-- Políticas actuales de las tablas que recibirán cambios.
SELECT schemaname,tablename,policyname,cmd,roles
FROM pg_policies
WHERE (schemaname='public' AND tablename IN (
 'businesses','business_memberships','profiles','products','orders',
 'order_items','business_payment_methods','business_content_pages',
 'business_expenses','order_cancellation_requests','access_block_requests','job_applications'
 ))
 OR (schemaname='storage' AND tablename='objects')
ORDER BY schemaname,tablename,cmd,policyname;

-- Revisión previa de grants: el resultado es inventario, no autorización para
-- cambiar permisos manualmente. Comparar después con verify-order-financial-access.sql.
SELECT table_schema,table_name,grantee,privilege_type
FROM information_schema.role_table_grants
WHERE table_schema IN ('public','storage')
  AND table_name IN ('businesses','products','orders','order_items','business_memberships','profiles','objects')
  AND grantee IN ('anon','authenticated','service_role')
ORDER BY table_schema,table_name,grantee,privilege_type;
