-- MiEje Market Independiente
-- Línea base única para productos que ya existían antes de instalar el historial.
-- BORRADOR: ejecutar solo después de instalar inventory-movements-draft.sql
-- y con autorización expresa. La transacción bloquea productos para evitar
-- que un ajuste concurrente quede fuera de la línea base.

BEGIN;

LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;

INSERT INTO public.inventory_movements (
  business_id,
  product_id,
  actor_id,
  movement_type,
  quantity_before,
  quantity_after,
  quantity_delta,
  reason
)
SELECT
  p.business_id,
  p.id,
  NULL,
  'initial',
  0,
  p.inventory,
  p.inventory,
  'Saldo inicial al activar el historial de inventario'
FROM public.products p
WHERE p.inventory > 0
  AND NOT EXISTS (
    SELECT 1
    FROM public.inventory_movements im
    WHERE im.business_id = p.business_id
      AND im.product_id = p.id
  );

COMMIT;

-- Idempotencia: volver a ejecutar no crea otra línea base para productos
-- que ya tengan al menos un movimiento.
