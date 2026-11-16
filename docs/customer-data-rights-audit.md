# Auditoría de derechos de datos de clientes — 16 nov 2026

## Alcance y método

Revisión de solo lectura del proyecto Supabase `MiEje Market Independiente` (`cqixlrwbqatbhzmpygiz`) y de los archivos `cuenta.html`, `cuenta.js` y `database/customers/customer-account-migration.sql` en la rama `correcciones-funcionales`.

No se modificaron datos, usuarios, sesiones, políticas, Auth ni Storage. No se ejecutó SQL de escritura, no se desplegó ninguna función y no se publicó el sitio.

## Resultado ejecutivo

La cuenta de cliente permite registrarse, iniciar sesión, consultar el historial previsto y gestionar favoritos cuando las migraciones pendientes estén aplicadas. Sin embargo, todavía no existe una interfaz completa para consultar/exportar los datos personales, corregir el perfil o solicitar la eliminación de la cuenta.

**No debe habilitarse un botón de eliminación directa desde el navegador.** El borrado de Auth requiere una operación de servidor con privilegios administrativos, tratamiento previo de membresías y pedidos, y revocación de sesiones. Supabase advierte que eliminar un usuario no invalida inmediatamente los access tokens JWT ya emitidos: estos pueden seguir siendo aceptados hasta su expiración. La revocación de refresh tokens tampoco hace desaparecer instantáneamente un access token ya emitido.

## Estado observado en el proyecto activo

- Se observó 1 usuario Auth y 1 perfil.
- La consulta de sesiones devolvió 0 filas en `auth.sessions`; no hay una sesión activa disponible para probar cierre global o revocación.
- `public.profiles` contiene los campos `display_name`, `phone`, `avatar_url`, `platform_role`, `is_blocked`, `blocked_reason` y marcas de tiempo.
- La política RLS `profiles_update_self` limita la actualización a la fila cuyo `id = auth.uid()`; la política de lectura permite el perfil propio y la lectura por el propietario de plataforma.
- La migración de clientes que crea `customer_favorites` y añade `orders.customer_user_id` continúa siendo un borrador. La tabla de favoritos y la columna de vinculación de pedidos no están todavía en la base activa.
- Los buckets observados son `business-assets` (público) y `job-applications-private` (privado). No se identificó un bucket de archivos personales de clientes en esta revisión.
- No se encontraron tablas de solicitudes de eliminación o privacidad en el esquema `public`.

## Hallazgos

### 1. Consulta y exportación de datos

- La pantalla `cuenta.html` muestra correo, nombre, pedidos y favoritos, pero no presenta una opción para descargar una copia de los datos de la cuenta.
- El historial proyectado usa `get_customer_order_history()` y devuelve un conjunto limitado de campos de pedido. No constituye por sí solo una exportación completa de los datos personales del usuario.
- No se encontró un flujo que reúna los datos de Auth, perfil, favoritos, solicitudes y otros datos asociados para entregar una copia legible al titular.

**Pendiente:** diseñar una exportación autenticada, limitada al usuario actual y entregada por un canal privado. No exponer `auth.users` ni crear una vista pública con datos sensibles.

### 2. Corrección de datos personales

- El perfil contiene campos editables de cliente: `display_name`, `phone` y `avatar_url`.
- La política de actualización de perfil está limitada a la fila propia. La auditoría previa comprobó que los permisos de columna para `authenticated` excluyen `platform_role` y `is_blocked`.
- `cuenta.html` y `cuenta.js` no incluyen actualmente un formulario para modificar nombre, teléfono o avatar.
- El correo se administra en Auth y no debe modificarse como si fuera un campo ordinario de `profiles`. Un cambio de correo debe seguir el flujo de Auth y su verificación correspondiente.
- La interfaz no debe permitir editar `platform_role`, `is_blocked`, `blocked_reason`, membresías ni otros atributos de autorización.

**Pendiente:** añadir un formulario de edición de campos de cliente con validación, actualización de la fila propia y confirmación del resultado. El correo debe tener un flujo separado de cambio y confirmación.

### 3. Eliminación de cuenta y dependencias

- No existe una acción de eliminación de cuenta en `cuenta.html` ni en `cuenta.js`.
- La eliminación de un usuario Auth requiere privilegios administrativos y debe ejecutarse en servidor. La clave `service_role` nunca puede estar en JavaScript público ni en GitHub.
- La FK `profiles.id → auth.users.id` usa `ON DELETE CASCADE`; eliminar el usuario Auth elimina su perfil.
- Las referencias desde registros históricos a `profiles` observadas en la base usan `SET NULL` para conservar los registros y retirar la referencia al actor.
- Existe una dependencia importante: `business_memberships.user_id → profiles.id` usa `ON DELETE RESTRICT`. Por tanto, eliminar un usuario que todavía tenga una membresía puede impedir la eliminación de su perfil y, en consecuencia, la eliminación Auth.
- Las membresías no deben borrarse sin revisar el rol y la continuidad del negocio. Si el usuario es el único administrador de un negocio, primero debe existir un proceso de transferencia de administración o una decisión explícita de cierre. El borrado de una cuenta de cliente nunca debe borrar automáticamente el negocio.
- La migración pendiente propone `orders.customer_user_id → auth.users.id ON DELETE SET NULL`. Esto conserva los pedidos y elimina la vinculación directa con la cuenta. Los pedidos de invitado permanecen sin usuario asociado.
- La migración pendiente propone que los favoritos se eliminen con la cuenta mediante `ON DELETE CASCADE`. Es apropiado para datos personales no comerciales, siempre que se aplique y pruebe la migración.
- Supabase también advierte que no puede eliminarse un usuario que todavía sea propietario de objetos en Storage. Antes de eliminar una cuenta se debe verificar la propiedad de objetos, y decidir si se eliminan o reasignan de forma segura.

**Pendiente:** diseñar una solicitud de eliminación con confirmación reciente de identidad, periodo/estado de procesamiento claramente informado, revocación de sesiones, tratamiento de membresías, revisión de objetos Storage y conservación de registros comerciales. La operación final debe ejecutarse en una Edge Function protegida o backend equivalente con secretos solo en servidor.

### 4. Sesiones y cierre de acceso

- El botón actual de `cuenta.js` ejecuta `client.auth.signOut()`, que cierra la sesión de ese cliente según el comportamiento predeterminado global de Supabase JS.
- No existe un proceso de eliminación que revoque primero las sesiones del usuario en todos sus dispositivos.
- Supabase documenta que el cierre global revoca refresh tokens/sesiones, pero un access token JWT ya emitido puede seguir siendo válido hasta su expiración.
- El proyecto debe validar el estado del perfil y la autorización en operaciones protegidas de servidor/RLS; no debe depender solo de que la interfaz haya cerrado sesión.
- La revisión previa encontró que las operaciones sensibles consultan el estado de bloqueo del perfil, pero no se verificó una revocación global de sesiones al solicitar eliminación.
- No se realizaron pruebas de revocación porque no había sesiones activas.

**Pendiente:** definir el flujo de eliminación/bloqueo global para revocar sesiones desde servidor, invalidar refresh tokens, impedir nuevas operaciones sensibles y esperar o controlar la expiración de access tokens ya emitidos. No confundir el cierre local de una pestaña con el cierre de todos los dispositivos.

### 5. Conservación y minimización de pedidos

- Los pedidos son registros comerciales y no deben desaparecer solo porque el cliente elimine su cuenta.
- El diseño de migración usa `ON DELETE SET NULL` en `orders.customer_user_id`, preservando pedido, artículos, importes y trazabilidad comercial sin mantener el vínculo de cuenta.
- La tabla `orders` contiene datos personales de entrega, como nombre, teléfono, correo, dirección y notas. La migración por sí sola no anonimiza estos campos.
- No se encontró una política aprobada de retención con plazos definidos. No debe inventarse un periodo ni borrar datos de facturación/contabilidad sin determinar antes las obligaciones aplicables.
- La conservación de pedidos debe separarse de la conservación de datos que ya no sean necesarios para atender el pedido o cumplir obligaciones legales.

**Pendiente:** definir con asesoría legal/contable los plazos y el tratamiento de los campos de contacto y entrega después de cumplir la finalidad comercial. Diseñar anonimización o supresión selectiva cuando sea compatible con obligaciones de conservación y reclamaciones.

## Diseño recomendado antes de programar

1. **Perfil:** formulario autenticado para nombre, teléfono y avatar; campos de autorización fuera del formulario y protegidos por permisos de columna/RLS.
2. **Correo:** flujo de cambio de correo de Supabase Auth con verificación; no actualizarlo directamente en la tabla de perfil.
3. **Exportación:** solicitud autenticada que reúna los datos del titular y genere una descarga privada con caducidad.
4. **Eliminación:** solicitud iniciada por el usuario, confirmación de identidad reciente, revisión de membresías y propiedad de Storage, revocación global de sesiones y eliminación final desde servidor.
5. **Membresías:** si el usuario administra un negocio, exigir transferencia a otro administrador antes de retirar su membresía. No eliminar ni suspender el negocio automáticamente.
6. **Pedidos:** conservar el registro comercial; desvincular `customer_user_id` y aplicar una política aprobada para los datos personales que permanezcan en el pedido.
7. **Auditoría:** guardar un registro mínimo de la solicitud y su resultado sin registrar contraseñas, tokens, enlaces de recuperación ni datos innecesarios.
8. **Pruebas:** probar con dos cuentas, una cuenta con membresía de empleado, una con administración de negocio, una con pedidos vinculados, una con favoritos, objetos Storage asociados y sesiones abiertas en varios dispositivos.

## Matriz de pruebas pendiente

- El cliente solo consulta y exporta sus propios datos.
- Un cliente no puede leer ni modificar el perfil de otra cuenta.
- La edición del perfil no permite cambiar roles, bloqueos ni membresías.
- El cambio de correo exige la verificación de Auth.
- La eliminación de cuenta con membresía activa se bloquea hasta transferir o resolver la responsabilidad del negocio.
- La eliminación conserva pedidos y datos comerciales que deban mantenerse, pero desvincula la cuenta según la migración aplicada.
- Los favoritos se eliminan con la cuenta cuando exista la tabla.
- Los objetos Storage asociados se detectan y se tratan antes del borrado Auth.
- El cierre global revoca refresh tokens; se comprueba que los endpoints sensibles rechacen operaciones aunque exista un access token anterior todavía no expirado.
- El proceso es idempotente: repetir una solicitud no duplica tareas ni elimina datos ajenos.

## Estado de implementación

- **Revisado:** `cuenta.html`, `cuenta.js`, políticas de `profiles`, dependencias de claves foráneas, buckets Storage y documentación vigente de Supabase Auth.
- **Corregido en código:** no se realizaron correcciones funcionales en esta auditoría.
- **Documentado:** hallazgos, riesgos y diseño recomendado en este archivo.
- **Pendiente de implementación:** exportación, edición de perfil, cambio de correo, solicitud/eliminación de cuenta, tratamiento de membresías, revocación global y política de retención.
- **Pruebas:** no ejecutadas. No se presenta un informe de resultados de pruebas.

## Límites

Este documento se guarda únicamente en `correcciones-funcionales`. No se ejecutó SQL de escritura, no se modificaron usuarios ni sesiones, no se alteró Auth o Storage, no se desplegó una Edge Function, no se fusionó ningún PR, no se modificó `main` y no se publicó GitHub Pages.


## Inconsistencia detectada: aviso de tratamiento frente al checkout — 16 nov 2026

La sección 7 del aviso de tratamiento de datos y los apartados de pedidos/pagos de los términos en `app.js` todavía describen el formulario como una demostración local que no guarda ni envía pedidos. En el mismo código, el checkout invoca `create-public-order`, que llama a la RPC `create_public_order`; el seguimiento también usa la Edge Function `track-public-order`.

Por tanto, los textos publicados no describen con precisión el flujo técnico actual. La consulta de solo lectura encontró cero pedidos en la tabla activa, pero eso no elimina el hecho de que el código puede transmitir y almacenar datos personales cuando se utiliza.

**Pendiente antes de activar el servicio:** actualizar política, aviso y términos para identificar qué datos de cliente/domicilio se recogen, quién decide el tratamiento, finalidades, proveedores reales, conservación, derechos, pagos, entrega, cancelaciones y canales de comunicación. Distinguir mensajes necesarios para gestionar una compra de comunicaciones promocionales. Completar los datos del responsable que siguen como marcadores `[COMPLETAR]` y validar los textos con asesoría legal colombiana. No se modificaron los textos legales en esta auditoría.
