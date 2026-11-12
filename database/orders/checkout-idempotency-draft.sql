-- Borrador: protección idempotente del checkout público.
-- No ejecutar hasta revisar y autorizar la migración completa.

CREATE TABLE IF NOT EXISTS private.checkout_idempotency (
  idempotency_key uuid PRIMARY KEY,
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  request_hash text NOT NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE private.checkout_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.checkout_idempotency FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_public_order_idempotent(
  p_idempotency_key uuid,
  p_ip text,
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
  v_request_hash text;
  v_existing_hash text;
  v_existing_response jsonb;
  v_response jsonb;
  v_allowed boolean;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Se requiere una clave de pedido válida.';
  END IF;

  v_request_hash := md5(jsonb_build_object(
    'business_id', p_business_id,
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

  -- Solo los intentos nuevos consumen el límite por IP.
  v_allowed := public.consume_checkout_rate_limit(p_ip);
  IF v_allowed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Se recibieron demasiadas solicitudes. Espera unos minutos e inténtalo de nuevo.';
  END IF;

  v_response := public.create_public_order(
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
  uuid, text, uuid, text, text, text, text, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_public_order_idempotent(
  uuid, text, uuid, text, text, text, text, text, text, jsonb
) TO service_role;

-- Pruebas posteriores en staging:
-- 1) Misma clave + mismo contenido => devuelve el mismo pedido y no descuenta stock otra vez.
-- 2) Dos llamadas simultáneas con misma clave => solo un pedido.
-- 3) Misma clave + contenido distinto => conflicto, sin crear otro pedido.
-- 4) Clave nueva => consume límite IP y crea un pedido normal.
-- 5) Error de inventario => transacción revertida y clave disponible para corregir/reintentar.
