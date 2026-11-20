# Auditoría de integridad y conciliación comercial

**Fecha de revisión:** 20 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Proyecto consultado:** `MiEje Market Independiente` (`cqixlrwbqatbhzmpygiz`)  
**PostgreSQL:** 17.11.0.003  
**Alcance:** inspección de esquema, restricciones y conteos mediante consultas SELECT.  
**Producción:** no se ejecutaron escrituras, migraciones ni cambios de configuración.

## ACC-26 — Estado real de los datos comerciales

### 1. Resultado de conteos

Las siguientes tablas existen en el esquema público y devolvieron cero registros al momento de la consulta:

| Tabla | Filas |
|---|---:|
| businesses | 0 |
| products | 0 |
| orders | 0 |
| order_items | 0 |
| financial_transactions | 0 |
| refund_details | 0 |
| product_costs | 0 |
| order_item_costs | 0 |
| business_expenses | 0 |

Por tanto, **no hay operaciones comerciales reales en este proyecto con las que se pueda hacer una conciliación de importes o inventario**. Los resultados de discrepancias sobre estas tablas no se pueden considerar aprobados: cero filas no demuestra que las reglas funcionen con datos reales.

### 2. Restricciones confirmadas en la base activa

Se consultaron las definiciones reales de `pg_constraint`. Las restricciones siguientes existen y están validadas:

- `orders`: importes no negativos, estados de pedido y pago limitados a los valores permitidos, método de pago restringido, clave única por negocio y número de pedido, y token de seguimiento único.
- `order_items`: cantidad mayor que cero, precio unitario no negativo y FK hacia pedido con `ON DELETE RESTRICT`.
- `financial_transactions`: importe positivo, tipos/estados restringidos y FK compuesta `(business_id, order_id)` hacia `orders(business_id, id)`.
- `refund_details`: relación compuesta con el pedido y con la transacción financiera, y una sola fila de detalle por transacción financiera.
- `product_costs`: FK compuesta `(business_id, product_id)` hacia el producto del mismo negocio.
- `order_item_costs`: FK compuesta al pedido y a la línea de pedido; el coste histórico puede ser NULL, pero no negativo.
- `business_expenses`: importe positivo, estados de pago y anulación coherentes, y relación con el negocio.

Estas restricciones aportan protección referencial, pero no prueban por sí solas la lógica transaccional de los RPC ni la autorización RLS.

### 3. Diferencia detectada: eliminación de productos y líneas históricas

En la base activa, la FK `order_items_product_id_fkey` está definida como:

`FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE SET NULL`

En el diseño de la rama `correcciones-funcionales`, el objetivo documentado para la conservación de líneas históricas es `ON DELETE RESTRICT`, junto con snapshots de nombre y precio. La base activa todavía no coincide con ese diseño.

**Riesgo:** al borrar un producto, se puede perder el vínculo de la línea histórica con el producto original. Aunque nombre y precio snapshot se conservan, se debilita la trazabilidad de inventario/costes.

**Estado:** diferencia confirmada por inspección de esquema. No hay filas en `orders` ni `order_items`, así que no se detectó pérdida de datos histórica en esta revisión. No se modificó la FK.

### 4. Ledger de inventario no presente en la base activa

La lista de tablas públicas no contiene `inventory_movements`. En auditorías anteriores, el ledger y sus controles de inmutabilidad se encontraban en borradores SQL de la rama, no aplicados a la base activa.

**Impacto:** todavía no es posible conciliar el stock actual de cada producto contra un registro persistente de entradas, salidas, ventas, cancelaciones y ajustes manuales en esta base. El campo `products.inventory` existe y tiene una restricción que impide valores negativos, pero eso no sustituye un ledger.

### 5. Límites de esta revisión

- No se evaluaron importes reales porque las tablas comerciales consultadas están vacías.
- No se probaron transacciones concurrentes, rollback, checkout, cancelación ni reembolso.
- No se ejecutaron RPC ni se validaron permisos RLS con usuarios de prueba.
- No se puede confirmar que las funciones financieras funcionen correctamente solo por observar restricciones.
- La tabla `financial_transactions` existe, pero no contiene pagos reales; no debe confundirse su existencia con una pasarela o conciliación bancaria activa.

## ACC-26 — Criterios de conciliación que deben aprobarse en staging

### Pedidos y líneas
- Para cada pedido, `subtotal` debe ser igual a la suma de `order_items.line_total`.
- Cada `line_total` debe ser igual a `quantity * unit_price`.
- `total` debe ser igual a `subtotal + delivery_fee`, salvo que se implemente y documente explícitamente otro componente de precio.
- Todas las líneas deben pertenecer al mismo pedido y negocio; producto asociado, si existe, debe pertenecer al mismo negocio.
- Las líneas históricas deben conservarse aunque el producto deje de venderse.

### Pagos y reembolsos
- Una confirmación de pago debe generar un único movimiento financiero completado por pedido y negocio.
- El importe y moneda deben coincidir con el total y moneda del pedido.
- Un reembolso debe referenciar el pedido y el movimiento financiero correcto, no exceder el pago completado y no duplicarse.
- El estado del pedido y el estado financiero deben ser coherentes, pero mantenerse como conceptos separados.
- Los errores y reintentos no deben duplicar cargos ni reembolsos.

### Inventario
- Cada venta confirmada debe reflejar exactamente la salida de unidades esperada.
- Cancelaciones aprobadas deben reponer solo las unidades previamente descontadas.
- Los ajustes manuales deben registrar actor, motivo, cantidad anterior/nueva y negocio.
- La suma del ledger debe cuadrar con el stock actual; diferencias deben producir una alerta y no corregirse silenciosamente.
- El stock nunca puede ser negativo.

### Costes y ganancias
- Los snapshots de coste de cada línea no deben cambiar al modificar el coste actual del producto.
- Los informes deben separar ingresos cobrados, pagos pendientes, reembolsos y gastos pagados.
- Si faltan snapshots de coste, la ganancia debe mostrarse como no calculable/incompleta, no como cero.
- Cada consulta debe filtrar por negocio y rechazar IDs de otro negocio.

## Acciones pendientes antes de aprobar ACC-26

1. Resolver mediante migración revisada en staging la diferencia de FK de `order_items.product_id`; confirmar que no existen referencias históricas que impidan cambiarla.
2. Aplicar y verificar el ledger `inventory_movements` en staging, incluyendo triggers, RPC y restricciones de acceso.
3. Preparar dos negocios ficticios, productos, costes y pedidos de prueba; no usar información personal real.
4. Ejecutar los verificadores SQL y casos de concurrencia/rollback en staging.
5. Conciliar un pedido pagado, un pedido cancelado, un reembolso y un ajuste de inventario.
6. Comprobar que los administradores de cada negocio no puedan leer ni alterar los registros del otro.
7. Repetir los conteos y diagnósticos después de las pruebas, y guardar evidencia sanitizada.

## Dictamen

La estructura activa contiene varias restricciones útiles para proteger la integridad entre negocio, pedido, pago, reembolso y costes. Sin embargo, los datos comerciales consultados están vacíos, el ledger de inventario no existe en la base activa y la FK de producto en líneas históricas todavía usa `ON DELETE SET NULL`, en vez del comportamiento `RESTRICT` previsto en la rama.

**ACC-26 queda parcialmente auditado, no aprobado funcionalmente.** La validación definitiva requiere datos sintéticos y pruebas transaccionales en staging. No se modificó la base activa.
