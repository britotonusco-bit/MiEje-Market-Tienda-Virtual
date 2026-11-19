-- MiEje Market Independiente
-- VERIFICACIÓN SOLO LECTURA del saldo de inventario frente al libro de movimientos.
-- Ejecutar después de instalar los triggers y, para productos preexistentes,
-- después de inventory-ledger-baseline-draft.sql.
--
-- Resultado esperado: cero filas con status = 'MISMATCH'.
-- La consulta no modifica datos.

WITH ledger AS (
  SELECT
    business_id,
    product_id,
    COUNT(*)::bigint AS movement_count,
    COALESCE(SUM(quantity_delta), 0)::bigint AS ledger_inventory,
    MIN(created_at) AS first_movement_at,
    MAX(created_at) AS last_movement_at
  FROM public.inventory_movements
  GROUP BY business_id, product_id
)
SELECT
  p.business_id,
  p.id AS product_id,
  p.name AS product_name,
  p.inventory AS current_inventory,
  COALESCE(l.ledger_inventory, 0)::bigint AS ledger_inventory,
  COALESCE(l.movement_count, 0)::bigint AS movement_count,
  l.first_movement_at,
  l.last_movement_at,
  CASE
    WHEN p.inventory::bigint = COALESCE(l.ledger_inventory, 0)
      THEN 'OK'
    ELSE 'MISMATCH'
  END AS status,
  p.inventory::bigint - COALESCE(l.ledger_inventory, 0) AS difference
FROM public.products p
LEFT JOIN ledger l
  ON l.business_id = p.business_id
 AND l.product_id = p.id
ORDER BY
  CASE WHEN p.inventory::bigint <> COALESCE(l.ledger_inventory, 0) THEN 0 ELSE 1 END,
  p.business_id,
  p.name;

-- Resumen de movimientos con dirección incompatible.
-- Debe devolver cero.
SELECT
  id,
  business_id,
  product_id,
  movement_type,
  quantity_before,
  quantity_after,
  quantity_delta,
  created_at
FROM public.inventory_movements
WHERE NOT (
  (movement_type = 'initial' AND quantity_delta > 0)
  OR (movement_type = 'sale' AND quantity_delta < 0)
  OR (movement_type = 'cancellation_return' AND quantity_delta > 0)
  OR (movement_type = 'adjustment' AND quantity_delta <> 0)
)
ORDER BY created_at DESC;
