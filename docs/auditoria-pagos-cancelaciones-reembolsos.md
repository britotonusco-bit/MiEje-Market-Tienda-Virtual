# Auditoría de pagos, cancelaciones y reembolsos

Fecha: 2026-11-16  
Rama revisada: `correcciones-funcionales`

## Alcance

Revisión estática de `panel-live.js`, `panel-personal.html`, `panel-negocio.html` y los borradores SQL ubicados en `database/orders/`. No se ejecutaron consultas contra Supabase ni se aplicaron cambios a la base de datos.

## Hallazgos confirmados en el código del cliente

1. El panel de empleados consulta pedidos sin seleccionar `total`, `subtotal`, `delivery_fee`, `payment_method` ni `payment_status`.
2. La tabla del panel de empleados no renderiza importes ni el botón de confirmar pagos.
3. El botón de confirmar pago se genera únicamente cuando `admin === true`, el pago está pendiente y el pedido no está cancelado.
4. La pantalla de reembolsos y sus acciones solo se cargan en el panel `business_admin`.
5. El panel de empleados sí puede solicitar una cancelación. La decisión final se ejecuta mediante `decide_order_cancellation`, cuya definición SQL borrador exige el rol `business_admin`.
6. La transición de estados de pedidos se realiza filtrando por negocio y estado previo, para evitar sobrescribir una actualización concurrente.

## Hallazgos en los borradores SQL

- `order-financial-access-draft.sql` define RPC financieras que validan la sesión, negocio activo y rol `business_admin`. También propone retirar permisos directos de lectura de importes y estados de pago para el rol `authenticated`.
- `mark_order_payment_received` bloquea el pedido, exige pago pendiente, impide confirmar pedidos cancelados o reembolsados y registra un movimiento financiero único.
- `refund-flow-draft.sql` exige pedido cancelado y pagado, una transacción de pago completada que coincida con el total, una cancelación aprobada y una referencia de reembolso. Incluye un índice único para impedir reembolsos duplicados.
- `cancellation-flow-draft.sql` permite solicitar cancelación a administradores y empleados, pero reserva la decisión al administrador. La aprobación cambia el estado y restituye inventario dentro de la misma transacción; no marca el pago como reembolsado.

## Bloqueo importante: despliegue no demostrado

Los archivos SQL anteriores están identificados como borradores. En esta rama no se encontró una carpeta `supabase/migrations/`; las definiciones revisadas están en `database/orders/` y no prueban que los RPC, índices, restricciones ni permisos estén instalados en el proyecto Supabase activo.

Por tanto, no se puede afirmar todavía que un empleado esté bloqueado en la base de datos, ni que pagos, cancelaciones y reembolsos funcionen en producción. La interfaz oculta las acciones financieras al empleado, pero la seguridad efectiva depende de los privilegios SQL, RLS y las comprobaciones dentro de las funciones desplegadas.

## Pruebas necesarias antes de dar esta parte por terminada

1. Empleado: lectura de pedidos operativos permitida; lectura directa de importes y estado de pago denegada.
2. Empleado: ejecución de `get_business_admin_order_financials`, `mark_order_payment_received` y `complete_order_refund` denegada.
3. Administrador del negocio A: acceso a las finanzas de A permitido y acceso a las de B denegado.
4. Confirmación de pago: una sola operación exitosa; segundo intento rechazado; pedido cancelado rechazado.
5. Cancelación: empleado puede solicitar; empleado no puede aprobar ni rechazar; administrador del negocio correcto sí puede decidir.
6. Reembolso: solo pedido cancelado, pagado y con pago conciliado; reembolso duplicado rechazado.
7. Inventario: una cancelación aprobada restituye cantidades una sola vez; una cancelación rechazada no altera existencias.
8. Verificación de auditoría y consistencia entre `orders`, `financial_transactions`, `refund_details` y `order_cancellation_requests`.

## Estado

- Revisión estática del cliente: completada para los controles de pago y reembolso y la solicitud/decisión de cancelación.
- Validación SQL: pendiente de ejecutar en un entorno de ensayo.
- Prueba real en navegador: pendiente.
- Supabase activo: sin cambios.
- Publicación o despliegue: no realizado.
