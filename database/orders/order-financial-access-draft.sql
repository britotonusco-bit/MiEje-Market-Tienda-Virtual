-- MiEje Market Independiente
-- Acceso financiero separado para administradores y clientes.
-- ESTADO: BORRADOR. Ejecutar solo después de checkout-idempotency-draft.sql
-- en un entorno de ensayo, nunca directamente en producción sin pruebas.
--
-- Motivo:
-- PostgreSQL/Supabase aplica GRANT por columna a todo el rol authenticated.
-- Una política RLS de fila no puede ocultar total/payment_status a empleados
-- y mostrárselos a administradores usando el mismo rol. Por eso se retiran
-- los importes de las consultas directas y se entregan mediante RPCs que
-- validan el rol de negocio o la propiedad del pedido.

CREATE OR REPLACE FUNCTION public.get_business_admin_order_financials(
  p_business_id uuid,
  p_refundable_only boolean DEFAULT false,
  p_limit integer DEFAULT 10000
)
RETURNS TABLE (
  order_id uuid,
  order_number bigint,
  subtotal numeric,
  delivery_fee numeric,
  total numeric,
  payment_status text,
  status text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 10000), 10000));
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
  END IF;

  IF NOT private.business_is_active(p_business_id)
     OR NOT private.has_business_role(p_business_id, ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador activo de este negocio puede consultar sus datos financieros.'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT o.id, o.order_number, o.subtotal, o.delivery_fee, o.total,
         o.payment_status, o.status, o.created_at
  FROM public.orders o
  WHERE o.business_id = p_business_id
    AND (
      NOT p_refundable_only
      OR (o.status = 'cancelled' AND o.payment_status = 'paid')
    )
  ORDER BY o.created_at DESC
  LIMIT v_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_business_admin_order_financials(uuid, boolean, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_admin_order_financials(uuid, boolean, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_business_admin_order_financials(uuid, boolean, integer) TO authenticated;


CREATE OR REPLACE FUNCTION public.get_customer_order_history()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión para consultar tu historial.' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_actor AND p.is_blocked = true
  ) THEN
    RAISE EXCEPTION 'La cuenta no tiene acceso al historial.' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', owned.id,
        'order_number', owned.order_number,
        'status', owned.status,
        'payment_status', owned.payment_status,
        'subtotal', owned.subtotal,
        'delivery_fee', owned.delivery_fee,
        'total', owned.total,
        'created_at', owned.created_at,
        'business_name', owned.business_name,
        'items', (
          SELECT coalesce(
            jsonb_agg(
              jsonb_build_object(
                'product_name', oi.product_name,
                'quantity', oi.quantity,
                'unit_price', oi.unit_price,
                'line_total', coalesce(oi.line_total, oi.unit_price * oi.quantity)
              ) ORDER BY oi.created_at
            ),
            '[]'::jsonb
          )
          FROM public.order_items oi
          WHERE oi.order_id = owned.id
        )
      ) ORDER BY owned.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_result
  FROM (
    SELECT o.id, o.order_number, o.status, o.payment_status,
           o.subtotal, o.delivery_fee, o.total, o.created_at,
           b.name AS business_name
    FROM public.orders o
    JOIN public.businesses b ON b.id = o.business_id
    WHERE o.customer_user_id = v_actor
    ORDER BY o.created_at DESC
    LIMIT 50
  ) owned;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_customer_order_history() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_customer_order_history() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_customer_order_history() TO authenticated;


-- Retirar SELECT general y grants por columna anteriores antes de conceder
-- únicamente los campos operativos que pueden consultar administradores y
-- empleados. Los importes y el estado del pago quedan detrás de RPCs.
REVOKE SELECT ON TABLE public.orders FROM PUBLIC, anon, authenticated;
REVOKE SELECT (
  id, business_id, order_number, customer_name, customer_phone, customer_email,
  delivery_address, delivery_notes, payment_method, payment_status, status,
  delivery_tracking, subtotal, delivery_fee, total, public_tracking_token,
  created_at, updated_at, customer_user_id
) ON TABLE public.orders FROM PUBLIC, anon, authenticated;

GRANT SELECT (
  id, business_id, order_number, customer_name, customer_phone,
  delivery_address, delivery_notes, payment_method, status,
  delivery_tracking, created_at, updated_at
) ON TABLE public.orders TO authenticated;


-- Los empleados y administradores solo necesitan nombres y cantidades para
-- preparar pedidos. Los precios de las líneas se devuelven al cliente dueño
-- del pedido mediante get_customer_order_history().
REVOKE SELECT ON TABLE public.order_items FROM PUBLIC, anon, authenticated;
REVOKE SELECT (
  id, order_id, product_id, product_name, quantity, unit_price,
  line_total, created_at
) ON TABLE public.order_items FROM PUBLIC, anon, authenticated;

GRANT SELECT (
  id, order_id, product_id, product_name, quantity, created_at
) ON TABLE public.order_items TO authenticated;


-- PRUEBAS OBLIGATORIAS EN ENSAYO:
-- 1) Un empleado no puede leer orders.total, subtotal, delivery_fee ni payment_status.
-- 2) Un empleado no puede leer order_items.unit_price ni line_total.
-- 3) Un administrador del negocio A obtiene finanzas de A, pero no de B.
-- 4) Un empleado y un cliente no pueden ejecutar el RPC financiero de negocio.
-- 5) Un cliente solo obtiene historial propio y precios de sus propios pedidos.
-- 6) Un cliente no puede consultar historial ajeno, incluso con IDs conocidos.
-- 7) El panel técnico no obtiene finanzas por estos RPCs.
-- 8) Checkout, tracking público, paneles y cuenta siguen funcionando con grants reducidos.
