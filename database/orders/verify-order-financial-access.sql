-- Verificación de privilegios para order-financial-access-draft.sql
-- Solo lectura. Ejecutar después de aplicar las migraciones en un entorno de ensayo.
-- Si alguna condición no se cumple, el bloque falla con una explicación.

DO $verification$
BEGIN
  IF has_column_privilege('authenticated', 'public.orders', 'total', 'SELECT')
     OR has_column_privilege('authenticated', 'public.orders', 'subtotal', 'SELECT')
     OR has_column_privilege('authenticated', 'public.orders', 'delivery_fee', 'SELECT')
     OR has_column_privilege('authenticated', 'public.orders', 'payment_status', 'SELECT') THEN
    RAISE EXCEPTION 'FALLO: authenticated todavía puede leer importes o estado de pago directamente desde orders.';
  END IF;

  IF NOT has_column_privilege('authenticated', 'public.orders', 'customer_name', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.orders', 'status', 'SELECT') THEN
    RAISE EXCEPTION 'FALLO: faltan columnas operativas necesarias para los paneles.';
  END IF;

  IF has_column_privilege('authenticated', 'public.order_items', 'unit_price', 'SELECT')
     OR has_column_privilege('authenticated', 'public.order_items', 'line_total', 'SELECT') THEN
    RAISE EXCEPTION 'FALLO: authenticated todavía puede leer precios por línea directamente.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.get_business_admin_order_financials(uuid,boolean,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: falta EXECUTE del RPC financiero para authenticated.';
  END IF;

  IF has_function_privilege('anon', 'public.get_business_admin_order_financials(uuid,boolean,integer)', 'EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_proc p
       CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
       WHERE p.oid = to_regprocedure('public.get_business_admin_order_financials(uuid,boolean,integer)')
         AND acl.grantee = 0
         AND acl.privilege_type = 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FALLO: el RPC financiero no debe ser ejecutable por anon ni PUBLIC.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_items'
      AND policyname = 'order_items_customer_select_own'
      AND qual ILIKE '%customer_owns_order%'
  ) THEN
    RAISE EXCEPTION 'FALLO: la política de order_items no usa el helper de propiedad del cliente.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'private.customer_owns_order(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: falta EXECUTE del helper privado de propiedad de pedidos.';
  END IF;

  IF has_function_privilege('anon', 'private.customer_owns_order(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: anon no debe ejecutar el helper privado de propiedad de pedidos.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.mark_order_payment_received(uuid,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: falta EXECUTE del RPC de confirmación de pago.';
  END IF;

  IF has_function_privilege('anon', 'public.mark_order_payment_received(uuid,text,text,text)', 'EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_proc p
       CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
       WHERE p.oid = to_regprocedure('public.mark_order_payment_received(uuid,text,text,text)')
         AND acl.grantee = 0
         AND acl.privilege_type = 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FALLO: el RPC de confirmación de pago no debe ser ejecutable por anon ni PUBLIC.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'financial_one_completed_payment_per_order'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta el índice único para impedir pagos duplicados.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.get_customer_order_history()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: falta EXECUTE del RPC de historial de cliente.';
  END IF;

  IF has_function_privilege('anon', 'public.get_customer_order_history()', 'EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_proc p
       CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
       WHERE p.oid = to_regprocedure('public.get_customer_order_history()')
         AND acl.grantee = 0
         AND acl.privilege_type = 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'FALLO: el RPC de historial no debe ser ejecutable por anon ni PUBLIC.';
  END IF;


  -- Los paneles solo necesitan modificar estado y referencia de entrega.
  IF NOT has_column_privilege('authenticated', 'public.orders', 'status', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.orders', 'delivery_tracking', 'UPDATE') THEN
    RAISE EXCEPTION 'FALLO: faltan permisos operativos para actualizar el estado o seguimiento del pedido.';
  END IF;

  IF has_column_privilege('authenticated', 'public.orders', 'payment_status', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.orders', 'total', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.orders', 'business_id', 'UPDATE') THEN
    RAISE EXCEPTION 'FALLO: authenticated puede modificar columnas financieras o la pertenencia del pedido.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'orders'
  ) OR NOT (
    SELECT c.relrowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'orders'
  ) THEN
    RAISE EXCEPTION 'FALLO: RLS no está habilitado en public.orders.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'orders'
      AND policyname = 'orders_members_update_status'
      AND cmd = 'UPDATE'
      AND qual ILIKE '%has_business_role%'
      AND qual ILIKE '%business_is_active%'
      AND with_check ILIKE '%has_business_role%'
      AND with_check ILIKE '%business_is_active%'
  ) THEN
    RAISE EXCEPTION 'FALLO: la política de actualización de pedidos no limita el acceso a miembros activos del negocio.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.complete_order_refund(uuid,text,text,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.complete_order_refund(uuid,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: privilegios incorrectos del RPC de reembolsos.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.request_order_cancellation(uuid,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.decide_order_cancellation(uuid,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.request_order_cancellation(uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.decide_order_cancellation(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FALLO: privilegios incorrectos de los RPC de cancelación.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'financial_one_completed_refund_per_order'
  ) THEN
    RAISE EXCEPTION 'FALLO: falta el índice único para impedir reembolsos duplicados.';
  END IF;

  RAISE NOTICE 'OK: los privilegios de lectura financiera de pedidos coinciden con el diseño esperado.';
END;
$verification$;
