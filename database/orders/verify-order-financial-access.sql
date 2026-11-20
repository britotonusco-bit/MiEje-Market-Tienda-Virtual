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

  IF position('p.is_blocked = false' IN lower(pg_get_functiondef(
       'private.customer_owns_order(uuid)'::regprocedure
     ))) = 0 THEN
    RAISE EXCEPTION 'FALLO: customer_owns_order debe rechazar perfiles bloqueados globalmente.';
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


-- Los RPC privilegiados deben ser SECURITY DEFINER solo cuando lo necesitan,
-- fijar search_path vacío, comprobar auth.uid() y no conservar EXECUTE para PUBLIC/anon.
DO $verification$
DECLARE
  signature text;
  function_oid oid;
  function_definition text;
  function_config text[];
  function_is_definer boolean;
  has_public_execute boolean;
  signatures text[] := ARRAY[
    'public.get_business_admin_order_financials(uuid,boolean,integer)',
    'public.mark_order_payment_received(uuid,text,text,text)',
    'public.get_customer_order_history()',
    'private.customer_owns_order(uuid)',
    'public.request_order_cancellation(uuid,uuid,text)',
    'public.decide_order_cancellation(uuid,text,text)',
    'public.complete_order_refund(uuid,text,text,text,text)'
  ];
BEGIN
  FOREACH signature IN ARRAY signatures LOOP
    function_oid := pg_catalog.to_regprocedure(signature);
    IF function_oid IS NULL THEN
      RAISE EXCEPTION 'FALLO: falta el RPC requerido: %.', signature;
    END IF;

    SELECT p.prosecdef, p.proconfig, pg_catalog.pg_get_functiondef(p.oid)
      INTO function_is_definer, function_config, function_definition
    FROM pg_catalog.pg_proc p
    WHERE p.oid = function_oid;

    IF function_is_definer IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FALLO: el RPC privilegiado no está definido como SECURITY DEFINER: %.', signature;
    END IF;

    IF NOT COALESCE(function_config @> ARRAY['search_path=""']::text[], false) THEN
      RAISE EXCEPTION 'FALLO: el RPC no fija search_path vacío: %.', signature;
    END IF;

    IF function_definition NOT ILIKE '%auth.uid()%' THEN
      RAISE EXCEPTION 'FALLO: el RPC no valida la identidad de la sesión mediante auth.uid(): %.', signature;
    END IF;

    IF pg_catalog.has_function_privilege('anon', function_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FALLO: anon puede ejecutar el RPC: %.', signature;
    END IF;

    IF NOT pg_catalog.has_function_privilege('authenticated', function_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FALLO: authenticated no tiene el EXECUTE esperado: %.', signature;
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc p
      CROSS JOIN LATERAL pg_catalog.aclexplode(
        COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
      ) AS acl
      WHERE p.oid = function_oid
        AND acl.grantee = 0
        AND acl.privilege_type = 'EXECUTE'
    ) INTO has_public_execute;

    IF has_public_execute THEN
      RAISE EXCEPTION 'FALLO: PUBLIC conserva EXECUTE sobre el RPC: %.', signature;
    END IF;
  END LOOP;
END
$verification$;
