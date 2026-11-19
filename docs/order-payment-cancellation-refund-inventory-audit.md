# Auditoría del flujo de pagos, cancelaciones, inventario y reembolsos

**Fecha:** 16/11/2026  
**Rama:** `correcciones-funcionales`  
**Estado:** revisión estática y contraste de esquema activo en modo lectura. No equivale a pruebas funcionales en staging.

## Alcance

Se revisaron los borradores:
- `database/orders/order-financial-access-draft.sql`
- `database/orders/cancellation-flow-draft.sql`
- `database/orders/refund-flow-draft.sql`
- `database/inventory/inventory-movements-draft.sql`
- `database/inventory/checkout-inventory-lock-order-draft.sql`
- `database/orders/checkout-idempotency-draft.sql`

También se consultó el esquema activo del proyecto independiente en modo lectura. No se ejecutaron migraciones ni escrituras.

## Hallazgos confirmados

### 1. Confirmación de pago

La RPC candidata `mark_order_payment_received`:
- bloquea el pedido con `FOR UPDATE`;
- exige membresía activa de tipo `business_admin` en el negocio del pedido;
- rechaza pedidos cancelados, fallidos, reembolsados o cuyo pago ya no esté pendiente;
- registra el movimiento financiero y actualiza `payment_status` dentro de la misma transacción;
- exige referencia para métodos que no sean efectivo;
- deja auditoría y revierte toda la operación si falla una de las escrituras.

La migración crea un índice único parcial para impedir dos movimientos `payment_received/completed` para el mismo pedido.

### 2. Cancelación y restitución de inventario

Las RPC candidatas:
- permiten que administrador o empleado activo solicite la cancelación;
- reservan la decisión al administrador activo del mismo negocio;
- bloquean primero el pedido y luego la solicitud, siguiendo un orden coherente entre ambas operaciones;
- impiden aprobar dos veces la misma solicitud;
- cambian el estado del pedido y restituyen existencias en la misma transacción;
- usan el trigger de movimientos de inventario para dejar el delta y el motivo de la restitución;
- revierten el conjunto completo si no se pueden restituir todos los productos.

El trigger de estado exige una solicitud aprobada por el mismo usuario que cambia el pedido a `cancelled`. La aprobación no cambia el estado de pago: un pedido que ya estaba pagado conserva ese dato para permitir la conciliación y el reembolso posterior.

### 3. Reembolsos

La RPC candidata `complete_order_refund`:
- solo admite administradores activos del negocio;
- exige pedido cancelado y pago marcado como recibido;
- concilia exactamente un movimiento de pago completado en COP cuyo importe coincida con el total;
- exige una solicitud de cancelación aprobada;
- registra el movimiento de reembolso, su detalle, el cambio a `payment_status='refunded'` y la auditoría dentro de una sola transacción;
- crea un índice único parcial para impedir más de un reembolso completado por pedido.

El procedimiento no mueve dinero ni se conecta a una pasarela: registra que el negocio ya realizó el reembolso fuera de MiEje Market. La interfaz debe mantener esa aclaración visible.

### 4. Inventario

La migración candidata:
- registra movimientos iniciales, ajustes, ventas y devoluciones por cancelación;
- mantiene la relación del producto con su negocio mediante una FK compuesta;
- impide borrar productos referenciados por líneas de pedido;
- restringe la lectura del historial al administrador del negocio;
- impide escrituras directas del historial desde roles de cliente;
- usa bloqueo de fila y valor esperado para evitar que un ajuste de inventario sobrescriba una venta concurrente.

### 5. Contraste con el esquema activo

La consulta de solo lectura confirmó que las tablas activas `financial_transactions`, `refund_details` y `order_cancellation_requests` tienen las columnas utilizadas por los borradores, y que existen restricciones de importe positivo, estados/tipos permitidos y relaciones entre negocio, pedido, cancelación y reembolso.

También se confirmó:
- existe el índice de una solicitud de cancelación pendiente por pedido;
- el esquema activo todavía no contiene el índice único parcial de un pago completado por pedido ni el índice único parcial de un reembolso completado por pedido;
- los índices candidatos de esos dos flujos están en las migraciones, no en el esquema activo.

## Riesgos y condiciones pendientes

1. **No hay staging disponible.** No se puede certificar concurrencia, rollback, comportamiento de triggers ni compatibilidad real de todas las migraciones.
2. **Reembolso externo.** La RPC registra una operación ya realizada; no debe presentarse como una transferencia automática ni como confirmación de una pasarela.
3. **Referencia y notas.** El panel debe pedir referencias/comprobantes sin almacenar números completos de cuenta, credenciales ni datos bancarios innecesarios. Las notas deben evitar información personal sensible.
4. **Prueba de concurrencia obligatoria.** En staging, ejecutar dos confirmaciones de pago simultáneas, dos decisiones de cancelación simultáneas y dos intentos de reembolso simultáneos para el mismo pedido.
5. **Prueba de aislamiento A/B.** Administrador A, empleado A y administrador B deben intentar cada operación sobre pedidos de ambos negocios. Todas las acciones cruzadas deben rechazarse.
6. **Prueba de inventario.** Comparar cantidades y movimientos antes/después de venta, cancelación aprobada, cancelación rechazada y error inducido. Cada operación debe producir exactamente un movimiento por producto afectado.
7. **Moneda.** El modelo actual de pedidos y las RPC revisadas trabajan con COP. Si se habilitan otras monedas, no basta con cambiar el texto de la interfaz: debe persistirse y conciliarse la moneda real del pedido y de cada movimiento.

## Resultado

**Revisión estática favorable, pruebas de ejecución pendientes.** No se encontró una razón suficiente para modificar estos SQL en esta pasada; no se hicieron cambios a las migraciones. El siguiente paso seguro es ejecutar el paquete completo en un proyecto de ensayo separado y completar la matriz de pruebas antes de integrar.

No se ejecutó SQL, no se modificó Supabase, no se desplegaron Edge Functions, no se fusionó ningún PR y no se publicó GitHub Pages.


## 8. Gastos pagados y reportes históricos

Se detectó que el borrador permitía anular gastos pagados. El reporte financiero suma únicamente gastos activos y pagados; por tanto, anular uno pagado lo retiraba del histórico sin registrar un movimiento compensatorio. La corrección restringe la anulación a gastos pendientes tanto en la RPC como en el trigger de protección. El verificador de integración exige ambas barreras. Para corregir un gasto que ya fue pagado se necesitará un flujo separado de reversión con referencia, motivo y auditoría; no debe simularse mediante anulación.


## 9. Costos históricos incompletos y ganancias estimadas

El reporte agrega los costos guardados por línea de pedido. Si alguna línea no tiene `order_item_costs.unit_cost`, el costo de ventas queda subestimado si se interpreta el valor faltante como cero. Se ajustó el borrador para que `gross_profit_estimate` y `net_profit_estimate` devuelvan `NULL` cuando `missing_cost_lines` sea mayor que cero. El informe conserva el conteo de líneas sin costo y la marca `complete_cost_data`. Así se evita mostrar una ganancia numérica engañosa.


## 10. Inmutabilidad del costo histórico por línea

La inspección de solo lectura del esquema activo confirmó que `order_item_costs` tiene una fila como máximo por línea de pedido (PK `order_item_id`) y claves foráneas compuestas que vinculan la fila con el pedido y su negocio. También permite `unit_cost IS NULL`, condición que el reporte identifica como costo faltante. No había triggers en esa tabla y el rol `service_role` tenía privilegios de UPDATE, DELETE y TRUNCATE.

Se añadió al borrador de límites de negocio un trigger que rechaza UPDATE y DELETE sobre snapshots, además de revocar esos privilegios y TRUNCATE a `service_role`. El checkout conserva INSERT para crear la fotografía original dentro de la transacción. El verificador ahora exige el trigger y la ausencia de esos privilegios.

La tabla `product_costs` conserva el costo vigente del producto y puede actualizarse por el administrador del negocio. Esa actualización no modifica la fila histórica de `order_item_costs`. No se ejecutó esta protección en la base activa; debe probarse en staging.


## 11. Hallazgo confirmado en el esquema activo: bypass técnico en políticas de costos

La consulta de solo lectura al proyecto Supabase independiente encontró que las políticas activas `product_costs_admin_select`, `product_costs_admin_insert`, `product_costs_admin_update` y `order_item_costs_admin_select` todavía incluyen `private.is_platform_owner()`. Esto concede al propietario técnico acceso directo global a costos de negocios, contrario al límite previsto. El borrador de `business-admin-boundaries.sql` recrea esas políticas sin el bypass; no se ha aplicado a la base activa.

Se amplió el verificador para revisar tanto `USING` (`qual`) como `WITH CHECK`, y para incluir las políticas INSERT y UPDATE de `product_costs`. La verificación anterior solo revisaba `qual` y podía dejar pasar un bypass en `WITH CHECK`.

La consulta también confirmó que `order_item_costs` no tiene triggers y que `service_role` conserva UPDATE, DELETE y TRUNCATE. El borrador ahora instala el trigger de inmutabilidad y revoca esos privilegios. No se ejecutaron cambios en Supabase.


## 12. Conciliación por fecha efectiva y presentación de costos faltantes

La lectura estática del reporte confirmó que:
- los cobros y reembolsos se agrupan por la fecha de confirmación financiera `financial_transactions.completed_at`;
- la reversión del costo de inventario se ubica en la fecha de decisión de la cancelación `order_cancellation_requests.decided_at`;
- los gastos solo entran cuando están pagados y se filtran por `business_expenses.paid_at`;
- los límites de cada periodo se calculan con la zona horaria `America/Bogota`, incluyendo el día final mediante un límite superior exclusivo.

El índice único parcial `order_cancellation_one_approved_per_order` impide que un pedido genere más de una cancelación aprobada y, por tanto, que la reversión de su costo se contabilice dos veces. Los índices únicos de pagos y reembolsos completados también forman parte de las protecciones requeridas.

Se detectó un problema de presentación: el RPC devuelve `NULL` para la ganancia bruta y neta cuando faltan costos históricos, pero el formateador monetario del panel convertía ese `NULL` en `$0`. Se corrigió la interfaz para mostrar **“No disponible”** en esos dos indicadores y explicar que el resultado no debe interpretarse como cero. Los importes de cobros, reembolsos y costos siguen visibles para facilitar la conciliación.

El verificador de integración ahora exige las tres fechas efectivas y la zona horaria Bogotá, además de comprobar la definición del índice único de cancelaciones aprobadas. Esto es una comprobación estática del SQL, no una prueba de ejecución.

**Pendiente:** probar en staging pedidos pagados y cancelados en periodos distintos, reembolsos realizados en una fecha posterior, gastos creados un día y pagados otro, y rangos que cruzan medianoche en Bogotá. No se ejecutó SQL ni se modificó Supabase.
