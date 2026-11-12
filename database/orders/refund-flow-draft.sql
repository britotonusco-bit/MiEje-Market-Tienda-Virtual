-- MiEje Market Independiente
-- Registro de reembolso total para pedidos cancelados que ya fueron pagados.
-- BORRADOR: no ejecutar hasta revisar y probar en entorno controlado.
--
-- Este procedimiento NO transfiere dinero ni se conecta a una pasarela.
-- Solo registra que el negocio ya realizó el reembolso por fuera de MiEje.
-- No almacena números completos de cuentas ni datos bancarios del cliente.
-- No admite reembolsos parciales en esta primera versión.

CREATE UNIQUE INDEX IF NOT EXISTS financial_one_completed_refund_per_order
ON public.financial_transactions (business_id, order_id)
WHERE transaction_type = 'refund' AND status = 'completed';

CREATE OR REPLACE FUNCTION public.complete_order_refund(
  p_order_id uuid,
  p_refund_method text,
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
  v_request_id uuid;
  v_transaction_id uuid;
  v_method text := pg_catalog.btrim(p_refund_method);
  v_provider text := NULLIF(pg_catalog.btrim(p_provider), '');
  v_reference text := NULLIF(pg_catalog.btrim(p_reference), '');
  v_notes text := NULLIF(pg_catalog.btrim(p_notes), '');
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
  END IF;

  IF p_refund_method IS NULL OR v_method = '' OR pg_catalog.char_length(v_method) > 80 THEN
    RAISE EXCEPTION 'Indica un medio de reembolso válido.' USING ERRCODE = '22023';
  END IF;
  IF v_provider IS NOT NULL AND pg_catalog.char_length(v_provider) > 120 THEN
    RAISE EXCEPTION 'El proveedor no puede superar 120 caracteres.' USING ERRCODE = '22023';
  END IF;
  IF v_reference IS NULL OR pg_catalog.char_length(v_reference) > 160 THEN
    RAISE EXCEPTION 'Registra una referencia o comprobante del reembolso.' USING ERRCODE = '22023';
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
    RAISE EXCEPTION 'Solo el administrador activo del negocio puede registrar reembolsos.' USING ERRCODE = '42501';
  END IF;

  IF v_order.status <> 'cancelled' THEN
    RAISE EXCEPTION 'Solo se pueden reembolsar pedidos cancelados.' USING ERRCODE = '23514';
  END IF;

  IF v_order.payment_status <> 'paid' THEN
    RAISE EXCEPTION 'El pedido no figura como pagado. No se debe registrar un reembolso.' USING ERRCODE = '23514';
  END IF;

  SELECT r.id INTO v_request_id
  FROM public.order_cancellation_requests r
  WHERE r.business_id = v_order.business_id
    AND r.order_id = v_order.id
    AND r.status = 'approved'
  ORDER BY r.decided_at DESC NULLS LAST, r.created_at DESC
  LIMIT 1;

  IF v_request_id IS NULL THEN
    RAISE EXCEPTION 'El pedido no tiene una solicitud de cancelación aprobada.' USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.financial_transactions ft
    WHERE ft.business_id = v_order.business_id
      AND ft.order_id = v_order.id
      AND ft.transaction_type = 'refund'
      AND ft.status = 'completed'
  ) THEN
    RAISE EXCEPTION 'Este pedido ya tiene un reembolso completado.' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.financial_transactions (
    business_id, order_id, cancellation_request_id,
    transaction_type, status, amount, currency,
    payment_method, provider, transaction_reference,
    description, registered_by, completed_at
  ) VALUES (
    v_order.business_id, v_order.id, v_request_id,
    'refund', 'completed', v_order.total, 'COP',
    v_method, v_provider, v_reference,
    'Reembolso total registrado por el administrador del negocio.',
    v_actor, pg_catalog.now()
  )
  RETURNING id INTO v_transaction_id;

  INSERT INTO public.refund_details (
    financial_transaction_id, business_id, order_id,
    refund_method, receiving_provider, refund_reference,
    registered_by, refund_completed_at, notes
  ) VALUES (
    v_transaction_id, v_order.business_id, v_order.id,
    v_method, v_provider, v_reference,
    v_actor, pg_catalog.now(), v_notes
  );

  UPDATE public.orders
  SET payment_status = 'refunded'
  WHERE id = v_order.id AND business_id = v_order.business_id;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_order.business_id, v_actor, 'order.refund_completed',
    'financial_transaction', v_transaction_id::text,
    pg_catalog.jsonb_build_object(
      'order_id', v_order.id,
      'amount', v_order.total,
      'currency', 'COP',
      'refund_method', v_method,
      'provider', v_provider,
      'reference', v_reference
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'transaction_id', v_transaction_id,
    'order_id', v_order.id,
    'amount', v_order.total,
    'payment_status', 'refunded'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_order_refund(uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_order_refund(uuid, text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.complete_order_refund(uuid, text, text, text, text) TO authenticated;

-- PRUEBAS ANTES DE DESPLEGAR:
-- - admin del negocio correcto puede registrar un reembolso total;
-- - empleado y admin de otro negocio reciben rechazo;
-- - pedido no cancelado o no pagado recibe rechazo;
-- - solicitud de cancelación no aprobada recibe rechazo;
-- - un segundo reembolso para el mismo pedido recibe rechazo;
-- - financial_transactions, refund_details, orders y audit_logs cambian
--   dentro de una sola transacción;
-- - comprobar que no se marcan como refunded pedidos cuyo pago estaba pendiente.
