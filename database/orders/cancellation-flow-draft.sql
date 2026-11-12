-- MiEje Market Independiente
-- Flujo transaccional propuesto para solicitudes de cancelación y devolución de inventario.
-- ESTADO: BORRADOR PARA REVISIÓN. No ejecutar en producción sin pruebas controladas.
--
-- Reglas:
-- 1) Un miembro activo del negocio (admin o empleado) registra el motivo comunicado
--    por el cliente. La solicitud queda pendiente.
-- 2) Solo el business_admin de ese negocio puede aprobar o rechazar.
-- 3) La aprobación cambia el pedido a cancelled y devuelve inventario en la misma
--    transacción. Si una operación falla, PostgreSQL revierte todo.
-- 4) El trigger existente enforce_order_status_transition exige que la solicitud
--    aprobada y decided_by coincidan con auth.uid(); este flujo respeta esa regla.
-- 5) No procesa reembolsos. Si el pedido ya estaba pagado, el reembolso debe
--    registrarse y completarse mediante un flujo financiero separado.

CREATE UNIQUE INDEX IF NOT EXISTS order_cancellation_one_pending_per_order
ON public.order_cancellation_requests (business_id, order_id)
WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.request_order_cancellation(
  p_business_id uuid,
  p_order_id uuid,
  p_customer_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_order public.orders%ROWTYPE;
  v_request public.order_cancellation_requests%ROWTYPE;
  v_reason text := pg_catalog.btrim(p_customer_reason);
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
  END IF;

  IF p_customer_reason IS NULL OR pg_catalog.char_length(v_reason) < 5 OR pg_catalog.char_length(v_reason) > 2000 THEN
    RAISE EXCEPTION 'El motivo debe tener entre 5 y 2000 caracteres.' USING ERRCODE = '22023';
  END IF;

  IF NOT private.business_is_active(p_business_id)
     OR NOT private.has_business_role(p_business_id, ARRAY['business_admin','employee']::text[]) THEN
    RAISE EXCEPTION 'No tienes permiso para solicitar la cancelación en este negocio.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el pedido en este negocio.' USING ERRCODE = 'P0002';
  END IF;

  IF v_order.status IN ('delivered','cancelled') THEN
    RAISE EXCEPTION 'No se puede solicitar la cancelación de un pedido terminado.' USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.order_cancellation_requests
    WHERE business_id = p_business_id
      AND order_id = p_order_id
      AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'Este pedido ya tiene una solicitud de cancelación pendiente.' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.order_cancellation_requests (
    business_id, order_id, customer_reason, status, forwarded_by, forwarded_at
  ) VALUES (
    p_business_id, p_order_id, v_reason, 'pending', v_actor, pg_catalog.now()
  )
  RETURNING * INTO v_request;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    p_business_id, v_actor, 'order.cancellation_requested',
    'order_cancellation_request', v_request.id::text,
    pg_catalog.jsonb_build_object('order_id', p_order_id, 'reason', v_reason)
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true, 'request_id', v_request.id, 'status', v_request.status
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.decide_order_cancellation(
  p_request_id uuid,
  p_decision text,
  p_admin_response text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_request record;
  v_response text := NULLIF(pg_catalog.btrim(p_admin_response), '');
  v_restored_products integer := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Debes iniciar sesión.' USING ERRCODE = '42501';
  END IF;

  IF p_decision IS NULL OR p_decision NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'La decisión debe ser approved o rejected.' USING ERRCODE = '22023';
  END IF;

  IF v_response IS NOT NULL AND pg_catalog.char_length(v_response) > 2000 THEN
    RAISE EXCEPTION 'La respuesta no puede superar 2000 caracteres.' USING ERRCODE = '22023';
  END IF;

  SELECT r.id, r.business_id, r.order_id, r.status AS request_status,
         o.status AS order_status
  INTO v_request
  FROM public.order_cancellation_requests r
  JOIN public.orders o
    ON o.id = r.order_id AND o.business_id = r.business_id
  WHERE r.id = p_request_id
  FOR UPDATE OF r, o;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la solicitud.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT private.business_is_active(v_request.business_id)
     OR NOT private.has_business_role(v_request.business_id, ARRAY['business_admin']::text[]) THEN
    RAISE EXCEPTION 'Solo el administrador activo de este negocio puede decidir la solicitud.' USING ERRCODE = '42501';
  END IF;

  IF v_request.request_status <> 'pending' THEN
    RAISE EXCEPTION 'Esta solicitud ya fue atendida.' USING ERRCODE = '23514';
  END IF;

  IF v_request.order_status IN ('delivered','cancelled') THEN
    RAISE EXCEPTION 'El pedido ya terminó y no puede cancelarse.' USING ERRCODE = '23514';
  END IF;

  UPDATE public.order_cancellation_requests
  SET status = p_decision,
      decided_by = v_actor,
      decided_at = pg_catalog.now(),
      admin_response = v_response,
      updated_at = pg_catalog.now()
  WHERE id = p_request_id;

  IF p_decision = 'approved' THEN
    -- El trigger existente valida que la solicitud aprobada la haya decidido
    -- exactamente el usuario que está cambiando el estado del pedido.
    UPDATE public.orders
    SET status = 'cancelled'
    WHERE id = v_request.order_id
      AND business_id = v_request.business_id;

    -- Restituir las unidades una sola vez, dentro de la misma transacción.
    WITH quantities AS (
      SELECT oi.product_id, pg_catalog.sum(oi.quantity)::integer AS quantity
      FROM public.order_items oi
      WHERE oi.order_id = v_request.order_id
        AND oi.product_id IS NOT NULL
      GROUP BY oi.product_id
    )
    UPDATE public.products p
    SET inventory = p.inventory + quantities.quantity,
        updated_at = pg_catalog.now()
    FROM quantities
    WHERE p.id = quantities.product_id
      AND p.business_id = v_request.business_id;

    GET DIAGNOSTICS v_restored_products = ROW_COUNT;
  END IF;

  INSERT INTO public.audit_logs (
    business_id, actor_id, action, entity_type, entity_id, details
  ) VALUES (
    v_request.business_id, v_actor,
    CASE WHEN p_decision = 'approved'
      THEN 'order.cancellation_approved'
      ELSE 'order.cancellation_rejected' END,
    'order_cancellation_request', p_request_id::text,
    pg_catalog.jsonb_build_object(
      'order_id', v_request.order_id,
      'decision', p_decision,
      'admin_response', v_response,
      'restored_products', v_restored_products
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'request_id', p_request_id,
    'order_id', v_request.order_id,
    'status', p_decision,
    'restored_products', v_restored_products
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.request_order_cancellation(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_order_cancellation(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.request_order_cancellation(uuid, uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.decide_order_cancellation(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decide_order_cancellation(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.decide_order_cancellation(uuid, text, text) TO authenticated;

-- PRUEBAS OBLIGATORIAS ANTES DE DESPLEGAR:
-- - solicitud por empleado/admin de negocio correcto;
-- - solicitud rechazada por usuario de otro negocio;
-- - aprobación solo por business_admin;
-- - rechazo sin tocar inventario;
-- - aprobación restaura cantidades exactas;
-- - segundo intento de aprobación falla y no duplica inventario;
-- - pedido entregado/cancelado no se puede cancelar;
-- - pedido pagado queda pendiente de reembolso manual y no se marca refunded aquí.
