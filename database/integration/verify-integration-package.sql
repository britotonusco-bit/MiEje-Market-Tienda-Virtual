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

  RAISE NOTICE 'OK: estructura, RPCs, RLS, privilegios y buckets del paquete están presentes.';
END
$verify$;

-- Comprobación adicional, también de solo lectura:
-- ejecutar después de este bloque:
-- database/orders/verify-order-financial-access.sql
