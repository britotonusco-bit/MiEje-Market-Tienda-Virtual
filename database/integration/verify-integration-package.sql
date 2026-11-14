-- MiEje Market — verificación posterior del paquete de integración
-- SOLO LECTURA. Ejecutar en staging después de aplicar todas las migraciones.
-- Si un requisito falla, el bloque aborta con un mensaje claro.

DO $verify$
DECLARE
  missing text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='orders'
      AND column_name='customer_user_id'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta orders.customer_user_id.';
  END IF;

  IF to_regclass('public.customer_favorites') IS NULL
     OR to_regclass('private.checkout_idempotency') IS NULL
     OR to_regclass('private.checkout_rate_limit_reservations') IS NULL
     OR to_regclass('public.platform_public_settings') IS NULL THEN
    RAISE EXCEPTION 'FALLO: falta una tabla de clientes, checkout o configuración global.';
  END IF;

  IF to_regclass('public.access_block_requests') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='access_block_requests'
         AND c.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'FALLO: falta access_block_requests o RLS no está habilitado.';
  END IF;

  IF has_table_privilege('anon','public.access_block_requests','SELECT')
     OR has_table_privilege('anon','public.access_block_requests','INSERT')
     OR has_table_privilege('authenticated','public.access_block_requests','SELECT')
     OR has_table_privilege('authenticated','public.access_block_requests','UPDATE')
     OR has_table_privilege('authenticated','public.access_block_requests','DELETE')
     OR NOT has_any_column_privilege('authenticated','public.access_block_requests','INSERT') THEN
    RAISE EXCEPTION 'FALLO: los permisos directos de access_block_requests no respetan el modelo esperado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='access_block_requests'
      AND policyname='access_block_requests_admin_submit'
      AND cmd='INSERT'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la política de solicitud exclusiva del administrador del negocio.';
  END IF;

  IF to_regprocedure('public.resolve_access_block_request(uuid,text,text,uuid)') IS NULL
     OR NOT has_function_privilege('service_role','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('anon','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('authenticated','public.resolve_access_block_request(uuid,text,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: la RPC de resolución de bloqueos no tiene permisos exclusivos de servidor.';
  END IF;

  IF to_regclass('public.platform_financial_records') IS NULL
     OR to_regclass('public.payroll_records') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='platform_financial_records'
         AND c.relrowsecurity
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='payroll_records'
         AND c.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'FALLO: faltan tablas financieras de plataforma o RLS no está habilitado.';
  END IF;

  IF has_table_privilege('anon','public.platform_financial_records','SELECT')
     OR has_table_privilege('anon','public.platform_financial_records','INSERT')
     OR has_table_privilege('authenticated','public.platform_financial_records','SELECT')
     OR has_table_privilege('authenticated','public.platform_financial_records','INSERT')
     OR has_table_privilege('authenticated','public.platform_financial_records','UPDATE')
     OR has_table_privilege('authenticated','public.platform_financial_records','DELETE')
     OR has_table_privilege('anon','public.payroll_records','SELECT')
     OR has_table_privilege('authenticated','public.payroll_records','SELECT')
     OR has_table_privilege('authenticated','public.payroll_records','INSERT')
     OR has_table_privilege('authenticated','public.payroll_records','UPDATE')
     OR has_table_privilege('authenticated','public.payroll_records','DELETE')
     OR NOT has_table_privilege('service_role','public.platform_financial_records','SELECT')
     OR NOT has_table_privilege('service_role','public.platform_financial_records','INSERT')
     OR NOT has_table_privilege('service_role','public.payroll_records','SELECT')
     OR NOT has_table_privilege('service_role','public.payroll_records','INSERT')
     OR NOT has_table_privilege('service_role','public.payroll_records','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los grants financieros no son exclusivos del servidor.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.check_constraints
    WHERE constraint_schema='public'
      AND constraint_name='payroll_paid_fields_consistent'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta la validación de coherencia del estado de nómina.';
  END IF;

  IF to_regclass('public.business_ai_settings') IS NULL
     OR to_regclass('public.platform_ai_settings') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='business_ai_settings'
         AND c.relrowsecurity
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='platform_ai_settings'
         AND c.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'FALLO: faltan tablas de configuración IA o RLS no está habilitado.';
  END IF;

  IF has_table_privilege('anon','public.business_ai_settings','SELECT')
     OR has_table_privilege('anon','public.business_ai_settings','INSERT')
     OR has_table_privilege('anon','public.platform_ai_settings','SELECT')
     OR has_table_privilege('anon','public.platform_ai_settings','INSERT')
     OR has_table_privilege('authenticated','public.platform_ai_settings','SELECT')
     OR has_table_privilege('authenticated','public.platform_ai_settings','INSERT')
     OR has_table_privilege('authenticated','public.platform_ai_settings','UPDATE')
     OR NOT has_table_privilege('service_role','public.platform_ai_settings','SELECT')
     OR NOT has_table_privilege('service_role','public.platform_ai_settings','INSERT')
     OR NOT has_table_privilege('service_role','public.platform_ai_settings','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los permisos de configuración IA no respetan el acceso por rol.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_ai_settings'
      AND policyname='business_ai_settings_admin_select' AND cmd='SELECT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_ai_settings'
      AND policyname='business_ai_settings_admin_insert' AND cmd='INSERT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_ai_settings'
      AND policyname='business_ai_settings_admin_update' AND cmd='UPDATE'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas de IA exclusivas del administrador del negocio.';
  END IF;

  IF to_regprocedure('public.resolve_platform_payroll_record(uuid,text,text,uuid)') IS NULL
     OR NOT has_function_privilege('service_role','public.resolve_platform_payroll_record(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('anon','public.resolve_platform_payroll_record(uuid,text,text,uuid)','EXECUTE')
     OR has_function_privilege('authenticated','public.resolve_platform_payroll_record(uuid,text,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: la RPC de resolución de nómina no es exclusiva del servidor.';
  END IF;

  IF to_regprocedure('private.audit_business_ai_settings_change()') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_trigger t
       JOIN pg_class c ON c.oid=t.tgrelid
       JOIN pg_namespace n ON n.oid=c.relnamespace
       WHERE n.nspname='public' AND c.relname='business_ai_settings'
         AND t.tgname='business_ai_settings_audit'
         AND NOT t.tgisinternal
     ) THEN
    RAISE EXCEPTION 'FALLO: falta el registro de auditoría de cambios de IA por negocio.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname='customer_favorites'
      AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'FALLO: RLS no está habilitado en customer_favorites.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname='platform_public_settings'
      AND c.relrowsecurity
  ) OR has_table_privilege('anon','public.platform_public_settings','SELECT')
    OR has_table_privilege('authenticated','public.platform_public_settings','SELECT')
    OR has_table_privilege('anon','public.platform_public_settings','UPDATE')
    OR has_table_privilege('authenticated','public.platform_public_settings','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: configuración global sin RLS o expuesta directamente al cliente.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='business_memberships'
      AND column_name='job_title'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta business_memberships.job_title.';
  END IF;

  IF to_regprocedure('public.get_public_order_idempotent(uuid,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)') IS NULL
     OR to_regprocedure('public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)') IS NULL
     OR to_regprocedure('public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPCs de idempotencia del checkout.';
  END IF;

  IF to_regprocedure('public.get_business_admin_order_financials(uuid,boolean,integer)') IS NULL
     OR to_regprocedure('public.mark_order_payment_received(uuid,text,text,text)') IS NULL
     OR to_regprocedure('public.get_customer_order_history()') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPCs de finanzas o historial de clientes.';
  END IF;

  IF to_regclass('public.financial_one_completed_payment_per_order') IS NULL
     OR to_regclass('public.financial_one_completed_refund_per_order') IS NULL THEN
    RAISE EXCEPTION 'FALLO: falta la protección contra pagos o reembolsos completados duplicados.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='financial_transactions'
      AND policyname='financial_admin_select'
      AND qual ILIKE '%is_platform_owner%'
  ) OR EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_expenses'
      AND policyname='business_expenses_select'
      AND qual ILIKE '%is_platform_owner%'
  ) THEN
    RAISE EXCEPTION 'FALLO: el propietario técnico conserva lectura directa global de finanzas de negocios.';
  END IF;

  IF to_regprocedure('public.complete_order_refund(uuid,text,text,text,text)') IS NULL
     OR NOT has_function_privilege('authenticated',
       'public.complete_order_refund(uuid,text,text,text,text)','EXECUTE')
     OR has_function_privilege('anon',
       'public.complete_order_refund(uuid,text,text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: RPC de reembolso ausente o con permisos incorrectos.';
  END IF;

  IF to_regprocedure('public.request_order_cancellation(uuid,uuid,text)') IS NULL
     OR to_regprocedure('public.decide_order_cancellation(uuid,text,text)') IS NULL
     OR to_regprocedure('public.complete_order_refund(uuid,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan RPCs de cancelación o reembolso.';
  END IF;

  IF to_regprocedure('private.guard_last_active_business_admin()') IS NULL
     OR to_regprocedure('private.prevent_business_scope_change()') IS NULL
     OR to_regprocedure('private.enforce_order_status_transition()') IS NULL THEN
    RAISE EXCEPTION 'FALLO: faltan funciones de protección de membresías/negocios/pedidos.';
  END IF;

  -- El técnico no debe conservar un bypass global sobre pedidos ni partidas.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='orders'
      AND policyname IN ('orders_members_select','orders_members_update_status')
      AND (
        coalesce(qual,'') ILIKE '%is_platform_owner%'
        OR coalesce(with_check,'') ILIKE '%is_platform_owner%'
      )
  ) OR EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='order_items'
      AND policyname='order_items_members_select'
      AND coalesce(qual,'') ILIKE '%is_platform_owner%'
  ) OR position(
    'is_platform_owner' IN lower(pg_get_functiondef(
      'private.enforce_order_status_transition()'::regprocedure
    ))
  ) > 0 THEN
    RAISE EXCEPTION 'FALLO: el propietario técnico conserva un bypass directo en el flujo de pedidos.';
  END IF;

  IF NOT has_column_privilege('authenticated','public.orders','status','UPDATE')
     OR NOT has_column_privilege('authenticated','public.orders','delivery_tracking','UPDATE')
     OR has_column_privilege('authenticated','public.orders','payment_status','UPDATE')
     OR has_column_privilege('authenticated','public.orders','total','UPDATE')
     OR has_table_privilege('anon','public.orders','SELECT')
     OR has_table_privilege('anon','public.order_items','SELECT') THEN
    RAISE EXCEPTION 'FALLO: los permisos de actualización/lectura de pedidos no coinciden con el modelo.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_select_own' AND cmd='SELECT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_insert_own_active_product' AND cmd='INSERT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='customer_favorites'
      AND policyname='customer_favorites_delete_own' AND cmd='DELETE'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas RLS de favoritos.';
  END IF;

  IF has_table_privilege('anon','public.customer_favorites','SELECT')
     OR has_table_privilege('anon','public.customer_favorites','INSERT')
     OR has_table_privilege('anon','public.customer_favorites','DELETE')
     OR NOT has_table_privilege('authenticated','public.customer_favorites','SELECT')
     OR NOT has_table_privilege('authenticated','public.customer_favorites','INSERT')
     OR NOT has_table_privilege('authenticated','public.customer_favorites','DELETE')
     OR has_table_privilege('authenticated','public.customer_favorites','UPDATE') THEN
    RAISE EXCEPTION 'FALLO: los permisos de favoritos no son exclusivos del cliente autenticado.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.get_customer_order_history()','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_customer_order_history()','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: el historial no está limitado a sesiones autenticadas.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey)
    WHERE c.conrelid='public.orders'::regclass
      AND c.contype='f'
      AND a.attname='customer_user_id'
      AND c.confdeltype='n'
  ) THEN
    RAISE EXCEPTION 'FALLO: borrar una cuenta podría no conservar los pedidos con customer_user_id en NULL.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_content_pages'
      AND policyname='business_content_pages_public_read'
      AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_content_pages'
      AND policyname='business_content_pages_public_or_admin_read'
      AND cmd='SELECT' AND roles @> ARRAY['authenticated']::name[]
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas separadas para contenido público anon y authenticated.';
  END IF;

  IF NOT has_function_privilege('service_role',
       'public.get_public_order_idempotent(uuid,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR NOT has_function_privilege('service_role',
       'public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR NOT has_function_privilege('service_role',
       'public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_public_order_idempotent(uuid,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.get_public_order_idempotent(uuid,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon',
       'public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.reserve_checkout_rate_limit(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon',
       'public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.create_public_order_idempotent(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPCs de idempotencia del checkout.';
  END IF;

  IF has_table_privilege('anon','private.checkout_idempotency','SELECT')
     OR has_table_privilege('authenticated','private.checkout_idempotency','SELECT')
     OR has_table_privilege('service_role','private.checkout_idempotency','SELECT')
     OR has_table_privilege('anon','private.checkout_rate_limit_reservations','SELECT')
     OR has_table_privilege('authenticated','private.checkout_rate_limit_reservations','SELECT')
     OR has_table_privilege('service_role','private.checkout_rate_limit_reservations','SELECT') THEN
    RAISE EXCEPTION 'FALLO: tablas internas de idempotencia no deben tener lectura directa.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.get_business_admin_order_financials(uuid,boolean,integer)','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_business_admin_order_financials(uuid,boolean,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPC financiero.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.get_customer_order_history()','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_customer_order_history()','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPC de historial.';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.mark_order_payment_received(uuid,text,text,text)','EXECUTE')
     OR has_function_privilege('anon',
       'public.mark_order_payment_received(uuid,text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: permisos incorrectos en RPC de confirmación de pagos.';
  END IF;

  IF has_column_privilege('authenticated','public.orders','total','SELECT')
     OR has_column_privilege('authenticated','public.orders','payment_status','SELECT')
     OR has_column_privilege('authenticated','public.order_items','unit_price','SELECT')
     OR has_column_privilege('authenticated','public.order_items','line_total','SELECT') THEN
    RAISE EXCEPTION 'FALLO: authenticated conserva lectura directa de importes financieros.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id='business-assets' AND public=true AND file_size_limit=5242880
  ) OR NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id='job-applications-private' AND public=false AND file_size_limit=5242880
  ) THEN
    RAISE EXCEPTION 'FALLO: buckets ausentes o su visibilidad/límite de 5 MB no coincide con lo esperado.';
  END IF;

  IF NOT has_column_privilege('anon','public.businesses','id','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','status','SELECT') THEN
    RAISE EXCEPTION 'FALLO: anon no tiene las columnas públicas mínimas para resolver contenido publicado.';
  END IF;

  IF NOT has_column_privilege('anon','public.businesses','name','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','slug','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','business_type','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','category','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','description','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','tagline','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','city','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','contact_phone','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','whatsapp_support','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','opening_hours','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','logo_url','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','public_suspension_message','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','delivery_fee','SELECT')
     OR NOT has_column_privilege('anon','public.businesses','minimum_order_amount','SELECT') THEN
    RAISE EXCEPTION 'FALLO: anon no puede leer todas las columnas públicas necesarias del directorio.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='business_content_pages'
      AND policyname='business_content_pages_public_read'
      AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
      AND qual ILIKE '%EXISTS%'
      AND qual NOT ILIKE '%private.business_is_active%'
      AND qual NOT ILIKE '%private.has_business_role%'
  ) THEN
    RAISE EXCEPTION 'FALLO: el contenido público anon todavía depende de helpers privados.';
  END IF;

  IF NOT has_table_privilege('anon','public.products','SELECT')
     OR NOT EXISTS (
       SELECT 1 FROM pg_policies
       WHERE schemaname='public' AND tablename='businesses'
         AND policyname='businesses_public_directory_anon'
         AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_policies
       WHERE schemaname='public' AND tablename='products'
         AND policyname='products_public_active_anon'
         AND cmd='SELECT' AND roles @> ARRAY['anon']::name[]
         AND qual ILIKE '%EXISTS%'
         AND qual NOT ILIKE '%private.business_is_active%'
     ) THEN
    RAISE EXCEPTION 'FALLO: el catálogo público anon no tiene grants/políticas independientes de helpers privados.';
  END IF;

  IF has_function_privilege('anon','private.business_is_active(uuid)','EXECUTE')
     OR has_function_privilege('anon','private.has_business_role(uuid,text[])','EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: no se debe conceder a anon ejecución de helpers privados.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_upload' AND cmd='INSERT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='business_assets_admin_read' AND cmd='SELECT'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='job_application_documents_business_admin_read' AND cmd='SELECT'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan políticas de Storage para activos o documentos privados.';
  END IF;


  IF to_regclass('public.product_costs') IS NULL
     OR to_regclass('public.order_item_costs') IS NULL
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.product_costs'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.order_item_costs'::regclass) THEN
    RAISE EXCEPTION 'FALLO: faltan tablas de costos o RLS no está habilitado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_costs'
      AND policyname='product_costs_admin_select'
      AND cmd='SELECT' AND qual NOT ILIKE '%is_platform_owner%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_costs'
      AND policyname='product_costs_admin_insert'
      AND cmd='INSERT' AND with_check NOT ILIKE '%is_platform_owner%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_costs'
      AND policyname='product_costs_admin_update'
      AND cmd='UPDATE' AND qual NOT ILIKE '%is_platform_owner%'
      AND with_check NOT ILIKE '%is_platform_owner%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='order_item_costs'
      AND policyname='order_item_costs_admin_select'
      AND cmd='SELECT' AND qual NOT ILIKE '%is_platform_owner%'
  ) THEN
    RAISE EXCEPTION 'FALLO: las políticas de costos permiten acceso técnico global o faltan.';
  END IF;

  IF NOT has_table_privilege('authenticated','public.product_costs','SELECT')
     OR NOT has_table_privilege('authenticated','public.product_costs','INSERT')
     OR NOT has_table_privilege('authenticated','public.product_costs','UPDATE')
     OR has_table_privilege('anon','public.product_costs','SELECT')
     OR has_table_privilege('anon','public.order_item_costs','SELECT')
     OR has_table_privilege('authenticated','public.order_item_costs','INSERT')
     OR has_table_privilege('authenticated','public.order_item_costs','UPDATE')
     OR has_table_privilege('authenticated','public.order_item_costs','DELETE') THEN
    RAISE EXCEPTION 'FALLO: privilegios incorrectos en tablas de costos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='order_item_costs'
      AND column_name='unit_cost'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='product_costs'
      AND column_name='cost_price'
  ) THEN
    RAISE EXCEPTION 'FALLO: faltan columnas para costo unitario e histórico.';
  END IF;

  RAISE NOTICE 'OK: estructura, RPCs, RLS, privilegios y buckets del paquete están presentes.';
END
$verify$;

-- Comprobación adicional, también de solo lectura:
-- ejecutar después de este bloque:
-- database/orders/verify-order-financial-access.sql
