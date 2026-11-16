# Auditoría de conexión entre paneles y operaciones de pedidos

**Fecha:** 16/11/2026  
**Rama:** `correcciones-funcionales`  
**Alcance:** revisión estática de llamadas desde `panel-live.js` y `app.js`, comparación con firmas SQL candidatas y consulta de existencia de RPC en Supabase Independiente.

## Resultado principal

Se confirmó que la interfaz contiene llamadas para confirmar pagos, solicitar y decidir cancelaciones, registrar reembolsos y crear pedidos públicos. Las firmas y argumentos de las llamadas revisadas coinciden con las funciones SQL candidatas de la rama.

Sin embargo, la consulta de solo lectura al proyecto Supabase independiente no encontró ninguna de estas cinco RPC:
- `mark_order_payment_received`
- `complete_order_refund`
- `request_order_cancellation`
- `decide_order_cancellation`
- `get_business_admin_order_financials`

Por tanto, los controles de pagos, reembolsos, cancelaciones y datos financieros no pueden considerarse operativos en el proyecto activo todavía. La interfaz muestra mensajes de error cuando las funciones no están desplegadas, pero no sustituye la instalación de las migraciones.

## Matriz de llamadas

| Acción de interfaz | Llamada | Resultado estático |
|---|---|---|
| Confirmar pago recibido | `mark_order_payment_received` | Argumentos coinciden con la firma candidata |
| Solicitar cancelación | `request_order_cancellation` | Argumentos coinciden con la firma candidata |
| Aprobar/rechazar cancelación | `decide_order_cancellation` | Argumentos coinciden con la firma candidata |
| Registrar reembolso realizado | `complete_order_refund` | Argumentos coinciden con la firma candidata |
| Consultar finanzas del negocio | `get_business_admin_order_financials` | Argumentos coinciden con la firma candidata |
| Crear pedido público | Edge Function `create-public-order` | Validación, idempotencia y llamada RPC visibles en código |

## Hallazgos y observaciones

### 1. Confirmación de pago

La interfaz solicita confirmación expresa, proveedor, referencia y notas. Para métodos distintos de efectivo exige referencia. Deshabilita el botón antes de invocar la RPC y lo reactiva ante error. El SQL candidato vuelve a validar el rol, estado del pedido e importe y usa bloqueo de fila.

**Pendiente:** comprobar la operación con dos solicitudes simultáneas en staging y verificar que solo quede un ingreso completado.

### 2. Cancelaciones

La interfaz permite registrar una solicitud desde el panel y presentar la decisión al administrador. El SQL candidato restringe la solicitud a miembros activos del negocio y la decisión al administrador. La aprobación devuelve inventario en la misma transacción.

**Observación funcional:** el texto de la interfaz describe el motivo como comunicado por el cliente, pero la acción se inicia desde el panel del negocio. No es una solicitud directa del cliente desde su cuenta. Debe mantenerse claro quién registra la solicitud y quién toma la decisión.

### 3. Reembolsos

La interfaz etiqueta la acción como “Registrar reembolso realizado” y solicita método, proveedor, referencia y notas. Esto coincide con el alcance real de la RPC: registrar una devolución externa ya ejecutada, no enviar dinero.

**Pendiente:** prueba de doble envío, conciliación del importe y revisión del manejo de referencias en la auditoría para no guardar información bancaria innecesaria.

### 4. Checkout público

El cliente deshabilita el botón durante el envío, crea una clave idempotente y conserva el intento cuando el resultado es incierto. La Edge Function valida identificadores, método de pago, productos y cantidades; identifica al cliente autenticado verificando el token con Auth y llama a RPC de consulta/reserva/creación idempotente.

La Edge Function fija `@supabase/supabase-js@2.75.0`. Debe comprobarse que esa versión sigue siendo compatible y que la cabecera `cf-connecting-ip` está presente en el despliegue real; no se puede verificar desde la revisión estática.

### 5. Estados de pedido

El panel presenta transiciones lineales y deshabilita el botón durante la actualización. La autorización final debe permanecer en la base de datos, no depender del botón o del JavaScript. La matriz de pruebas debe incluir transiciones fuera de orden, usuario sin membresía y cambio simultáneo desde dos sesiones.

## Pruebas pendientes obligatorias

1. Confirmación simultánea del mismo pago: un solo movimiento completado.
2. Solicitudes simultáneas de cancelación: una sola solicitud pendiente.
3. Dos aprobaciones simultáneas: una sola restitución por producto.
4. Reembolso simultáneo: un solo reembolso completado.
5. Fallo inducido en cada paso: rollback de todas las escrituras relacionadas.
6. Aislamiento entre negocio A y B para administrador y empleado.
7. Checkout repetido con la misma clave y mismo contenido: devolver el mismo pedido sin duplicar inventario.
8. Checkout con la misma clave y contenido distinto: rechazarlo.
9. Pruebas de cabeceras/IP en el entorno real de Edge Functions.

## Conclusión

**Conexiones estáticas coherentes; operación real no verificada.** El principal bloqueo es que las RPC financieras y de cancelación revisadas no existen todavía en el proyecto Supabase activo. Los SQL siguen siendo borradores en la rama.

No se ejecutó SQL, no se modificó Supabase, no se desplegaron Edge Functions, no se fusionó ningún PR y no se publicó GitHub Pages.


## Auditoría de notificaciones y comunicación de pedidos — 16 nov 2026

### Hallazgo principal: no existe entrega automática de notificaciones

La inspección del proyecto Supabase activo y de la rama `correcciones-funcionales` no encontró un flujo de notificación asociado a la creación o al cambio de estado de pedidos.

**Código de aplicación**
- `panel-live.js` cambia el estado mediante `orders.update(changes)`. Tras guardar, vuelve a cargar la lista del panel; no invoca un servicio de notificaciones ni genera un aviso al cliente.
- `app.js` registra el pedido mediante la Edge Function `create-public-order` y permite consultar el estado con `track-public-order`. No se encontró una llamada posterior a correo, SMS, push o WhatsApp automático.
- El campo `whatsapp_support` genera un enlace de contacto `wa.me` para que la persona inicie una conversación. Esto no es una integración que envíe mensajes automáticos al cambiar el estado.

**Proyecto Supabase activo**
- Hay seis Edge Functions activas: `technical-business-management`, `create-public-order`, `track-public-order`, `resolve-my-access`, `get-public-storefront` y `create-job-application`. No hay función de notificaciones, correo, SMS, push ni webhook de pedido.
- Las tablas públicas incluyen `orders`, `order_items`, `order_cancellation_requests`, `audit_logs` y otras tablas comerciales, pero no una tabla de notificaciones, bandeja de salida (outbox), cola de mensajes o registro de entrega.
- El trigger `orders_audit_status` llama a `private.log_order_status_change()`. Esta función inserta en `audit_logs` la acción `order.status_changed` con el estado anterior y el nuevo. Es una traza interna de auditoría, no una notificación al cliente.
- No hay tablas de pedidos en la publicación `supabase_realtime`; tampoco se encontró instalada la extensión `pg_net` ni `pg_cron`. La consulta al esquema `cron.job` no pudo ejecutarse porque el esquema/relación no existe; no se interpreta como una prueba de configuración adicional.
- No se encontró una tabla o política de Realtime para notificaciones.

### Consecuencia funcional

El cliente no recibe un aviso automático cuando el pedido:
1. Es recibido por el negocio.
2. Es confirmado.
3. Pasa a preparación.
4. Está listo.
5. Sale en camino.
6. Se entrega o se cancela.

El cliente debe abrir el seguimiento e introducir nuevamente su código privado para consultar el estado. No hay evidencia de correo de confirmación de compra ni de notificaciones de cambios.

### Diferencia entre auditoría y notificación

El registro en `audit_logs` conserva quién hizo el cambio (si hay sesión autenticada), el negocio, la entidad y los estados anterior/nuevo. Sirve para revisión interna. No guarda un destinatario, canal, plantilla, resultado de entrega, número de intentos ni confirmación de lectura; por tanto no se debe presentar como un sistema de avisos.

### Arquitectura recomendada antes de implementarlo

1. Crear una bandeja de salida transaccional (outbox) para eventos de pedido. La inserción del evento debe ocurrir en la misma transacción que crea el pedido o cambia su estado, para no perder avisos si el proceso posterior falla.
2. Procesar la outbox desde una Edge Function/worker, con reintentos limitados, backoff, idempotencia, estados `pending/sent/failed`, registro de proveedor y referencia de entrega. No realizar llamadas HTTP externas dentro de un trigger que mantenga abierta la transacción del pedido.
3. Separar canales: correo transaccional, WhatsApp mediante proveedor y plantillas autorizadas, y notificaciones internas. No asumir que un enlace `wa.me` envía mensajes.
4. Para clientes autenticados, una bandeja interna debe aplicar RLS por `auth.uid()`. Para eventos en vivo, preferir Broadcast privado con autorización RLS del tema y enviar únicamente el ID del evento y el estado mínimo, no la fila completa del pedido.
5. Para invitados, conservar el seguimiento mediante Edge Function con token privado; no publicar el token en nombres de canal ni emitir los datos del pedido en un canal público. El refresco seguro puede seguir consultando el endpoint protegido.
6. Respetar preferencias y autorizaciones: los avisos necesarios para gestionar la compra deben distinguirse de promociones. No enviar mensajes promocionales sin la autorización correspondiente.
7. Definir plantillas en español, zona horaria de Colombia, límites de frecuencia y manejo de rebotes/errores. Nunca incluir direcciones completas, datos de pago ni información sensible en notificaciones visibles en pantalla bloqueada.

### Inconsistencia adicional en los textos legales

La sección de tratamiento de datos de `app.js` afirma que el pedido es una demostración y que el formulario no almacena ni envía datos al servidor. Los términos también afirman que el carrito/formulario son demostrativos, que no se genera un pedido real y que el botón solo muestra una vista previa local. Sin embargo, el código actual del checkout invoca `create-public-order`, que llama a la RPC `create_public_order`, y el seguimiento consulta `track-public-order`.

Esto significa que los textos legales no describen correctamente el comportamiento actual del código. Aunque la base activa tenía cero pedidos en la consulta de esta auditoría, el flujo de servidor sí está implementado y puede almacenar datos personales de pedido cuando se utiliza. Deben actualizarse la política de privacidad, el aviso de tratamiento y los términos antes de activar el uso público/comercial, describiendo los datos realmente recogidos, responsables, finalidades, proveedores, conservación, cancelaciones, pagos y canales de atención. La revisión final debe validarse con asesoría legal colombiana. No se modificaron los textos legales en esta pasada.

### Pruebas requeridas en staging

- Crear un pedido y verificar que el evento outbox se inserte una sola vez.
- Cambiar cada estado válido y verificar un único evento por transición.
- Simular caída del proveedor: el pedido permanece guardado y el aviso se reintenta sin duplicarse.
- Repetir el procesamiento del mismo evento: no se envía dos veces.
- Verificar que cliente A no reciba avisos del negocio/cliente B.
- Verificar canales privado y de invitado sin exponer filas, token, dirección ni teléfono.
- Verificar que cancelación aprobada/rechazada y reembolso generen eventos distintos y no se confundan.
- Verificar preferencias de comunicación y separación de avisos transaccionales frente a marketing.
- Comparar los textos legales publicados con los datos y canales efectivamente activados.

### Resultado

**No existe todavía un sistema de notificaciones automáticas de pedidos.** Solo hay seguimiento manual por código y auditoría interna de cambios de estado. La implementación de notificaciones, la cola/outbox, los proveedores y las pruebas siguen pendientes. No se modificó la base activa, no se enviaron mensajes ni correos, no se desplegaron funciones y no se cambió la publicación.
