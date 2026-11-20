-- MiEje Market: diagnóstico de conciliación comercial (solo lectura)
-- Ejecutar únicamente en un entorno autorizado. Todas las sentencias son SELECT.
-- Cero filas significa que no hay anomalías detectables en el conjunto consultado;
-- si las tablas están vacías, NO demuestra que el flujo funcional esté probado.

-- 1. Volumen de tablas principales.
SELECT 'businesses' AS table_name, count(*)::bigint AS rows FROM public.businesses
UNION ALL SELECT 'products', count(*) FROM public.products
UNION ALL SELECT 'orders', count(*) FROM public.orders
UNION ALL SELECT 'order_items', count(*) FROM public.order_items
UNION ALL SELECT 'financial_transactions', count(*) FROM public.financial_transactions
UNION ALL SELECT 'refund_details', count(*) FROM public.refund_details
UNION ALL SELECT 'product_costs', count(*) FROM public.product_costs
UNION ALL SELECT 'order_item_costs', count(*) FROM public.order_item_costs
UNION ALL SELECT 'business_expenses', count(*) FROM public.business_expenses;

-- 2. Líneas cuyo total no coincide con cantidad por precio unitario.
SELECT id, order_id, quantity, unit_price, line_total
FROM public.order_items
WHERE line_total IS DISTINCT FROM quantity * unit_price;

-- 3. Pedidos cuyo subtotal no coincide con la suma de sus líneas.
SELECT o.id, o.business_id, o.subtotal,
       COALESCE(sum(oi.line_total), 0) AS calculated_subtotal
FROM public.orders o
LEFT JOIN public.order_items oi ON oi.order_id = o.id
GROUP BY o.id, o.business_id, o.subtotal
HAVING o.subtotal IS DISTINCT FROM COALESCE(sum(oi.line_total), 0);

-- 4. Pedidos cuyo total no coincide con subtotal más domicilio.
SELECT id, business_id, subtotal, delivery_fee, total
FROM public.orders
WHERE total IS DISTINCT FROM subtotal + delivery_fee;

-- 5. Pagos completados cuyo negocio/orden no coincide (la FK compuesta debería impedirlo).
SELECT ft.id, ft.business_id, ft.order_id, o.business_id AS order_business_id
FROM public.financial_transactions ft
LEFT JOIN public.orders o ON o.id = ft.order_id
WHERE o.id IS NULL OR o.business_id IS DISTINCT FROM ft.business_id;

-- 6. Reembolsos cuyo negocio/orden no coincide con el detalle de transacción.
SELECT rd.id, rd.business_id, rd.order_id, rd.financial_transaction_id,
       ft.business_id AS transaction_business_id, ft.order_id AS transaction_order_id
FROM public.refund_details rd
LEFT JOIN public.financial_transactions ft ON ft.id = rd.financial_transaction_id
WHERE ft.id IS NULL
   OR ft.business_id IS DISTINCT FROM rd.business_id
   OR ft.order_id IS DISTINCT FROM rd.order_id;

-- 7. Costes snapshot sin línea o con negocio/pedido discordante.
SELECT c.order_item_id, c.order_id, c.business_id,
       oi.order_id AS item_order_id, o.business_id AS order_business_id
FROM public.order_item_costs c
LEFT JOIN public.order_items oi ON oi.id = c.order_item_id
LEFT JOIN public.orders o ON o.id = c.order_id
WHERE oi.id IS NULL
   OR o.id IS NULL
   OR oi.order_id IS DISTINCT FROM c.order_id
   OR o.business_id IS DISTINCT FROM c.business_id;

-- 8. Productos con stock negativo (la CHECK constraint debe impedirlo).
SELECT id, business_id, inventory
FROM public.products
WHERE inventory < 0;

-- Nota: la base activa consultada no tiene public.inventory_movements.
-- Por eso no se incluye una conciliación de ledger hasta que exista en staging.
