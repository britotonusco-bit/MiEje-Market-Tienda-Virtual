-- Borrador: protección idempotente del checkout público y funciones de clientes.
-- No ejecutar hasta revisar y autorizar la migración completa.

-- Vinculación de pedidos con clientes autenticados y favoritos.
-- Los pedidos de invitados conservan customer_user_id = NULL.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS customer_user_id uuid
  REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS orders_customer_user_created_idx
  ON public.orders (customer_user_id, created_at DESC)
  WHERE customer_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.customer_favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_favorites_user_product_unique UNIQUE (user_id, product_id)
);

ALTER TABLE public.customer_favorites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.customer_favorites FROM PUBLIC, anon, authenticated;
GRANT SELECT, DELETE ON TABLE public.customer_favorites TO authenticated;
GRANT INSERT (user_id, product_id) ON TABLE public.customer_favorites TO authenticated;

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

REVOKE ALL ON FUNCTION public.create_public_order_for_customer(
  uuid, uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
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

  v_request_hash := md5(jsonb_build_object(
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
  )::text);

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
  idempotency_key uuid PRIMARY KEY,
  ip_hash text NOT NULL,
  request_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.checkout_rate_limit_reservations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.checkout_rate_limit_reservations
  FROM PUBLIC, anon, authenticated, service_role;

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
  v_existing_ip_hash text;
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
  v_request_hash := pg_catalog.md5(pg_catalog.jsonb_build_object(
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
  )::text);

  -- Serializar por clave y después por IP para evitar reservas duplicadas
  -- y que solicitudes concurrentes sobrepasen el límite.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_idempotency_key::text, 0)
  );
  DELETE FROM private.checkout_rate_limit_reservations
  WHERE idempotency_key = p_idempotency_key
    AND created_at < pg_catalog.now() - interval '24 hours';

  SELECT ip_hash, request_hash
    INTO v_existing_ip_hash, v_existing_request_hash
  FROM private.checkout_rate_limit_reservations
  WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_existing_ip_hash <> v_ip_hash OR v_existing_request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'La clave de este intento ya fue reservada con datos diferentes.';
    END IF;
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
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Se requiere una clave de pedido válida.';
  END IF;

  v_request_hash := md5(jsonb_build_object(
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
  )::text);

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

  -- La reserva de IP se realiza antes, mediante una RPC independiente.
  -- Aquí solo se valida el formato; no se consume otra vez el límite.
  IF p_ip IS NULL OR pg_catalog.length(pg_catalog.btrim(p_ip)) < 3
     OR pg_catalog.length(p_ip) > 100 THEN
    RAISE EXCEPTION 'No fue posible validar el origen de la solicitud.';
  END IF;

  v_response := public.create_public_order_for_customer(
    p_customer_user_id,
    p_business_id,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_delivery_address,
    p_delivery_notes,
    p_payment_method,
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
-- 4) Clave nueva => consume exactamente una vez el límite IP dentro de la transacción.
-- 5) Error de inventario => transacción revertida y clave disponible para corregir/reintentar.
