# Auditoría de clientes, favoritos, historial y consentimiento del checkout

**Fecha:** 19 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Alcance:** revisión estática de `app.js`, `index.html`, `supabase/functions/create-public-order/index.ts`, `database/customers/customer-account-migration.sql`, `database/orders/checkout-idempotency-draft.sql` y `database/orders/order-financial-access-draft.sql`.

## Resultado

La vinculación del pedido con la cuenta se resuelve en el servidor: la Edge Function valida el bearer token con Auth, consulta el perfil y toma el ID del usuario validado. No confía en un `customer_user_id` enviado por el navegador. Los pedidos de invitados conservan el valor nulo.

Los favoritos se consultan por el usuario autenticado y las escrituras incluyen su ID. El borrador SQL añade RLS por propietario, impide reasignar filas porque no concede UPDATE y establece una restricción única por usuario/producto. La protección definitiva depende de aplicar y probar esa migración en staging.

El historial sí está conectado a la interfaz independiente `cuenta.html` mediante `cuenta.js`, que invoca `get_customer_order_history()` al abrir la cuenta. La RPC exige sesión, perfil no bloqueado y filtra por `orders.customer_user_id = auth.uid()`; limita la consulta a los últimos 50 pedidos. `app.js` no contiene esa llamada porque la pantalla de cuenta usa su propio archivo JavaScript. La migración de clientes y las políticas de lectura relacionadas todavía son borradores; por tanto, la interfaz existe, pero su funcionamiento depende de aplicar y probar las migraciones.

## Hallazgo crítico: consentimiento del checkout no persistido

En `index.html`, el formulario contiene una casilla obligatoria `privacyConsent` y un texto de autorización. Sin embargo, el manejador de `#checkoutForm` en `app.js` no lee esa casilla ni incluye el consentimiento en `checkoutPayload`.

La Edge Function `create-public-order` tampoco valida un campo de consentimiento. Las RPC de idempotencia no reciben una versión del aviso ni guardan fecha/hora de autorización en el pedido.

Por tanto, la validación HTML solo impide el envío normal desde ese formulario; no constituye evidencia persistente en el servidor y una llamada directa a la Edge Function no queda protegida por esa casilla.

### Corrección requerida antes de habilitar el checkout

1. Leer y validar la casilla en el navegador, y enviar únicamente el indicador de aceptación junto con el identificador/versionado del aviso aplicable.
2. Volver a validar el consentimiento en la Edge Function. Rechazar solicitudes sin aceptación válida; no confiar en el navegador.
3. Incluir la versión del aviso y el indicador en el hash de idempotencia y en la reserva de límite, para impedir que una misma clave represente solicitudes con consentimientos diferentes.
4. Persistir en `orders` la evidencia mínima necesaria: aceptación, versión del aviso y marca de tiempo generada por el servidor. No guardar una fecha enviada por el cliente.
5. Devolver un error claro si la migración o las columnas no están disponibles. No crear pedidos sin evidencia.
6. Añadir verificaciones al paquete SQL y probar en staging: casilla desmarcada, solicitud directa sin consentimiento, consentimiento válido, reintento idempotente y clave reutilizada con datos distintos.

La modificación debe hacerse en la rama y en los borradores SQL, respetando el orden de dependencias del paquete de integración. No aplicar la migración ni desplegar la Edge Function en el proyecto activo sin autorización expresa.

## Estado de la verificación

- Revisión estática de código y SQL: realizada.
- Pruebas con dos cuentas de clientes y dos negocios: pendientes en staging.
- Verificación de RLS/grants/RPC instaladas: pendiente; los scripts revisados son borradores.
- Pruebas reales de checkout, historial y favoritos: pendientes.
- Cambios en Supabase activo o despliegues: ninguno.


## Implementación en la rama (19 nov 2026)

Se implementó el flujo de consentimiento en la rama `correcciones-funcionales`:

- El checkbox del checkout identifica explícitamente la versión `privacy-2026-11-19-v1`.
- `app.js` exige aceptación y envía el indicador y la versión; ambos quedan incluidos en la huella local del intento.
- La Edge Function rechaza solicitudes sin aceptación explícita o con una versión distinta de la admitida por el servidor.
- `checkout-idempotency-draft.sql` agrega a `orders` los campos `privacy_consent`, `privacy_consent_version` y `privacy_consent_at`. La restricción permite valores nulos solo para pedidos históricos; los nuevos pedidos deben guardar aceptación, versión y fecha.
- La RPC de creación vuelve a validar la aceptación y la versión, y genera la fecha con `transaction_timestamp()`. Los tres RPC de idempotencia incluyen la aceptación y versión en el hash del intento.
- `verify-integration-package.sql` comprueba las columnas, la restricción, la firma/permisos de la RPC y la generación de fecha en el servidor.

**Estado:** cambios guardados en la rama; falta revisar el diff completo, validar las firmas SQL y probar en staging. No se aplicó ninguna migración ni se desplegó la Edge Function. La versión debe actualizarse coordinadamente en la política pública, el HTML, la Edge Function y el borrador SQL cuando se publique una nueva versión del aviso.


## Revisión de la interfaz de cuenta

La inspección de `cuenta.html` y `cuenta.js` confirmó que existen registro, inicio de sesión, cierre de sesión, recuperación mediante enlace a `recuperar-clave.html`, historial de pedidos y favoritos. La página carga historial y favoritos al detectar una sesión, y vuelve a actualizar el estado cuando cambia la autenticación.

No se detectó una llamada de historial ausente: está en `cuenta.js`, no en `app.js`. La prueba de aislamiento entre dos clientes y el acceso real a la tabla de favoritos siguen pendientes de staging, porque las migraciones SQL aún no están aplicadas en el proyecto activo.

La pantalla muestra un mensaje de error si falla la RPC del historial o la consulta de favoritos. No se modificó esta interfaz durante la corrección del consentimiento.


## Casos de prueba obligatorios en staging

1. Enviar checkout sin marcar la casilla: la interfaz lo bloquea y la Edge Function debe responder HTTP 400 si se llama directamente.
2. Enviar `privacy_consent=true` con una versión distinta: el servidor debe rechazarlo.
3. Crear un pedido como invitado con aceptación válida: el pedido debe conservar `customer_user_id=NULL`, `privacy_consent=true`, la versión exacta y una fecha de PostgreSQL.
4. Crear un pedido con sesión válida: el pedido debe quedar asociado al ID autenticado validado por Auth y guardar la misma evidencia.
5. Reintentar con la misma clave y mismo contenido: debe recuperar el pedido original sin duplicarlo.
6. Reutilizar la clave con otro valor de aceptación o versión: debe producir conflicto y no crear un segundo pedido.
7. Intentar leer o modificar directamente las tres columnas de evidencia desde `authenticated`: debe fallar; la evidencia solo se consulta mediante acceso autorizado del servidor.
8. Ejecutar el verificador integral: debe reconocer las cuatro firmas nuevas, los tres hashes de idempotencia y el timestamp generado en PostgreSQL.

Estos casos no se han ejecutado todavía. La verificación realizada hasta ahora es estática sobre los archivos de la rama.
