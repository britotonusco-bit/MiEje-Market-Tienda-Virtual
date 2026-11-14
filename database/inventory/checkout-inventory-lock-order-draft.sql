-- MiEje Market Independiente
-- Ajuste del checkout para bloquear productos en orden determinista y etiquetar
-- los movimientos de inventario generados por cada venta.
-- ESTADO: BORRADOR. Aplicar únicamente después de revisar contra la función live.

CREATE OR REPLACE FUNCTION public.create_public_order(
  p_business_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_delivery_address text,
  p_delivery_notes text,
  p_payment_method text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_business public.businesses%rowtype;
  v_item jsonb;
  v_product_id uuid;
  v_quantity integer;
  v_product public.products%rowtype;
  v_subtotal numeric(12,2) := 0;
  v_total numeric(12,2);
  v_snapshot jsonb := '[]'::jsonb;
  v_order public.orders%rowtype;
  v_order_item_id uuid;
  v_unit_cost numeric(12,2);
  v_item_count integer;
  v_distinct_count integer;
BEGIN
  IF p_business_id IS NULL
     OR NULLIF(TRIM(p_customer_name), '') IS NULL
     OR NULLIF(TRIM(p_customer_phone), '') IS NULL
     OR NULLIF(TRIM(p_delivery_address), '') IS NULL
     OR p_payment_method IS NULL
     OR p_payment_method NOT IN ('cash','transfer','card','other') THEN
    RAISE EXCEPTION 'Datos del pedido incompletos o inválidos.';
  END IF;

  IF LENGTH(TRIM(p_customer_name)) > 160
     OR LENGTH(TRIM(p_customer_phone)) > 50
     OR LENGTH(TRIM(p_customer_email)) > 254
     OR LENGTH(TRIM(p_delivery_address)) > 500
     OR LENGTH(COALESCE(p_delivery_notes, '')) > 1000 THEN
    RAISE EXCEPTION 'Uno o más campos superan el límite permitido.';
  END IF;

  IF p_items IS NULL
     OR JSONB_TYPEOF(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'El pedido debe incluir una lista de productos válida.';
  END IF;

  IF JSONB_ARRAY_LENGTH(p_items) < 1
     OR JSONB_ARRAY_LENGTH(p_items) > 30 THEN
    RAISE EXCEPTION 'El pedido debe incluir entre 1 y 30 productos.';
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT value->>'product_id')
  INTO v_item_count, v_distinct_count
  FROM JSONB_ARRAY_ELEMENTS(p_items);

  IF v_item_count <> v_distinct_count THEN
    RAISE EXCEPTION 'No repitas el mismo producto; ajusta su cantidad.';
  END IF;

  SELECT *
  INTO v_business
  FROM public.businesses
  WHERE id = p_business_id
    AND status = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El negocio no está disponible para recibir pedidos.';
  END IF;

  -- Validar identificadores y cantidades antes del CAST usado para ordenar.
  IF EXISTS (
    SELECT 1
    FROM JSONB_ARRAY_ELEMENTS(p_items) AS item(value)
    WHERE COALESCE(value->>'product_id','')
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR COALESCE(value->>'quantity','') !~ '^[1-9][0-9]*$'
  ) THEN
    RAISE EXCEPTION 'Producto o cantidad inválidos.';
  END IF;

  -- Bloquear productos siempre por UUID ascendente. Dos carritos que contengan
  -- los mismos productos en distinto orden adquieren los locks en el mismo orden.
  FOR v_item IN
    SELECT value
    FROM JSONB_ARRAY_ELEMENTS(p_items)
    ORDER BY (value->>'product_id')::uuid
  LOOP
    IF COALESCE(v_item->>'product_id','')
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR COALESCE(v_item->>'quantity','')
        !~ '^[1-9][0-9]*$' THEN
      RAISE EXCEPTION 'Producto o cantidad inválidos.';
    END IF;

    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;

    IF v_quantity > 99 THEN
      RAISE EXCEPTION 'La cantidad por producto no puede superar 99.';
    END IF;

    SELECT *
    INTO v_product
    FROM public.products
    WHERE id = v_product_id
      AND business_id = p_business_id
      AND is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Uno de los productos no está disponible.';
    END IF;

    IF v_product.inventory < v_quantity THEN
      RAISE EXCEPTION 'No hay inventario suficiente para: %', v_product.name;
    END IF;

    SELECT pc.cost_price
    INTO v_unit_cost
    FROM public.product_costs AS pc
    WHERE pc.product_id = v_product.id
      AND pc.business_id = p_business_id;

    v_subtotal := v_subtotal + (v_product.price * v_quantity);

    v_snapshot := v_snapshot || JSONB_BUILD_ARRAY(
      JSONB_BUILD_OBJECT(
        'product_id', v_product.id,
        'product_name', v_product.name,
        'quantity', v_quantity,
        'unit_price', v_product.price,
        'unit_cost', v_unit_cost
      )
    );
  END LOOP;

  IF v_subtotal < v_business.minimum_order_amount THEN
    RAISE EXCEPTION 'El pedido no alcanza el valor mínimo del negocio.';
  END IF;

  v_total := v_subtotal + v_business.delivery_fee;

  INSERT INTO public.orders (
    business_id, customer_name, customer_phone, customer_email,
    delivery_address, delivery_notes, payment_method, payment_status,
    status, subtotal, delivery_fee, total
  )
  VALUES (
    p_business_id,
    TRIM(p_customer_name),
    TRIM(p_customer_phone),
    NULLIF(TRIM(COALESCE(p_customer_email, '')), ''),
    TRIM(p_delivery_address),
    NULLIF(TRIM(COALESCE(p_delivery_notes, '')), ''),
    p_payment_method,
    'pending',
    'pending',
    v_subtotal,
    v_business.delivery_fee,
    v_total
  )
  RETURNING * INTO v_order;

  FOR v_item IN
    SELECT value FROM JSONB_ARRAY_ELEMENTS(v_snapshot)
  LOOP
    INSERT INTO public.order_items (
      order_id, product_id, product_name, quantity, unit_price
    )
    VALUES (
      v_order.id,
      (v_item->>'product_id')::uuid,
      v_item->>'product_name',
      (v_item->>'quantity')::integer,
      (v_item->>'unit_price')::numeric
    )
    RETURNING id INTO v_order_item_id;

    INSERT INTO public.order_item_costs (
      order_item_id, order_id, business_id, unit_cost
    )
    VALUES (
      v_order_item_id,
      v_order.id,
      p_business_id,
      NULLIF(v_item->>'unit_cost', '')::numeric
    );

    PERFORM pg_catalog.set_config(
      'app.inventory_movement_reason',
      'Venta mediante pedido ' || v_order.id::text,
      true
    );
    PERFORM pg_catalog.set_config(
      'app.inventory_movement_type', 'sale', true
    );

    UPDATE public.products
    SET inventory = inventory - (v_item->>'quantity')::integer
    WHERE id = (v_item->>'product_id')::uuid
      AND business_id = p_business_id;
  END LOOP;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  )
  VALUES (
    p_business_id,
    NULL,
    'order.created',
    'order',
    v_order.id::text,
    JSONB_BUILD_OBJECT(
      'order_number', v_order.order_number,
      'total', v_order.total,
      'source', 'public_storefront'
    )
  );

  RETURN JSONB_BUILD_OBJECT(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'status', v_order.status,
    'total', v_order.total,
    'public_tracking_token', v_order.public_tracking_token
  );
END;
$function$;

-- La firma conserva el permiso de ejecución actual (solo service_role).
REVOKE ALL ON FUNCTION public.create_public_order(
  uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_public_order(
  uuid, text, text, text, text, text, text, jsonb
) TO service_role;

-- Pruebas requeridas: dos carritos concurrentes con los mismos productos
-- en orden inverso, última unidad disponible, producto de otro negocio,
-- carrito inválido, y movimiento de venta con motivo y delta correctos.

       OR COALESCE(value->>'quantity','') !~ '^[1-9][0-9]*
    SELECT value
    FROM JSONB_ARRAY_ELEMENTS(p_items)
    ORDER BY (value->>'product_id')::uuid
  LOOP
    IF COALESCE(v_item->>'product_id','')
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR COALESCE(v_item->>'quantity','')
        !~ '^[1-9][0-9]*$' THEN
      RAISE EXCEPTION 'Producto o cantidad inválidos.';
    END IF;

    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;

    IF v_quantity > 99 THEN
      RAISE EXCEPTION 'La cantidad por producto no puede superar 99.';
    END IF;

    SELECT *
    INTO v_product
    FROM public.products
    WHERE id = v_product_id
      AND business_id = p_business_id
      AND is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Uno de los productos no está disponible.';
    END IF;

    IF v_product.inventory < v_quantity THEN
      RAISE EXCEPTION 'No hay inventario suficiente para: %', v_product.name;
    END IF;

    SELECT pc.cost_price
    INTO v_unit_cost
    FROM public.product_costs AS pc
    WHERE pc.product_id = v_product.id
      AND pc.business_id = p_business_id;

    v_subtotal := v_subtotal + (v_product.price * v_quantity);

    v_snapshot := v_snapshot || JSONB_BUILD_ARRAY(
      JSONB_BUILD_OBJECT(
        'product_id', v_product.id,
        'product_name', v_product.name,
        'quantity', v_quantity,
        'unit_price', v_product.price,
        'unit_cost', v_unit_cost
      )
    );
  END LOOP;

  IF v_subtotal < v_business.minimum_order_amount THEN
    RAISE EXCEPTION 'El pedido no alcanza el valor mínimo del negocio.';
  END IF;

  v_total := v_subtotal + v_business.delivery_fee;

  INSERT INTO public.orders (
    business_id, customer_name, customer_phone, customer_email,
    delivery_address, delivery_notes, payment_method, payment_status,
    status, subtotal, delivery_fee, total
  )
  VALUES (
    p_business_id,
    TRIM(p_customer_name),
    TRIM(p_customer_phone),
    NULLIF(TRIM(COALESCE(p_customer_email, '')), ''),
    TRIM(p_delivery_address),
    NULLIF(TRIM(COALESCE(p_delivery_notes, '')), ''),
    p_payment_method,
    'pending',
    'pending',
    v_subtotal,
    v_business.delivery_fee,
    v_total
  )
  RETURNING * INTO v_order;

  FOR v_item IN
    SELECT value FROM JSONB_ARRAY_ELEMENTS(v_snapshot)
  LOOP
    INSERT INTO public.order_items (
      order_id, product_id, product_name, quantity, unit_price
    )
    VALUES (
      v_order.id,
      (v_item->>'product_id')::uuid,
      v_item->>'product_name',
      (v_item->>'quantity')::integer,
      (v_item->>'unit_price')::numeric
    )
    RETURNING id INTO v_order_item_id;

    INSERT INTO public.order_item_costs (
      order_item_id, order_id, business_id, unit_cost
    )
    VALUES (
      v_order_item_id,
      v_order.id,
      p_business_id,
      NULLIF(v_item->>'unit_cost', '')::numeric
    );

    PERFORM pg_catalog.set_config(
      'app.inventory_movement_reason',
      'Venta mediante pedido ' || v_order.id::text,
      true
    );

    UPDATE public.products
    SET inventory = inventory - (v_item->>'quantity')::integer
    WHERE id = (v_item->>'product_id')::uuid
      AND business_id = p_business_id;
  END LOOP;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  )
  VALUES (
    p_business_id,
    NULL,
    'order.created',
    'order',
    v_order.id::text,
    JSONB_BUILD_OBJECT(
      'order_number', v_order.order_number,
      'total', v_order.total,
      'source', 'public_storefront'
    )
  );

  RETURN JSONB_BUILD_OBJECT(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'status', v_order.status,
    'total', v_order.total,
    'public_tracking_token', v_order.public_tracking_token
  );
END;
$function$;

-- La firma conserva el permiso de ejecución actual (solo service_role).
REVOKE ALL ON FUNCTION public.create_public_order(
  uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_public_order(
  uuid, text, text, text, text, text, text, jsonb
) TO service_role;

-- Pruebas requeridas: dos carritos concurrentes con los mismos productos
-- en orden inverso, última unidad disponible, producto de otro negocio,
-- carrito inválido, y movimiento de venta con motivo y delta correctos.

  ) THEN
    RAISE EXCEPTION 'Producto o cantidad inválidos.';
  END IF;

  -- Bloquear productos siempre por UUID ascendente. Dos carritos que contengan
  -- los mismos productos en distinto orden adquieren los locks en el mismo orden.
  FOR v_item IN
    SELECT value
    FROM JSONB_ARRAY_ELEMENTS(p_items)
    ORDER BY (value->>'product_id')::uuid
  LOOP
    IF COALESCE(v_item->>'product_id','')
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR COALESCE(v_item->>'quantity','')
        !~ '^[1-9][0-9]*$' THEN
      RAISE EXCEPTION 'Producto o cantidad inválidos.';
    END IF;

    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;

    IF v_quantity > 99 THEN
      RAISE EXCEPTION 'La cantidad por producto no puede superar 99.';
    END IF;

    SELECT *
    INTO v_product
    FROM public.products
    WHERE id = v_product_id
      AND business_id = p_business_id
      AND is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Uno de los productos no está disponible.';
    END IF;

    IF v_product.inventory < v_quantity THEN
      RAISE EXCEPTION 'No hay inventario suficiente para: %', v_product.name;
    END IF;

    SELECT pc.cost_price
    INTO v_unit_cost
    FROM public.product_costs AS pc
    WHERE pc.product_id = v_product.id
      AND pc.business_id = p_business_id;

    v_subtotal := v_subtotal + (v_product.price * v_quantity);

    v_snapshot := v_snapshot || JSONB_BUILD_ARRAY(
      JSONB_BUILD_OBJECT(
        'product_id', v_product.id,
        'product_name', v_product.name,
        'quantity', v_quantity,
        'unit_price', v_product.price,
        'unit_cost', v_unit_cost
      )
    );
  END LOOP;

  IF v_subtotal < v_business.minimum_order_amount THEN
    RAISE EXCEPTION 'El pedido no alcanza el valor mínimo del negocio.';
  END IF;

  v_total := v_subtotal + v_business.delivery_fee;

  INSERT INTO public.orders (
    business_id, customer_name, customer_phone, customer_email,
    delivery_address, delivery_notes, payment_method, payment_status,
    status, subtotal, delivery_fee, total
  )
  VALUES (
    p_business_id,
    TRIM(p_customer_name),
    TRIM(p_customer_phone),
    NULLIF(TRIM(COALESCE(p_customer_email, '')), ''),
    TRIM(p_delivery_address),
    NULLIF(TRIM(COALESCE(p_delivery_notes, '')), ''),
    p_payment_method,
    'pending',
    'pending',
    v_subtotal,
    v_business.delivery_fee,
    v_total
  )
  RETURNING * INTO v_order;

  FOR v_item IN
    SELECT value FROM JSONB_ARRAY_ELEMENTS(v_snapshot)
  LOOP
    INSERT INTO public.order_items (
      order_id, product_id, product_name, quantity, unit_price
    )
    VALUES (
      v_order.id,
      (v_item->>'product_id')::uuid,
      v_item->>'product_name',
      (v_item->>'quantity')::integer,
      (v_item->>'unit_price')::numeric
    )
    RETURNING id INTO v_order_item_id;

    INSERT INTO public.order_item_costs (
      order_item_id, order_id, business_id, unit_cost
    )
    VALUES (
      v_order_item_id,
      v_order.id,
      p_business_id,
      NULLIF(v_item->>'unit_cost', '')::numeric
    );

    PERFORM pg_catalog.set_config(
      'app.inventory_movement_reason',
      'Venta mediante pedido ' || v_order.id::text,
      true
    );

    UPDATE public.products
    SET inventory = inventory - (v_item->>'quantity')::integer
    WHERE id = (v_item->>'product_id')::uuid
      AND business_id = p_business_id;
  END LOOP;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  )
  VALUES (
    p_business_id,
    NULL,
    'order.created',
    'order',
    v_order.id::text,
    JSONB_BUILD_OBJECT(
      'order_number', v_order.order_number,
      'total', v_order.total,
      'source', 'public_storefront'
    )
  );

  RETURN JSONB_BUILD_OBJECT(
    'id', v_order.id,
    'order_number', v_order.order_number,
    'status', v_order.status,
    'total', v_order.total,
    'public_tracking_token', v_order.public_tracking_token
  );
END;
$function$;

-- La firma conserva el permiso de ejecución actual (solo service_role).
REVOKE ALL ON FUNCTION public.create_public_order(
  uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_public_order(
  uuid, text, text, text, text, text, text, jsonb
) TO service_role;

-- Pruebas requeridas: dos carritos concurrentes con los mismos productos
-- en orden inverso, última unidad disponible, producto de otro negocio,
-- carrito inválido, y movimiento de venta con motivo y delta correctos.
