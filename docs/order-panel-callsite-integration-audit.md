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


### 8. Evidencia de autorización en el checkout

La vista del checkout en `index.html` muestra una casilla obligatoria `privacyConsent` con el texto de autorización para gestionar el pedido. Sin embargo:

- El manejador de checkout en `app.js` no lee ni envía `privacyConsent` en el payload de `create-public-order`.
- La Edge Function desplegada `create-public-order` tampoco recibe un campo de autorización.
- La RPC activa `create_public_order` no tiene parámetro de consentimiento y no registra fecha, versión del aviso, finalidad ni evidencia de aceptación.
- La tabla activa `orders` no tiene columnas de consentimiento/privacidad.

La validación `required` del navegador impide normalmente enviar el formulario sin marcar la casilla, pero eso no crea evidencia verificable del consentimiento en el servidor. Un cliente modificado puede omitir la validación de interfaz; la operación de servidor no tiene un dato con el que comprobarlo.

**Riesgo alto de cumplimiento y trazabilidad:** no debe confundirse la casilla visible con un registro persistente de autorización. Antes de activar el flujo comercial, definir con asesoría legal la base aplicable y qué autorizaciones son necesarias; si se requiere autorización, registrar en servidor el usuario/identificador de pedido, fecha, versión exacta del aviso, finalidades y canal, sin guardar más datos de los necesarios. El servidor debe rechazar una solicitud que requiera autorización si no recibe y valida la evidencia correspondiente. Separar autorización para gestionar el pedido de cualquier consentimiento opcional de marketing.

### Pruebas adicionales

- Enviar checkout con casilla marcada y verificar evidencia persistida y vinculada al pedido.
- Omitir o falsear el campo desde una llamada directa a la Edge Function: el servidor debe rechazarlo si la autorización es requisito.
- Verificar versión del aviso, marca temporal y finalidades.
- Comprobar que desmarcar autorizaciones promocionales no impida una compra cuando sean opcionales.


### Auditoría de permisos y flujo de estados de pedidos en paneles — 16 nov 2026

**Hallazgo crítico confirmado en Supabase activo (solo lectura):** el panel `panel-live.js` ejecuta `db.from('orders').update(changes)` desde `changeOrderStatus()` para administradores y empleados. La tabla tiene política RLS `orders_members_update_status`, pero el rol `authenticated` no tiene privilegio SQL UPDATE sobre `public.orders` (`has_table_privilege = false`). La existencia de una política RLS no concede por sí sola el privilegio SQL. Por tanto, la acción de cambio de estado del panel no puede completarse por esa ruta directa con los permisos actuales. No se ejecutó un cambio de estado para probarlo.

**Inconsistencia adicional de estados:**
- El checkout/RPC `create_public_order` crea pedidos con estado `pending`.
- La restricción `orders_status_check` admite `pending, confirmed, preparing, ready, out_for_delivery, delivered, cancelled`.
- El trigger `private.enforce_order_status_transition()` espera transiciones desde `pending` y usa `out_for_delivery`.
- El panel representa `received` y `on_the_way`, y su mapa de avance empieza en `received` y usa `on_the_way`.

Esto impide que el flujo de interfaz y el modelo de base de datos compartan un vocabulario coherente. Además, el trigger solo permite cancelar con una solicitud aprobada, mientras que la UI de avance normal no debe ofrecer cancelación como transición directa.

**Permisos de productos y costos:**
- RLS de `products` permite INSERT/UPDATE/DELETE únicamente al rol `business_admin` del negocio activo; empleados no pasan esas políticas aunque el rol tenga privilegios SQL generales.
- RLS de `product_costs` restringe SELECT/INSERT/UPDATE al administrador del negocio activo o al propietario de plataforma.
- La lectura de pedidos y sus líneas se limita a miembros activos del negocio (administrador/empleado) y al propietario de plataforma.
- El panel filtra sus consultas y actualizaciones de pedidos por `business_id`; la protección final debe seguir en RLS/RPC, no depender solo del filtro JavaScript.

**Corrección necesaria antes de habilitar la operación:** preparar una RPC transaccional de cambio de estado que compruebe `auth.uid()`, membresía activa y negocio activo, acepte solo los campos operativos (`status` y `delivery_tracking`), aplique la máquina de estados acordada (`received → confirmed → preparing → ready → on_the_way → delivered`) y registre auditoría. Revocar la escritura directa amplia y conceder EXECUTE solo a `authenticated` con comprobación explícita de rol dentro de la función. Alinear la restricción CHECK y el trigger con el vocabulario definitivo, conservando compatibilidad o migración controlada para pedidos históricos `pending/out_for_delivery`. No conceder UPDATE de tabla como solución rápida.

**Estado de este paso:** hallazgo documentado; no se modificó el panel ni la base activa. La corrección requiere una migración y una RPC coordinadas, pruebas de estados y permisos con cuentas de administrador/empleado de dos negocios en staging. No desplegar sobre el proyecto activo.


### Segunda pasada: RPC ausentes y separación del rol técnico — 16 nov 2026

#### RPC que el panel invoca pero no existen en la base activa

Se extrajeron las llamadas `.rpc(...)` de `panel-live.js` y se compararon por nombre y firma con `pg_proc` en todos los esquemas consultados. De las 12 RPC invocadas por el panel, solo existen estas tres:

- `pay_business_expense`
- `register_business_expense`
- `void_business_expense`

No aparecen en la base activa:

- `get_business_admin_order_financials`
- `get_business_admin_profit_report`
- `attach_business_expense_receipt`
- `adjust_business_inventory`
- `save_business_payment_methods`
- `mark_order_payment_received`
- `complete_order_refund`
- `request_order_cancellation`
- `decide_order_cancellation`

Esto afecta rutas centrales del panel: `loadBusinessAdmin()` llama `get_business_admin_order_financials` al iniciar y lanza el error si falla; el reporte de ganancias, inventario, configuración de pagos, confirmación de pagos, solicitudes/decisiones de cancelación y registro de reembolsos también dependen de RPC ausentes. Por tanto, varias funciones que aparecen en la interfaz no están conectadas a operaciones existentes en la base activa. No se ejecutaron llamadas mutadoras para probarlas.

Además, el código invoca la Edge Function `get-platform-public-settings`, pero la lista actual de funciones desplegadas contiene únicamente `technical-business-management`, `create-public-order`, `track-public-order`, `resolve-my-access`, `get-public-storefront` y `create-job-application`. La función invocada no figura como desplegada en este proyecto.

#### Exceso de permisos del propietario técnico

Las políticas activas también conceden al propietario de plataforma acceso transversal que no coincide con la separación de funciones acordada:

- `businesses_admin_update` permite que `platform_owner` actualice cualquier fila de `businesses`, sin limitar las columnas; esto puede incluir configuración comercial, no solo estado/suspensión.
- `business_payment_methods` permite al propietario de plataforma leer, insertar y actualizar métodos de pago de los negocios.
- `product_costs` permite al propietario de plataforma leer, insertar y actualizar costos internos.
- Las políticas de `orders`, `order_items` y `order_item_costs` permiten al propietario de plataforma leer pedidos, datos de clientes y costos históricos de todos los negocios; la política de pedidos también lo incluye para UPDATE.

Aunque la interfaz técnica no exponga necesariamente todos esos botones, RLS es la autorización real. Debe reducirse el acceso transversal: el técnico gestiona cuentas, membresías y estado operativo del negocio mediante acciones específicas, pero no debe consultar ni modificar pagos, costos, pedidos ni configuración comercial de cada tienda. Las acciones de suspensión/reactivación deben ser RPC/Edge Function estrechas, con campos permitidos explícitos y auditoría.

#### Estado y siguientes correcciones

1. Definir el contrato y las firmas de las RPC faltantes; validar rol, negocio activo, campos permitidos, transacciones e idempotencia.
2. Corregir primero la RPC de consulta de pedidos/finanzas para que el panel administrativo pueda iniciar sin depender de una función inexistente.
3. Crear la RPC de transición de pedidos y alinear estados históricos/UI/trigger/check.
4. Añadir las RPC de inventario, pagos, cancelaciones y reembolsos con autorización específica por rol.
5. Eliminar el acceso del propietario técnico a datos comerciales/financieros transversales y sustituir la actualización genérica de negocios por acciones limitadas.
6. Resolver la referencia a `get-platform-public-settings` (implementar y desplegar en staging o retirar la llamada si ya no corresponde).
7. Probar en staging con dos negocios y cuentas separadas de propietario técnico, administrador y empleado; verificar accesos permitidos y denegados.

No se hicieron cambios en Supabase ni despliegues. La comparación fue de solo lectura. La rama sigue siendo el único destino de documentación; no se modificó `main` ni GitHub Pages.


### Corrección de auditoría y conciliación de borradores — 16 nov 2026

#### Rectificación importante sobre permisos de UPDATE en pedidos

La consulta anterior comprobó `has_table_privilege('authenticated','public.orders','UPDATE') = false` y se concluyó erróneamente que la actualización estaba bloqueada. La comprobación correcta de las columnas usadas por `panel-live.js` devuelve `has_column_privilege(..., 'status', 'UPDATE') = true` y `has_column_privilege(..., 'delivery_tracking', 'UPDATE') = true`. La tabla tiene política RLS `orders_members_update_status` con `USING` y `WITH CHECK` para miembros activos (`business_admin`/ `employee`) y propietario técnico, y una política SELECT equivalente. Por ello, el UPDATE del panel cuenta con permisos de columna y política RLS; no se ha demostrado que esté bloqueado por privilegios SQL. La conclusión anterior queda reemplazada.

El problema funcional confirmado era el vocabulario: la interfaz enviaba `received` y `on_the_way`, pero la restricción CHECK y el trigger de la base aceptan `pending` y `out_for_delivery`. Se corrigió la interfaz en la rama para utilizar los valores reales de la base y conservar las etiquetas visibles “Recibido” y “En camino”. También se corrigió el mapa de etiquetas del seguimiento público.

**Cambios branch-only:**
- `panel-live.js`: estado inicial `pending`, entrega `out_for_delivery`, mapa de transiciones y detección del inicio de reparto alineados con la DB.
- `app.js`: etiquetas de seguimiento alineadas con `pending/out_for_delivery`.

Verificación estática posterior: ambos archivos recuperados desde GitHub contienen los valores correctos; no quedan referencias de estado `received` ni `on_the_way` en el mapa de estados ni en el seguimiento público. La palabra `received` que permanece en `panel-live.js` corresponde a una variable local de suma de pagos, no a un estado de pedido. No se hizo prueba de navegador ni actualización de un pedido real.

#### Las RPC faltantes sí tienen borradores SQL en la rama

La comprobación anterior se refería a funciones desplegadas en la base activa. Se revisaron ahora los archivos SQL del repositorio y se encontró que las nueve RPC ausentes ya tienen implementaciones de borrador distribuidas así:

- `get_business_admin_order_financials`, `get_business_admin_profit_report`, `mark_order_payment_received`: `database/orders/order-financial-access-draft.sql`.
- `request_order_cancellation`, `decide_order_cancellation`: `database/orders/cancellation-flow-draft.sql`.
- `complete_order_refund`: `database/orders/refund-flow-draft.sql`.
- `adjust_business_inventory`: `database/inventory/inventory-movements-draft.sql`.
- `save_business_payment_methods`: `database/security/business-payment-methods-atomic-draft.sql`.
- `attach_business_expense_receipt`: `database/finance/business-expense-audit-draft.sql`.

Esto cambia el siguiente paso: no se deben reescribir desde cero; primero hay que revisar dependencias, firmas exactas, grants, políticas, triggers y orden de aplicación de estos borradores. Ninguno se considera activo o probado solo por existir en GitHub.

#### Edge Function de configuración pública

Rectificación adicional: `get-platform-public-settings` sí existe como código fuente en `supabase/functions/get-platform-public-settings/index.ts`, y hay un borrador de tabla/RPC en `database/platform/platform-public-settings-draft.sql`. Sin embargo, no figura entre las seis Edge Functions activas del proyecto. Por tanto, el hallazgo correcto es **código fuente y esquema en borrador, pero función no desplegada en el proyecto activo**; no “función inexistente”.

#### Asesores Supabase — seguridad y rendimiento

Lectura de los asesores el 16 nov 2026:
- Seguridad: protección contra contraseñas filtradas deshabilitada (WARN). Debe revisarse/habilitarse desde Auth antes de la activación pública.
- Seguridad: tres tablas con RLS y sin políticas: `private.checkout_rate_limits`, `public.job_application_rate_limits`, `public.job_application_upload_sessions`. Se comprobó que `anon` y `authenticated` no tienen privilegios de tabla/columna sobre ellas; las dos tablas públicas conceden acceso solo a `service_role`. La tabla privada tampoco concede acceso directo a esos roles. No añadir políticas públicas por silenciar el asesor; conservar el acceso interno controlado por función.
- Rendimiento: 16 claves foráneas sin índice de cobertura y una advertencia por políticas SELECT permisivas múltiples en `business_content_pages`. También se informaron 17 índices sin uso observado; no eliminarlos basándose solo en ese dato, especialmente con carga de pruebas limitada.

La documentación actual de Supabase recalca que los GRANT y RLS cumplen funciones distintas y deben revisarse juntos. Desde el 30 oct 2026 las tablas nuevas de `public` ya no se exponen automáticamente a Data API por defecto; cualquier futura migración debe declarar explícitamente exposición, GRANT y RLS según necesidad.

#### Estado

Se corrigió el vocabulario de estados en la rama y se conciliaron los hallazgos con los borradores existentes. No se ejecutó SQL, no se desplegaron Edge Functions, no se modificó Auth ni se publicó la rama. Pendiente: revisión línea por línea de los borradores, staging y pruebas con cuentas reales separadas por rol/negocio.
