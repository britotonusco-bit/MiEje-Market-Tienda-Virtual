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
  payment_method text,
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
         o.payment_method, o.payment_status, o.status, o.created_at
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


-- Confirmación manual del dinero realmente recibido. No conecta con bancos ni
-- pasarelas: el administrador confirma un pago externo ya recibido.
CREATE UNIQUE INDEX IF NOT EXISTS financial_one_completed_payment_per_order
ON public.financial_transactions (business_id, order_id)
WHERE transaction_type = 'payment_received' AND status = 'completed';

CREATE OR REPLACE FUNCTION public.mark_order_payment_received(
  p_order_id uuid,
  p_provider text DEFAULT NULL,
  p_reference text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_order public.orders%ROWTYPE;
  v_provider text := NULLIF(pg_catalog.btrim(p_provider), '');
  v_reference text := NULLIF(pg_catalog.btrim(p_reference), '');
  v_notes text := NULLIF(pg_catalog.btrim(p_notes), '');
  v_transaction_id uuid;
  v_updated integer := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
  END IF;

  IF v_provider IS NOT NULL AND pg_catalog.char_length(v_provider) > 120 THEN
    RAISE EXCEPTION 'El proveedor no puede superar 120 caracteres.' USING ERRCODE = '22023';
  END IF;
  IF v_reference IS NOT NULL AND pg_catalog.char_length(v_reference) > 160 THEN
    RAISE EXCEPTION 'La referencia no puede superar 160 caracteres.' USING ERRCODE = '22023';
  END IF;
  IF v_notes IS NOT NULL AND pg_catalog.char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'Las notas no pueden superar 2000 caracteres.' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el pedido.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT private.business_is_active(v_order.business_id)
     OR NOT private.has_business_role(v_order.business_id, ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador activo de este negocio puede confirmar pagos.' USING ERRCODE = '42501';
  END IF;

  IF v_order.status = 'cancelled' OR v_order.payment_status IN ('refunded','failed') THEN
    RAISE EXCEPTION 'No se puede registrar un pago para un pedido cancelado, fallido o reembolsado.' USING ERRCODE = '23514';
  END IF;

  IF v_order.payment_status <> 'pending' THEN
    RAISE EXCEPTION 'El pedido no tiene un pago pendiente de confirmación.' USING ERRCODE = '23514';
  END IF;

  IF v_order.total <= 0 THEN
    RAISE EXCEPTION 'El pedido no tiene un importe positivo para registrar como recibido.' USING ERRCODE = '23514';
  END IF;

  IF v_order.payment_method <> 'cash' AND v_reference IS NULL THEN
    RAISE EXCEPTION 'Para pagos que no son en efectivo debes registrar una referencia o comprobante.' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.financial_transactions (
    business_id, order_id, transaction_type, status, amount, currency,
    payment_method, provider, transaction_reference, description,
    registered_by, completed_at
  ) VALUES (
    v_order.business_id, v_order.id, 'payment_received', 'completed',
    v_order.total, 'COP', v_order.payment_method, v_provider,
    v_reference, 'Pago recibido y confirmado por el administrador del negocio.',
    v_actor, pg_catalog.now()
  )
  RETURNING id INTO v_transaction_id;

  UPDATE public.orders
  SET payment_status = 'paid'
  WHERE id = v_order.id
    AND business_id = v_order.business_id
    AND payment_status = 'pending';

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'El estado del pago cambió. No se registró el ingreso.' USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_order.business_id, v_actor, 'order.payment_received',
    'financial_transaction', v_transaction_id::text,
    pg_catalog.jsonb_build_object(
      'order_id', v_order.id,
      'amount', v_order.total,
      'currency', 'COP',
      'payment_method', v_order.payment_method,
      'provider', v_provider,
      'reference', v_reference,
      'notes', v_notes
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id,
    'order_id', v_order.id,
    'payment_status', 'paid',
    'amount', v_order.total
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_order_payment_received(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_order_payment_received(uuid, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_order_payment_received(uuid, text, text, text) TO authenticated;


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


-- La política de order_items no debe exigir que el cliente tenga SELECT
-- directo sobre orders.customer_user_id. La comprobación de propiedad se hace
-- mediante una función SECURITY DEFINER y no expone ese identificador interno.
CREATE OR REPLACE FUNCTION private.customer_owns_order(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = p_order_id
      AND o.customer_user_id = auth.uid()
  );
$function$;

REVOKE ALL ON FUNCTION private.customer_owns_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.customer_owns_order(uuid) TO authenticated;

DROP POLICY IF EXISTS order_items_customer_select_own ON public.order_items;
CREATE POLICY order_items_customer_select_own
ON public.order_items
FOR SELECT
TO authenticated
USING (private.customer_owns_order(order_id));


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



-- Índices parciales para reportes por fecha real de movimiento (no created_at).
CREATE INDEX IF NOT EXISTS idx_financial_completed_business_type_date
ON public.financial_transactions (business_id, transaction_type, completed_at)
WHERE status = 'completed' AND completed_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_business_expenses_paid_at
ON public.business_expenses (business_id, paid_at)
WHERE status = 'active' AND payment_status = 'paid' AND paid_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.get_business_admin_profit_report(
  p_business_id uuid, p_start_date date, p_end_date date
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501'; END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date < p_start_date OR p_end_date - p_start_date > 366 THEN
    RAISE EXCEPTION 'Selecciona un periodo válido de hasta 367 días.' USING ERRCODE = '22023';
  END IF;
  IF NOT private.business_is_active(p_business_id)
     OR NOT private.has_business_role(p_business_id, ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador activo del negocio puede consultar este reporte.' USING ERRCODE = '42501';
  END IF;
  WITH period_payments AS (
    SELECT ft.order_id, sum(ft.amount)::numeric(14,2) amount
    FROM public.financial_transactions ft
    WHERE ft.business_id=p_business_id AND ft.transaction_type='payment_received'
      AND ft.status='completed'
      AND ft.completed_at >= (p_start_date::timestamp AT TIME ZONE 'America/Bogota')
      AND ft.completed_at < ((p_end_date + 1)::timestamp AT TIME ZONE 'America/Bogota')
    GROUP BY ft.order_id
  ),
  period_refunds AS (
    SELECT COALESCE(sum(ft.amount),0)::numeric(14,2) amount
    FROM public.financial_transactions ft
    WHERE ft.business_id=p_business_id AND ft.transaction_type='refund'
      AND ft.status='completed'
      AND ft.completed_at >= (p_start_date::timestamp AT TIME ZONE 'America/Bogota')
      AND ft.completed_at < ((p_end_date + 1)::timestamp AT TIME ZONE 'America/Bogota')
  ),
  cost_movements AS (
    SELECT oi.id AS order_item_id, oic.unit_cost, oi.quantity, 1::integer AS direction
    FROM period_payments pp
    JOIN public.orders o ON o.id=pp.order_id AND o.business_id=p_business_id
    JOIN public.order_items oi ON oi.order_id=o.id
    LEFT JOIN public.order_item_costs oic ON oic.order_item_id=oi.id
      AND oic.order_id=o.id AND oic.business_id=p_business_id
    UNION ALL
    SELECT oi.id AS order_item_id, oic.unit_cost, oi.quantity, -1::integer AS direction
    FROM public.order_cancellation_requests cr
    JOIN public.orders o ON o.id=cr.order_id AND o.business_id=cr.business_id
    JOIN public.order_items oi ON oi.order_id=o.id
    LEFT JOIN public.order_item_costs oic ON oic.order_item_id=oi.id
      AND oic.order_id=o.id AND oic.business_id=p_business_id
    WHERE cr.business_id=p_business_id AND cr.status='approved'
      AND cr.decided_at IS NOT NULL
      AND (cr.decided_at AT TIME ZONE 'America/Bogota')::date BETWEEN p_start_date AND p_end_date
      AND EXISTS (
        SELECT 1 FROM public.financial_transactions paid
        WHERE paid.business_id=p_business_id AND paid.order_id=o.id
          AND paid.transaction_type='payment_received' AND paid.status='completed'
      )
  ),
  cost_totals AS (
    SELECT
      COALESCE(sum(unit_cost*quantity) FILTER (WHERE unit_cost IS NOT NULL AND direction=1),0)::numeric(14,2) gross_cost,
      COALESCE(sum(unit_cost*quantity) FILTER (WHERE unit_cost IS NOT NULL AND direction=-1),0)::numeric(14,2) inventory_cost_reversals,
      COALESCE(sum(unit_cost*quantity*direction) FILTER (WHERE unit_cost IS NOT NULL),0)::numeric(14,2) net_cost,
      count(DISTINCT order_item_id) FILTER (WHERE unit_cost IS NULL)::integer missing_cost_lines
    FROM cost_movements
  ),
  expense_totals AS (
    SELECT COALESCE(sum(be.amount),0)::numeric(14,2) amount
    FROM public.business_expenses be
    WHERE be.business_id=p_business_id AND be.status='active'
      AND be.payment_status='paid' AND be.paid_at IS NOT NULL
      AND be.paid_at >= (p_start_date::timestamp AT TIME ZONE 'America/Bogota')
      AND be.paid_at < ((p_end_date + 1)::timestamp AT TIME ZONE 'America/Bogota')
  ),
  totals AS (
    SELECT
      COALESCE((SELECT sum(amount) FROM period_payments),0)::numeric(14,2) sales,
      (SELECT amount FROM period_refunds) refunds,
      (SELECT gross_cost FROM cost_totals) gross_cost,
      (SELECT inventory_cost_reversals FROM cost_totals) inventory_cost_reversals,
      (SELECT net_cost FROM cost_totals) cost_of_sales,
      (SELECT missing_cost_lines FROM cost_totals) missing_cost_lines,
      (SELECT amount FROM expense_totals) paid_expenses,
      (SELECT count(*) FROM period_payments)::integer paid_orders
  )
  SELECT jsonb_build_object(
    'start_date',p_start_date,'end_date',p_end_date,'sales',sales,'refunds',refunds,
    'net_sales',sales-refunds,'gross_cost_of_sales',gross_cost,
    'inventory_cost_reversals',inventory_cost_reversals,'cost_of_sales',cost_of_sales,
    'gross_profit_estimate',sales-refunds-cost_of_sales,
    'paid_expenses',paid_expenses,
    'net_profit_estimate',sales-refunds-cost_of_sales-paid_expenses,
    'missing_cost_lines',missing_cost_lines,'paid_orders',paid_orders,
    'complete_cost_data',missing_cost_lines=0,
    'basis','Reporte de movimientos por fecha de confirmación en hora Bogotá: pagos, reembolsos, aprobaciones de cancelación que restituyen inventario y gastos pagados. El costo se reconoce con el pago y se revierte al aprobar una cancelación pagada. Resultado estimado, no estado contable certificado.'
  ) INTO v_result FROM totals;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_business_admin_profit_report(uuid,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_business_admin_profit_report(uuid,date,date) TO authenticated;

-- PRUEBAS OBLIGATORIAS EN ENSAYO:
-- 1) Un empleado no puede leer orders.total, subtotal, delivery_fee ni payment_status.
-- 2) Un empleado no puede leer order_items.unit_price ni line_total.
-- 3) Un administrador del negocio A obtiene finanzas de A, pero no de B.
-- 4) Un empleado y un cliente no pueden ejecutar el RPC financiero de negocio.
-- 5) Un cliente solo obtiene historial propio y precios de sus propios pedidos.
-- 6) Un cliente no puede consultar historial ajeno, incluso con IDs conocidos.
-- 7) El panel técnico no obtiene finanzas por estos RPCs.
-- 8) Checkout, tracking público, paneles y cuenta siguen funcionando con grants reducidos.
