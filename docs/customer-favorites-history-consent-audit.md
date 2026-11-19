# Auditoría de clientes, favoritos, historial y consentimiento del checkout

**Fecha:** 19 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Alcance:** revisión estática de `app.js`, `index.html`, `supabase/functions/create-public-order/index.ts`, `database/customers/customer-account-migration.sql`, `database/orders/checkout-idempotency-draft.sql` y `database/orders/order-financial-access-draft.sql`.

## Resultado

La vinculación del pedido con la cuenta se resuelve en el servidor: la Edge Function valida el bearer token con Auth, consulta el perfil y toma el ID del usuario validado. No confía en un `customer_user_id` enviado por el navegador. Los pedidos de invitados conservan el valor nulo.

Los favoritos se consultan por el usuario autenticado y las escrituras incluyen su ID. El borrador SQL añade RLS por propietario, impide reasignar filas porque no concede UPDATE y establece una restricción única por usuario/producto. La protección definitiva depende de aplicar y probar esa migración en staging.

El historial se entrega mediante `get_customer_order_history()`, que exige sesión, perfil no bloqueado y filtra por `orders.customer_user_id = auth.uid()`. La función limita la consulta a los últimos 50 pedidos. La migración de clientes y las políticas de lectura relacionadas todavía son borradores; no debe anunciarse como funcional en el proyecto activo.

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
