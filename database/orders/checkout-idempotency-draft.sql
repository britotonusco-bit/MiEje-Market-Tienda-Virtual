-- Borrador: protección idempotente del checkout público y funciones de clientes.
-- No ejecutar hasta revisar y autorizar la migración completa.

-- Método concreto seleccionado por el cliente. El nombre queda congelado
-- como histórico aunque el negocio renombre/desactive/elimine el método.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS payment_method_id uuid,
  ADD COLUMN IF NOT EXISTS payment_method_name text;

DO $payment_method_fk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.orders'::regclass
      AND conname = 'orders_payment_method_id_fkey'
  ) THEN
    ALTER TABLE public.orders
      ADD CONSTRAINT orders_payment_method_id_fkey
      FOREIGN KEY (payment_method_id)
      REFERENCES public.business_payment_methods(id)
      ON DELETE SET NULL;
  END IF;
END;
$payment_method_fk$;

CREATE INDEX IF NOT EXISTS orders_business_payment_method_idx
  ON public.orders (business_id, payment_method_id)
  WHERE payment_method_id IS NOT NULL;

-- customer-account-migration.sql (paso 8) es la única fuente de verdad
-- para customer_user_id, su índice y la tabla customer_favorites.
-- Aquí solo se ajustan las políticas de favoritos y las políticas de lectura
-- necesarias para el historial de pedidos.
DROP POLICY IF EXISTS customer_favorites_select_own ON public.customer_favorites;
CREATE POLICY customer_favorites_select_own ON public.customer_favorites
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

-- Mantener una sola política de INSERT para evitar reglas duplicadas que se
-- combinen mediante OR después de aplicar customer-account-migration.sql.
DROP POLICY IF EXISTS customer_favorites_insert_own ON public.customer_favorites;
DROP POLICY IF EXISTS customer_favorites_insert_own_active_product ON public.customer_favorites;
CREATE POLICY customer_favorites_insert_own_active_product ON public.customer_favorites
  FOR INSERT TO authenticated WITH CHECK (
    user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.products p
      WHERE p.id = customer_favorites.product_id
        AND p.is_active = true
        AND (SELECT private.business_is_active(p.business_id))
    )
  );

DROP POLICY IF EXISTS customer_favorites_delete_own ON public.customer_favorites;
CREATE POLICY customer_favorites_delete_own ON public.customer_favorites
  FOR DELETE TO authenticated USING (user_id = (SELECT auth.uid()));

-- El historial muestra el nombre del negocio, pero no expone su ficha privada.
GRANT SELECT (id, name) ON public.businesses TO authenticated;
DROP POLICY IF EXISTS businesses_customer_order_name_select ON public.businesses;
CREATE POLICY businesses_customer_order_name_select ON public.businesses
  FOR SELECT TO authenticated USING (status = 'active');

DROP POLICY IF EXISTS orders_customer_select_own ON public.orders;
CREATE POLICY orders_customer_select_own ON public.orders
  FOR SELECT TO authenticated USING (customer_user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS order_items_customer_select_own ON public.order_items;
CREATE POLICY order_items_customer_select_own ON public.order_items
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND o.customer_user_id = (SELECT auth.uid())
    )
  );

-- Crea el pedido y conserva el método exacto elegido. La Edge Function
-- nunca proporciona el nombre snapshot: se obtiene de la fila validada aquí.
CREATE OR REPLACE FUNCTION public.create_public_order_for_customer_with_payment_method(
  p_customer_user_id uuid,
  p_business_id uuid,
  p_payment_method_id uuid,
  p_payment_method text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_delivery_address text,
  p_delivery_notes text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_method public.business_payment_methods%ROWTYPE;
  v_order jsonb;
  v_order_id uuid;
BEGIN
  IF p_payment_method_id IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'Debes seleccionar un método de pago válido.';
  END IF;

  SELECT *
  INTO v_method
  FROM public.business_payment_methods
  WHERE id = p_payment_method_id
    AND business_id = p_business_id
    AND is_enabled = true
  FOR SHARE;

  IF NOT FOUND OR v_method.method_code <> p_payment_method THEN
    RAISE EXCEPTION 'El método de pago ya no está disponible. Actualiza la tienda y vuelve a intentarlo.';
  END IF;

  v_order := public.create_public_order(
    p_business_id,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_delivery_address,
    p_delivery_notes,
    p_payment_method,
    p_items
  );

  v_order_id := (v_order->>'id')::uuid;

  UPDATE public.orders
  SET payment_method_id = v_method.id,
      payment_method_name = v_method.display_name,
      customer_user_id = p_customer_user_id
  WHERE id = v_order_id
    AND business_id = p_business_id
    AND customer_user_id IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No fue posible guardar el método de pago del pedido.';
  END IF;

  RETURN v_order || jsonb_build_object('payment_method_name', v_method.display_name);
END;
$function$;

REVOKE ALL ON FUNCTION public.create_public_order_for_customer_with_payment_method(
  uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_public_order_for_customer_with_payment_method(
  uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) TO service_role;

-- La cuenta autenticada se asigna solo después de validar el JWT en la Edge Function.
CREATE OR REPLACE FUNCTION public.create_public_order_for_customer(
  p_customer_user_id uuid,
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
  v_order jsonb;
  v_order_id uuid;
BEGIN
  v_order := public.create_public_order(
    p_business_id,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_delivery_address,
    p_delivery_notes,
    p_payment_method,
    p_items
  );

  IF p_customer_user_id IS NOT NULL THEN
    v_order_id := (v_order->>'id')::uuid;
    UPDATE public.orders
    SET customer_user_id = p_customer_user_id
    WHERE id = v_order_id
      AND business_id = p_business_id
      AND customer_user_id IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'No fue posible vincular el pedido con la cuenta del cliente.';
    END IF;
  END IF;

  RETURN v_order;
END;
$function$;

-- Revocar después de crear la función: esta firma no existe en el esquema live.
REVOKE ALL ON FUNCTION public.create_public_order_for_customer(
  uuid, uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_public_order_for_customer(
  uuid, uuid, text, text, text, text, text, text, jsonb
) TO service_role;


CREATE TABLE IF NOT EXISTS private.checkout_idempotency (
  idempotency_key uuid PRIMARY KEY,
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  request_hash text NOT NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.checkout_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.checkout_idempotency FROM PUBLIC, anon, authenticated, service_role;


-- Consulta previa para que un reintento ya completado recupere el pedido
-- original sin consumir nuevamente el límite de solicitudes por IP.
CREATE OR REPLACE FUNCTION public.get_public_order_idempotent(
  p_idempotency_key uuid,
  p_business_id uuid,
  p_payment_method_id uuid,
  p_customer_user_id uuid,
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
  v_request_hash text;
  v_existing_hash text;
  v_existing_response jsonb;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Se requiere una clave de pedido válida.';
  END IF;

  v_request_hash := pg_catalog.encode(extensions.digest(jsonb_build_object(
    'business_id', p_business_id,
    'payment_method_id', p_payment_method_id,
    'customer_user_id', p_customer_user_id,
    'customer_name', p_customer_name,
    'customer_phone', p_customer_phone,
    'customer_email', p_customer_email,
    'delivery_address', p_delivery_address,
    'delivery_notes', p_delivery_notes,
    'payment_method', p_payment_method,
    'items', p_items
  )::text, 'sha256'), 'hex');

  SELECT request_hash, response
  INTO v_existing_hash, v_existing_response
  FROM private.checkout_idempotency
  WHERE idempotency_key = p_idempotency_key;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_existing_hash <> v_request_hash THEN
    RAISE EXCEPTION 'La clave de este intento ya fue usada con datos diferentes. Actualiza el checkout e inténtalo nuevamente.';
  END IF;

  RETURN v_existing_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_order_idempotent(
  uuid, uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_order_idempotent(
  uuid, uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) TO service_role;

-- Reserva de intentos en una transacción independiente al pedido.
-- Así, los intentos fallidos también cuentan, pero reintentar la misma clave
-- con el mismo contenido no consume una segunda reserva.
CREATE TABLE IF NOT EXISTS private.checkout_rate_limit_reservations (
  idempotency_key uuid NOT NULL,
  ip_hash text NOT NULL,
  request_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (idempotency_key, ip_hash)
);

ALTER TABLE private.checkout_rate_limit_reservations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.checkout_rate_limit_reservations
  FROM PUBLIC, anon, authenticated, service_role;

-- Índices para que el conteo por IP y la limpieza de reservas antiguas
-- no recorran toda la tabla cuando aumente el volumen de compras.
CREATE INDEX IF NOT EXISTS checkout_rate_reservations_ip_created_idx
  ON private.checkout_rate_limit_reservations (ip_hash, created_at DESC);
CREATE INDEX IF NOT EXISTS checkout_rate_reservations_created_idx
  ON private.checkout_rate_limit_reservations (created_at);

CREATE OR REPLACE FUNCTION public.reserve_checkout_rate_limit(
  p_idempotency_key uuid,
  p_ip text,
  p_business_id uuid,
  p_payment_method_id uuid,
  p_customer_user_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_delivery_address text,
  p_delivery_notes text,
  p_payment_method text,
  p_items jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_ip_hash text;
  v_request_hash text;
  v_existing_request_hash text;
  v_count integer;
BEGIN
  IF p_idempotency_key IS NULL
     OR p_ip IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_ip)) < 3
     OR pg_catalog.length(p_ip) > 100 THEN
    RETURN false;
  END IF;

  v_ip_hash := pg_catalog.encode(
    extensions.digest(pg_catalog.btrim(p_ip), 'sha256'), 'hex'
  );
  v_request_hash := pg_catalog.encode(extensions.digest(pg_catalog.jsonb_build_object(
    'business_id', p_business_id,
    'payment_method_id', p_payment_method_id,
    'customer_user_id', p_customer_user_id,
    'customer_name', p_customer_name,
    'customer_phone', p_customer_phone,
    'customer_email', p_customer_email,
    'delivery_address', p_delivery_address,
    'delivery_notes', p_delivery_notes,
    'payment_method', p_payment_method,
    'items', p_items
  )::text, 'sha256'), 'hex');

  -- Serializar por clave y después por IP para evitar reservas duplicadas
  -- y que solicitudes concurrentes sobrepasen el límite.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );
  DELETE FROM private.checkout_rate_limit_reservations
  WHERE idempotency_key = p_idempotency_key
    AND created_at < pg_catalog.now() - interval '24 hours';

  -- Una misma clave solo puede representar un contenido. Si el cliente cambia
  -- de red, se crea una reserva adicional para la IP nueva, sin borrar la
  -- reserva anterior ni consumir dos veces el intento en la misma IP.
  SELECT request_hash
    INTO v_existing_request_hash
  FROM private.checkout_rate_limit_reservations
  WHERE idempotency_key = p_idempotency_key
  ORDER BY created_at DESC
  LIMIT 1;

  IF FOUND AND v_existing_request_hash <> v_request_hash THEN
    RAISE EXCEPTION 'La clave de este intento ya fue reservada con datos diferentes.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM private.checkout_rate_limit_reservations
    WHERE idempotency_key = p_idempotency_key
      AND ip_hash = v_ip_hash
      AND request_hash = v_request_hash
  ) THEN
    RETURN true;
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_ip_hash, 0)
  );

  DELETE FROM private.checkout_rate_limit_reservations
  WHERE created_at < pg_catalog.now() - interval '24 hours';

  SELECT pg_catalog.count(*)::integer
    INTO v_count
  FROM private.checkout_rate_limit_reservations
  WHERE ip_hash = v_ip_hash
    AND created_at >= pg_catalog.now() - interval '10 minutes';

  IF v_count >= 10 THEN
    RETURN false;
  END IF;

  INSERT INTO private.checkout_rate_limit_reservations (
    idempotency_key, ip_hash, request_hash
  ) VALUES (
    p_idempotency_key, v_ip_hash, v_request_hash
  );

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.reserve_checkout_rate_limit(
  uuid, text, uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_checkout_rate_limit(
  uuid, text, uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) TO service_role;

CREATE OR REPLACE FUNCTION public.create_public_order_idempotent(
  p_idempotency_key uuid,
  p_ip text,
  p_business_id uuid,
  p_payment_method_id uuid,
  p_customer_user_id uuid,
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
  v_request_hash text;
  v_existing_hash text;
  v_existing_response jsonb;
  v_response jsonb;
  v_ip_hash text;
  v_reserved_ip_hash text;
  v_reserved_request_hash text;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Se requiere una clave de pedido válida.';
  END IF;

  v_request_hash := pg_catalog.encode(extensions.digest(jsonb_build_object(
    'business_id', p_business_id,
    'payment_method_id', p_payment_method_id,
    'customer_user_id', p_customer_user_id,
    'customer_name', p_customer_name,
    'customer_phone', p_customer_phone,
    'customer_email', p_customer_email,
    'delivery_address', p_delivery_address,
    'delivery_notes', p_delivery_notes,
    'payment_method', p_payment_method,
    'items', p_items
  )::text, 'sha256'), 'hex');

  -- Serializa solicitudes simultáneas con la misma clave.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 0));

  SELECT request_hash, response
  INTO v_existing_hash, v_existing_response
  FROM private.checkout_idempotency
  WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_existing_hash <> v_request_hash THEN
      RAISE EXCEPTION 'La clave de este intento ya fue usada con datos diferentes. Actualiza el checkout e inténtalo nuevamente.';
    END IF;
    RETURN v_existing_response;
  END IF;

  -- Exigir la reserva de IP creada por reserve_checkout_rate_limit().
  -- La RPC de creación no debe poder ejecutarse saltándose el límite.
  IF p_ip IS NULL OR pg_catalog.length(pg_catalog.btrim(p_ip)) < 3
     OR pg_catalog.length(p_ip) > 100 THEN
    RAISE EXCEPTION 'No fue posible validar el origen de la solicitud.';
  END IF;

  v_ip_hash := pg_catalog.encode(
    extensions.digest(pg_catalog.btrim(p_ip), 'sha256'), 'hex'
  );

  SELECT ip_hash, request_hash
  INTO v_reserved_ip_hash, v_reserved_request_hash
  FROM private.checkout_rate_limit_reservations
  WHERE idempotency_key = p_idempotency_key
    AND ip_hash = v_ip_hash
  FOR UPDATE;

  IF NOT FOUND
     OR v_reserved_ip_hash <> v_ip_hash
     OR v_reserved_request_hash <> v_request_hash THEN
    RAISE EXCEPTION 'El intento no tiene una reserva de seguridad válida. Vuelve a iniciar el checkout.';
  END IF;

  v_response := public.create_public_order_for_customer_with_payment_method(
    p_customer_user_id,
    p_business_id,
    p_payment_method_id,
    p_payment_method,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_delivery_address,
    p_delivery_notes,
    p_items
  );

  INSERT INTO private.checkout_idempotency (
    idempotency_key, business_id, request_hash, response
  )
  VALUES (
    p_idempotency_key, p_business_id, v_request_hash, v_response
  );

  RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_public_order_idempotent(
  uuid, text, uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_public_order_idempotent(
  uuid, text, uuid, uuid, uuid, text, text, text, text, text, text, jsonb
) TO service_role;

-- Pruebas posteriores en staging:
-- 1) Misma clave + mismo contenido => devuelve el mismo pedido y no descuenta stock otra vez.
-- 2) Dos llamadas simultáneas con misma clave => solo un pedido.
-- 3) Misma clave + contenido distinto => conflicto, sin crear otro pedido.
-- 4) Clave nueva => reserve_checkout_rate_limit registra el intento en una transacción
--    independiente; create_public_order_idempotent exige esa reserva antes de crear el pedido.
-- 5) Error de inventario => se revierte la transacción del pedido/idempotencia, pero la
--    reserva IP permanece para que el intento fallido cuente en el límite. La misma clave
--    y contenido puede reintentarse sin consumir otra reserva.
