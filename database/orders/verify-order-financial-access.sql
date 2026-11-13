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

  RAISE NOTICE 'OK: los privilegios de lectura financiera de pedidos coinciden con el diseño esperado.';
END;
$verification$;
