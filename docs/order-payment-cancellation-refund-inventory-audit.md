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


## 13. Fechas visibles en el historial de gastos

El historial del panel ahora diferencia la fecha en que ocurrió o se registró el gasto (`expense_date`) de la fecha efectiva de pago (`paid_at`). La fecha de pago se presenta en hora de Colombia y aparece como pendiente cuando el gasto todavía no ha sido pagado.

Esto alinea la lectura del historial con el reporte financiero, que incorpora los gastos en el periodo de `paid_at`, no en el periodo de `expense_date`. No cambia importes ni registros almacenados.

## 13. Conciliación de subtotales y acumulados por periodo

Se revisó la función única `get_business_admin_profit_report(p_business_id, p_start_date, p_end_date)`: admite periodos de hasta 367 días inclusivos, por lo que puede consultar un año calendario completo, incluidos los años bisiestos. No hay un cálculo anual separado; el panel debe solicitar el rango anual completo.

Las identidades revisadas son:
- Cobros netos = cobros completados - reembolsos completados.
- Costo neto = costo reconocido en pagos del periodo - costo revertido por cancelaciones aprobadas en el periodo.
- Ganancia bruta estimada = cobros - reembolsos - costo neto.
- Resultado neto estimado = ganancia bruta - gastos pagados del periodo.
- Domicilios cobrados es un dato informativo incluido dentro de los cobros; no debe sumarse nuevamente.

Se amplió el verificador SQL para exigir estas identidades, la inclusión de un año bisiesto y la separación del domicilio como dato informativo. Esto no sustituye una prueba con transacciones de ensayo: la aditividad día→mes→año debe verificarse con movimientos reales controlados, incluyendo pagos, cancelaciones, reembolsos y gastos que crucen límites de mes y año.

No se ejecutó SQL ni se modificó Supabase.

### 14. Cancelaciones pagadas y obligaciones de devolución

La lista del panel de administrador consulta pedidos cancelados que siguen con `payment_status='paid'`. Esos pedidos no deben interpretarse como reembolsados: representan importes pendientes de devolver hasta que exista un movimiento de reembolso completado.

Se ajustó el panel para mostrar explícitamente el estado **Pendiente de devolución** y para indicar que el administrador solo debe registrar el reembolso después de haber devuelto realmente el dinero fuera de MiEje Market. La RPC `complete_order_refund` exige pedido cancelado y pagado, exactamente un pago completado en COP que coincida con el total, una solicitud de cancelación aprobada y una referencia de devolución; el índice único impide duplicar el reembolso completado.

El informe financiero resta únicamente reembolsos efectivamente completados dentro del periodo. Por tanto, una cancelación pagada aún no reembolsada permanece en los cobros netos hasta que se registre el movimiento real. El costo de inventario, en cambio, se revierte cuando se aprueba la cancelación. Son movimientos distintos y deben mostrarse por separado.

**Límite:** el modelo actual registra reembolsos totales, no parciales, y no ejecuta transferencias ni pagos automáticos. La prueba de conciliación de casos pendientes y completados sigue pendiente en staging.

### 15. Casos de cancelación, inventario y fechas financieras

Se contrastó el flujo para cuatro escenarios:

- **Cancelación antes del pago:** la aprobación cancela el pedido y restituye las unidades descontadas por el checkout. No genera un movimiento de reembolso ni cambia `payment_status` a `refunded`, porque no existe dinero recibido que devolver.
- **Cancelación después del pago:** la aprobación restituye inventario y revierte el costo de inventario en la fecha de decisión. El pago continúa registrado como recibido hasta que el administrador registre por separado el reembolso que ya realizó.
- **Cancelación aprobada sin reembolso completado:** el pedido aparece en la cola de devoluciones pendientes. El reporte no resta el importe como reembolsado, aunque el costo del inventario ya se haya revertido.
- **Reembolso en un periodo posterior:** el ingreso se cuenta en la fecha `completed_at` del pago y la devolución en la fecha `completed_at` del reembolso. La reversión del costo se reconoce en la fecha `decided_at` de la cancelación aprobada. Por eso, las cifras de periodos distintos pueden mostrar el cobro, la reversión de costo y la devolución en meses diferentes; no deben forzarse a coincidir por fecha de creación del pedido.

La aprobación de cancelación bloquea el pedido y la solicitud, solo procesa solicitudes pendientes y evita una segunda aprobación mediante el índice único por pedido. Para restituir existencias bloquea los productos en orden UUID, actualiza las cantidades en la misma transacción y aborta toda la operación si no logra restituir todos los productos referenciados. El trigger de inventario registra el movimiento de restitución.

Se amplió el verificador SQL para detectar que la cancelación no registre por sí misma un reembolso ni marque el pago como devuelto, que la decisión no procese solicitudes ya atendidas y que la reversión de costo requiera un pago completado en COP.

**Pendiente de prueba:** ejecutar en staging escenarios concurrentes y de conciliación con datos controlados. Esta revisión es estática; no confirma que los triggers, índices y RPC estén instalados en la base activa.

### 16. Integridad del libro de movimientos de inventario

La revisión encontró que el historial necesitaba dos protecciones adicionales: impedir modificaciones/borrados incluso desde `service_role` y validar que el signo de la variación coincida con el tipo de movimiento. Se actualizaron los borradores:

- `inventory_movements_direction_check` exige variación negativa para ventas y positiva para inventario inicial y restituciones por cancelación; los ajustes manuales pueden ser positivos o negativos.
- Un trigger `inventory_movements_immutable` rechaza UPDATE y DELETE. Se revocaron a `service_role` los permisos directos de INSERT, UPDATE, DELETE y TRUNCATE; las inserciones normales las realiza el trigger de productos con privilegios de función.
- El trigger de inventario ahora rechaza tipos explícitamente inválidos y evita clasificar una venta o restitución con dirección contraria.
- Se agregó `inventory-ledger-baseline-draft.sql` para registrar una sola línea base de productos preexistentes que todavía no tengan movimientos. Debe ejecutarse después de instalar los triggers y con la tabla de productos bloqueada durante la transacción.
- Se agregó `verify-inventory-ledger.sql`, consulta de solo lectura que compara las existencias actuales con la suma de variaciones del historial y señala movimientos con dirección incompatible.

**Criterio de conciliación:** para cada producto, `products.inventory` debe coincidir con la suma de `inventory_movements.quantity_delta`. Un resultado distinto de cero requiere investigar el historial y la secuencia de instalación; no se debe inventar un ajuste para ocultar la diferencia.

**Pendiente:** ejecutar primero la migración de movimientos, luego la línea base, y finalmente la consulta de conciliación en staging. También faltan pruebas de concurrencia, rollback y permisos con dos negocios. No se ejecutó ninguna de estas operaciones en la base activa.

### 17. Integridad de las líneas históricas de pedidos

La revisión confirmó que el checkout ya conserva `product_name` y `unit_price` como datos snapshot en `order_items`. Por eso, los cambios posteriores al nombre o precio del producto no deben reescribir lo que el cliente compró. Se reforzó el diseño:

- La FK `order_items_product_id_fkey` conserva `ON DELETE RESTRICT`: un producto que ya aparece en un pedido no puede borrarse físicamente. Debe desactivarse para dejar de venderlo.
- El nuevo trigger `order_items_history_guard` impide UPDATE y DELETE de las líneas históricas.
- Al insertar una línea, el trigger exige un `product_id` válido y verifica que el producto pertenezca al mismo negocio que el pedido.
- La aprobación de una cancelación ahora se detiene si encuentra líneas históricas con `product_id IS NULL`. Esto protege pedidos antiguos afectados por la FK anterior `ON DELETE SET NULL`: no se cancela ni se declara restituido inventario que no puede identificarse con seguridad.
- El verificador integral comprueba el trigger, la FK restrictiva, la validación de negocio y el bloqueo de cancelaciones con referencias ausentes. También comprueba que checkout conserve nombre y precio en la definición de la RPC.

**Limitación importante:** las líneas históricas que ya perdieron su `product_id` no se pueden reconstruir automáticamente con certeza. Deben identificarse y resolverse mediante revisión del negocio antes de aprobar su cancelación. No se deben asociar a productos por similitud de nombre ni inventar cantidades.

**Pendiente:** ejecutar las migraciones y pruebas en staging, incluyendo cambio de nombre/precio posterior a una venta, intento de borrar producto vendido, inserción de línea con producto de otro negocio, intento de editar/borrar una línea histórica y cancelación de un pedido antiguo con referencia NULL. No se ejecutó SQL en la base activa.

**Contraste de solo lectura con la base activa:** en el proyecto independiente consultado, `public.order_items` existe con 0 filas, `null_product_references = 0` y `cross_business_references = 0`. La FK activa se confirmó como `FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE SET NULL`; aún no es restrictiva. Esto significa que hoy no hay líneas históricas afectadas en esa tabla, pero el riesgo de perder la referencia sigue presente hasta aplicar la migración revisada. La consulta fue estrictamente de lectura; no se modificó Supabase.


### 18. Integridad completa del pedido y coherencia del flujo de estados

La revisión estática encontró una diferencia entre los estados que usa el panel y los estados normalizados por la base de datos. El panel todavía interpretaba `pending` y `out_for_delivery`, mientras que el flujo vigente utiliza `received` y `on_the_way`. Se alinearon las etiquetas, los botones de avance y la captura de referencia de entrega con los estados actuales:

`received → confirmed → preparing → ready → on_the_way → delivered`

La cancelación sigue siendo una ruta separada y solo puede completarse después de la aprobación de una solicitud por el administrador del negocio. Un pedido entregado o cancelado no debe volver a avanzar.

También se amplió el verificador de integración para comprobar que los roles autenticados puedan actualizar únicamente los campos operativos autorizados y no tengan permiso de modificar importes, método/estado de pago, datos originales del cliente ni líneas históricas. Se añadió una comprobación de la restricción de estados normalizados y del trigger que valida las transiciones.

**Resultado de esta pasada:** se corrigió la discrepancia de estados en el panel y se fortaleció el verificador para importes y datos históricos. La revisión del código confirma que el cambio de estado usa comparación con el estado anterior (`.eq('status', currentStatus)`), mientras el trigger del servidor valida la transición permitida. Los importes se entregan al administrador mediante RPC y no mediante escritura directa desde el panel.

**Pendiente de ejecución:** ejecutar el verificador SQL en staging y probar con dos sesiones concurrentes, estados terminales, empleado y administrador de negocios distintos, y cambios de precio/nombre del producto después de una compra. No se ejecutó SQL ni se modificó la base activa en esta revisión.
