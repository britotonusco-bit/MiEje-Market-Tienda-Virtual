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


### Evidencia de autorización del checkout pendiente

El checkout presenta una casilla obligatoria `privacyConsent`, pero el manejador de `app.js` no incluye su valor en la llamada a `create-public-order`. La Edge Function y la RPC activa tampoco reciben ni almacenan evidencia de autorización, y `orders` no tiene columnas para fecha, versión del aviso o finalidad. La validación del navegador no es evidencia persistente ni puede sustituir una comprobación del servidor.

Antes de activar el servicio, determinar con asesoría legal qué autorizaciones son necesarias y registrar en servidor la evidencia mínima correspondiente (fecha, versión del aviso, finalidad y vínculo con la operación). Mantener separadas las finalidades necesarias para gestionar el pedido de las comunicaciones promocionales opcionales. La casilla actual no debe presentarse como prueba de consentimiento almacenado.


## Auditoría de postulaciones laborales, consentimiento y conservación — 16 nov 2026

### Alcance y evidencia

Se revisaron en modo solo lectura la Edge Function activa `create-job-application`, su versión en `correcciones-funcionales`, la RPC activa `submit_public_job_application`, el esquema/RLS/grants de las tablas de postulaciones y sesiones, y el bucket `job-applications-private`. No se consultaron ni expusieron datos personales de postulantes.

En la consulta realizada, `job_applications`, `job_application_upload_sessions` y `job_application_rate_limits` tenían cero filas. Esto solo describe el estado en el momento de la consulta; no demuestra que el flujo no pueda almacenar postulaciones.

### 1. Consentimiento: comprobación real en servidor, evidencia incompleta

- El formulario de vacantes envía `privacy_consent` como booleano.
- La Edge Function activa rechaza la postulación si el valor no es `true`.
- La RPC activa también valida `p_privacy_consent IS DISTINCT FROM true` y la tabla tiene una restricción `privacy_consent = true`. Por tanto, la aceptación no depende únicamente del navegador.
- La tabla `job_applications` guarda `privacy_consent`, pero no registra una marca temporal específica del consentimiento, versión del aviso, finalidad autorizada ni texto/identificador del aviso aceptado. `created_at` registra la creación de la postulación, pero no identifica de forma independiente qué aviso vio la persona.

**Conclusión:** existe una validación de aceptación y se persiste un booleano, pero la evidencia no es suficientemente detallada para reconstruir qué versión del aviso se aceptó y para qué finalidades. Definir con asesoría legal colombiana el texto y la base jurídica aplicable. Si se requiere autorización, guardar en servidor una versión inmutable del aviso, fecha/hora y finalidades, vinculadas a la postulación. No tratar una sola casilla como autorización general para comunicaciones promocionales.

### 2. Protección de postulaciones y aislamiento por negocio

- RLS está habilitado en `job_applications`, `job_application_upload_sessions` y `job_application_rate_limits`.
- La política SELECT de `job_applications` permite leer al administrador activo del negocio correspondiente mediante `private.has_business_role(business_id, ['business_admin'])`.
- La política UPDATE aplica el mismo límite de negocio y exige que el negocio continúe activo; también usa `WITH CHECK`.
- La función helper comprueba una membresía activa del usuario autenticado, el rol permitido y que el perfil no esté bloqueado.
- No se encontraron políticas para lectura/escritura directa de las tablas de sesiones temporales o límites; sus grants de tabla observados se reservan a `service_role` y `postgres`.
- La política activa de Storage para CV permite SELECT a administradores activos del negocio indicado por la primera carpeta de la ruta. No concede lectura a visitantes ni empleados. El helper de membresías no concede acceso global al propietario técnico por el mero hecho de tener el rol de plataforma.

**Pendiente de prueba:** confirmar con cuentas ficticias A/B que el administrador A no puede leer ni descargar postulaciones/archivos de B, que el empleado no puede acceder a CV y que el técnico no obtiene acceso global salvo que exista una autorización de negocio explícita. La consulta de políticas no sustituye pruebas de autorización reales.

### 3. Carga de hojas de vida

Controles observados:
- El bucket `job-applications-private` es privado, con límite de 5 MB y MIME permitido PDF/DOC/DOCX.
- La ruta vincula UUID del negocio, UUID de postulación y nombre de archivo aleatorio.
- La Edge Function valida que el negocio esté activo y que la página corresponda a una vacante publicada, aprobada y del mismo negocio.
- La solicitud de carga genera primero el token firmado de Storage y obtiene su vencimiento real desde el claim `exp` del token. La sesión SQL vence cinco minutos después de ese instante; así, la limpieza no puede borrar el archivo mientras el token siga vigente. Se rechazan tokens sin `exp`, vencidos o con una vigencia superior a 24 horas.
- Al enviar, el servidor comprueba sesión, negocio, página, ruta, vencimiento y que el objeto exista; la RPC vuelve a validar la sesión y la consume dentro de una transacción.

Riesgos pendientes:
- La validación usa extensión, MIME declarado y tamaño. No verifica la firma binaria real del documento ni ejecuta análisis antimalware.
- El tamaño del archivo se valida inicialmente con el valor enviado por el navegador y después con los metadatos de Storage; se debe conservar el límite del bucket como control del servidor.
- `form_responses` solo se comprueba como objeto JSON. No se encontró un límite explícito de bytes, número de campos o profundidad antes de guardarlo. Añadir límites de tamaño y estructura para evitar almacenamiento abusivo.
- No se hicieron pruebas con archivos reales ni pruebas A/B de descargas. No se afirma que el aislamiento haya superado pruebas dinámicas.

### 4. Diferencia entre la función activa y la rama

La Edge Function activa `create-job-application` es versión 2. La revisión de solo lectura mostró que su limitador usa un contador común para las acciones de preparación de carga y envío. En la rama `correcciones-funcionales`, el código valida primero la acción y separa el contador por acción, evitando que la carga legítima consuma el mismo cupo que el envío de la postulación.

Por tanto, el código de GitHub no coincide completamente con la función desplegada. La revisión de la rama no se encuentra activa en Supabase.

**Pendiente:** probar la versión de la rama en staging, desplegarla allí junto con sus dependencias y verificar límites, reintentos, errores y carga/entrega. No desplegar directamente en el proyecto activo.

### 5. Conservación, sesiones temporales y eliminación de CV

- La sesión temporal expira cinco minutos después del vencimiento real del token firmado de carga. Esa expiración SQL no borra por sí sola el archivo del bucket.
- El borrador `database/maintenance/job-application-cleanup-draft.sql` y la Edge Function `cleanup-job-application-data` existen en la rama, pero la función de limpieza no está desplegada y la RPC de listado de sesiones vencidas no está instalada en la base activa.
- La limpieza candidata elimina archivos huérfanos de sesiones vencidas y filas antiguas del limitador. Cuando una postulación existe, conserva el CV y retira solo la sesión temporal.
- No se encontró un plazo ni un proceso aprobado para eliminar postulaciones completadas o sus hojas de vida. En consecuencia, los CV asociados a postulaciones pueden permanecer almacenados sin una fecha de eliminación definida.
- No se encontró una tarea programada activa para ejecutar la limpieza. La extensión `pg_cron` no está instalada en el proyecto consultado; la existencia de una Edge Function en GitHub no equivale a que exista una programación activa.

**Riesgo alto de privacidad:** falta una política de conservación y eliminación para postulaciones completas y CV. Definir plazos por finalidad con asesoría legal y de recursos humanos; aplicar una rutina autenticada, auditable e idempotente que elimine tanto el objeto Storage como los datos que ya no deban conservarse. Mantener separados los registros mínimos que deban preservarse por obligación legal o defensa de reclamaciones. No inventar un plazo hasta que se apruebe.

### 6. Estado y acciones requeridas

1. Alinear la Edge Function activa con la versión revisada de la rama, después de pruebas en staging.
2. Añadir evidencia de consentimiento con versión del aviso, fecha/hora y finalidades.
3. Validar tamaño y estructura de `form_responses` en el servidor.
4. Incorporar validación de contenido real y un proceso de análisis de archivos antes de permitir su descarga.
5. Probar aislamiento A/B, empleado, visitante y técnico con usuarios ficticios.
6. Instalar y probar la limpieza de sesiones vencidas y archivos huérfanos; configurar su ejecución controlada.
7. Definir e implementar retención y eliminación de postulaciones/CV completados.
8. Actualizar el aviso de privacidad y la información de vacantes para explicar responsable, finalidades, destinatarios, conservación y canal para ejercer derechos.

**Resultado:** la postulación sí exige y almacena un booleano de aceptación en servidor, y el bucket de CV es privado. Sin embargo, no hay evidencia versionada del aviso ni política de retención de postulaciones completas; la limpieza candidata solo cubre sesiones/archivos huérfanos. La versión activa de la Edge Function no coincide plenamente con la rama. No se ejecutaron pruebas dinámicas, no se modificó Supabase, no se desplegó ninguna función y no se alteraron archivos de postulantes.


### Correcciones preparadas en la rama: carga de CV y validación de respuestas — 16 nov 2026

La revisión complementaria detectó que el navegador cargaba la hoja de vida antes de enviar el consentimiento. Aunque la Edge Function y la RPC rechazaban la postulación final sin consentimiento, la persona podía obtener un token firmado y transferir el archivo antes de esa validación. Esto no cumplía el orden esperado de autorización.

Cambios preparados únicamente en `correcciones-funcionales`:
- El formulario comprueba la casilla antes de iniciar el proceso.
- La acción de servidor `request_upload` también exige `privacy_consent = true` antes de crear la sesión y emitir el token firmado. La comprobación del navegador no es la barrera de seguridad.
- La acción `submit` limita las respuestas personalizadas a 20 campos, claves de hasta 80 caracteres, valores de texto de hasta 500 caracteres y 16 KiB serializados.
- Antes de registrar la postulación, el servidor descarga el archivo privado y comprueba la firma binaria inicial correspondiente a PDF, DOC u OOXML/ZIP, además de la extensión y el límite de tamaño. Si la firma no coincide, elimina el objeto y la sesión temporal.

Archivos modificados:
- `app.js`
- `supabase/functions/create-job-application/index.ts`

Límites de la corrección:
- La comprobación de cabecera no reemplaza un análisis antimalware ni garantiza que el documento completo sea válido o seguro.
- La autorización sigue guardándose como booleano; todavía falta registrar versión del aviso, fecha/hora y finalidades autorizadas.
- La política de conservación y eliminación de CV/postulaciones sigue pendiente.
- La función activa de Supabase continúa en versión 2. Estos cambios están en GitHub y no están desplegados.
- No se ejecutaron pruebas dinámicas ni se cargaron documentos reales. Se requiere probar en staging con archivos válidos e inválidos, ausencia de consentimiento, exceso de respuestas, vencimiento de sesiones y aislamiento A/B.

Commits de la rama:
- `app.js`: `eac652a511410976867ba933584629289c94c031`
- `supabase/functions/create-job-application/index.ts`: `09635732018b6398215e5b76b85bdc1c43a7db53`


### Auditoría del acceso a postulaciones y descarga de hojas de vida desde el panel — 16 nov 2026

**Panel real revisado:** `panel-negocio.html` + `panel-live.js`. El archivo `panel-admin.html` es un prototipo visual general desconectado; no debe confundirse con el panel operativo del administrador de negocio.

**Controles verificados en código y Supabase activo (consultas de solo lectura):**
- `loadJobApplications()` consulta los campos necesarios de `job_applications`, filtra por `business_id = businessId` y limita la lista a 100 registros.
- La política RLS `job_applications_business_admin_read` permite SELECT únicamente cuando `private.has_business_role(job_applications.business_id, ['business_admin'])` devuelve verdadero. La función comprueba `auth.uid()`, membresía activa, perfil no bloqueado y rol exacto.
- El administrador actualiza estado/notas con filtros por ID y `business_id`; la política UPDATE exige el rol de administrador y que el negocio esté activo, tanto en USING como en WITH CHECK.
- La tabla no concede SELECT a `anon`; la política pública existente es INSERT con consentimiento verdadero y vacante publicada/aprobada en negocio activo. La tabla de sesiones de carga no concede privilegios a `anon` ni `authenticated`.
- El bucket `job-applications-private` está marcado como privado, con límite de 5 MiB y MIME permitidos PDF/DOC/DOCX.
- La política de lectura de Storage exige bucket correcto, carpeta inicial con UUID de negocio, negocio activo y membresía `business_admin` para ese negocio. No se encontró una política pública de lectura para ese bucket.
- El panel crea enlaces firmados de descarga con vigencia de 300 segundos por archivo, después de consultar la postulación. La URL temporal no es un enlace permanente.
- La función `private.has_business_role` es SECURITY DEFINER pero está en esquema no expuesto, fija `search_path` vacío y compara contra `auth.uid()`; no se observó una autorización basada en metadata editable del usuario.

**Riesgos y pendientes:**
- El panel solicita hasta 100 postulaciones y crea enlaces firmados en paralelo para cada CV; conviene implementar paginación y generar el enlace solo cuando el administrador pulse Descargar, para reducir solicitudes simultáneas y exposición innecesaria de URLs temporales.
- El panel muestra datos de contacto, mensaje y respuestas de cada postulante al administrador del negocio; esto coincide con la función de selección, pero debe reflejarse en el aviso de privacidad y en una política de conservación/eliminación.
- No se realizaron pruebas dinámicas con dos cuentas y dos negocios; por tanto, el aislamiento está respaldado por filtros y políticas inspeccionadas, pero no se declara probado en ejecución.
- No se descargaron archivos ni se consultaron filas reales de postulantes.

**Resultado:** no se detectó una vía de lectura pública en las políticas inspeccionadas ni una consulta del panel sin filtro de negocio. No se modificó código en este paso porque los controles existentes observados ya aplican la separación por negocio. Quedan pendientes pruebas dinámicas, paginación/descarga bajo demanda, conservación y evidencia de consentimiento versionada.


### Mejora de descarga bajo demanda — 16 nov 2026

Se modificó `panel-live.js` para que el panel no genere hasta 100 enlaces firmados al cargar la lista. Ahora muestra un botón por CV y solicita el enlace firmado de 300 segundos únicamente cuando el administrador pulsa Descargar. La ventana se abre durante la interacción para evitar que el navegador bloquee la descarga después de la respuesta asíncrona; si la creación del enlace falla, se cierra la ventana temporal. El servidor Storage sigue aplicando la política RLS del bucket.

Verificación estática posterior al guardado: se confirmó que el archivo de la rama contiene el botón `data-download-resume`, la llamada `createSignedUrl(path, 300, ...)`, la apertura previa de ventana y que ya no usa `Promise.all(rows.map(async ...))` para generar enlaces durante la carga. No se ejecutó una prueba de navegador ni se descargó ningún CV real.


### Correcciones adicionales de vacantes — 19 nov 2026

Se reforzó el flujo de postulaciones en `correcciones-funcionales`:

- La respuesta de la Edge Function ahora incluye `Cache-Control: no-store, private, max-age=0`, `Pragma: no-cache` y `X-Content-Type-Options: nosniff`. Esto es especialmente importante porque la acción `request_upload` devuelve un token temporal de carga.
- El formulario y la Edge Function usan la versión `job-application-2026-11-19-v1`. Tanto la preparación de la carga como el envío final rechazan una aceptación ausente o con versión distinta.
- La migración nueva `database/jobs/job-application-consent-draft.sql` añade `privacy_consent_version` y `privacy_consent_at`, permitiendo conservar los registros históricos sin evidencia versionada.
- La RPC `submit_public_job_application` valida la versión y guarda la fecha con `pg_catalog.transaction_timestamp()`. Se corrigió también el GRANT para que coincida con la firma de diez argumentos.
- El verificador integral ahora revisa las tablas/RLS, las políticas de administrador, los permisos de columnas, el bucket privado y las firmas/privilegios de las RPC de postulación y limpieza.

**Límite importante:** la versión identifica el aviso aceptado, pero no convierte automáticamente el texto actual en un aviso jurídicamente aprobado. El contenido, finalidades, base jurídica, periodo de conservación y mecanismo para atender solicitudes de titulares deben revisarse antes de producción. La política de retención de postulaciones y CV sigue sin definirse.

**Dependencia del esquema:** no se encontró en el repositorio una migración completa de creación de `job_applications`, `job_application_upload_sessions` y `job_application_rate_limits`. La nueva migración añade columnas sobre las tablas existentes; no sustituye el DDL base. Recuperar y revisar el esquema aprobado antes de preparar un staging desde cero.

No se aplicó SQL ni se desplegó la Edge Function. No se ejecutaron pruebas dinámicas ni análisis antimalware. Las comprobaciones nuevas del verificador están preparadas para staging.


### Ajustes complementarios del flujo de vacantes — 19 nov 2026

La Edge Function ahora devuelve cabeceras `no-store` y `nosniff` para todas sus respuestas, incluida la respuesta que contiene el token temporal de carga. El limitador por IP dejó de usar `X-Forwarded-For` como alternativa: ese encabezado puede contener valores enviados por el cliente si el proxy no lo reemplaza. Se confía únicamente en `cf-connecting-ip`; si el proxy no proporciona ese dato, la solicitud se rechaza en vez de omitir el control.

El verificador integral también comprueba que:
- las tres tablas privadas tengan RLS;
- los roles públicos no puedan consultar ni alterar sesiones o contadores;
- el administrador solo pueda actualizar estado y notas, no cambiar la pertenencia del negocio, la identidad del postulante ni la ruta del CV;
- la política Storage de lectura relacione el archivo con la fila de postulación y el negocio;
- no existan políticas de escritura directa sobre el bucket privado;
- las RPC de registro, rate limit y limpieza sean ejecutables únicamente por `service_role`.

La política de retención sigue abierta: la limpieza elimina sesiones temporales y archivos huérfanos, pero no decide cuándo borrar postulaciones completas o CV ya asociados. Ese plazo requiere una decisión documentada del responsable del tratamiento y revisión jurídica; no se fijó automáticamente.


**Dependencias adicionales que faltan en el repositorio:** la función Edge invoca `consume_job_application_rate_limit`, pero no se encontró su definición SQL ni un archivo que cree las tres tablas base. El verificador ahora exige que la RPC exista y sea ejecutable solo por `service_role`; esto no reemplaza la necesidad de recuperar su DDL y probar su contador en staging. También se debe confirmar que el proxy de staging suministre `cf-connecting-ip`, ya que el código falla de forma cerrada si falta.


### Ajuste del guardado de postulaciones desde el panel

La interfaz del administrador actualizaba `reviewed_by` y `reviewed_at` usando valores construidos en el navegador. Se retiraron esos dos campos del UPDATE: el panel ahora envía únicamente `status` y `admin_notes`, que son los campos operativos previstos para el administrador. La identidad del revisor y la fecha no deben confiarse al cliente; si se requiere conservar esa auditoría, debe implementarse con trigger o RPC en PostgreSQL que obtenga el usuario desde `auth.uid()` y la fecha desde el servidor. El verificador ahora falla si `authenticated` tiene permiso de actualizar directamente `reviewed_by` o `reviewed_at`.

La función de limpieza también devuelve ahora `Cache-Control: no-store`, `Pragma: no-cache` y `X-Content-Type-Options: nosniff` en todas sus respuestas.


### Migración propuesta para auditoría de revisión

Se creó `database/jobs/job-application-review-audit-draft.sql` (paso 20). Revoca UPDATE a nivel de tabla y los permisos por columna sobre datos de identidad, contacto, respuestas, CV y metadatos de auditoría. Solo concede al rol `authenticated` UPDATE de `status` y `admin_notes`. Un trigger BEFORE UPDATE genera `reviewed_by` mediante `auth.uid()` y `reviewed_at` con `pg_catalog.transaction_timestamp()`.

El panel `panel-live.js` se ajustó para enviar únicamente `status` y `admin_notes`. Ya no confía en el navegador para indicar quién revisó la postulación ni cuándo. El verificador integral comprueba que no exista UPDATE a nivel de tabla para `authenticated`, que no pueda modificar directamente los metadatos y que el trigger esté instalado.

**Orden requerido:** aplicar el esquema base aprobado de vacantes, luego los pasos 18 y 19 según el README, y finalmente el paso 20. La migración es un borrador y no se ha ejecutado en Supabase. Confirmar también que la policy RLS de UPDATE continúa limitando cada fila al administrador del negocio activo.


El paso 20 también agrega la restricción `job_applications_status_allowed_check`, que limita los estados a `pending`, `reviewing`, `contacted`, `accepted` y `rejected`. Antes de crearla, el script comprueba que no existan estados históricos fuera de ese catálogo; si encuentra alguno, se detiene para revisión manual. El panel valida los mismos valores y limita las notas a 3000 caracteres, pero la restricción de PostgreSQL es la protección definitiva frente a solicitudes directas.


### Alcance real de la limpieza de archivos huérfanos

La función `cleanup-job-application-data` no recorre el bucket completo buscando objetos sin fila SQL. Obtiene únicamente sesiones vencidas devueltas por `list_expired_job_application_upload_sessions` y valida que cada ruta corresponda al negocio, la sesión y un nombre UUID con extensión permitida. Si existe una postulación vinculada, conserva el objeto y elimina solo la sesión temporal; si no existe, elimina el objeto de esa sesión y después la fila. Si Storage falla, conserva la fila para reintentar.

Por tanto, el alcance probado por lectura de código es **limpieza de objetos asociados a sesiones vencidas**, no detección general de todos los objetos huérfanos del bucket. No se debe ampliar la eliminación a un barrido indiscriminado: cualquier rutina futura debe comparar rutas con postulaciones y sesiones, limitarse a un prefijo validado y registrar cada eliminación. Los objetos sin sesión detectable requieren un proceso separado de conciliación y revisión antes de borrarse.

La migración de permisos del paso 20 se reforzó para revocar dinámicamente las concesiones UPDATE por columna de todas las columnas reales, salvo `status` y `admin_notes`; luego revoca esos dos permisos a todos los roles y los concede únicamente a `authenticated`. Así no depende de que el listado de columnas del esquema base esté completo.


### Revisión adicional de integridad de inventario — 19 nov 2026

La lectura de `business-admin-boundaries.sql` confirma que el permiso directo de UPDATE sobre `products.inventory` se revoca a `authenticated` y `anon`. El ajuste de existencias se canaliza por `adjust_business_inventory`, que valida negocio activo y rol `business_admin`, bloquea la fila del producto y compara las existencias esperadas antes de guardar. El historial `inventory_movements` tiene RLS y una política de lectura para el administrador del negocio activo.

Se amplió `verify-integration-package.sql` para comprobar en staging que: ningún cliente pueda insertar, modificar o borrar el historial; nadie pueda actualizar directamente `products.inventory`; la RPC sea `SECURITY DEFINER` con `search_path` vacío; y la política de lectura del historial exija administrador y negocio activo. Estas son comprobaciones estáticas del verificador; todavía no se han ejecutado contra staging ni producción.


### Comprobación estática de checkout y cancelaciones — 19 nov 2026

Se amplió el verificador de integración para revisar el contenido de las RPC instaladas en staging: el checkout debe ordenar los productos por UUID antes de bloquearlos, usar bloqueo de fila y descontar inventario; la aprobación de cancelación debe bloquear productos en orden estable, sumar las cantidades de las líneas y comprobar que se restituyeron todos los productos esperados. Esto no sustituye pruebas concurrentes reales ni confirma que las funciones ya estén desplegadas.


### Conciliación de moneda en reportes y reembolsos — 19 nov 2026

El borrador del reporte de ganancias ahora filtra explícitamente en COP tanto los pagos como los reembolsos, evitando sumar movimientos de otra moneda como si fueran pesos colombianos. El verificador de integración inspecciona la RPC de reembolso para exigir bloqueo del pedido, estado cancelado, estado de pago pagado, exactamente un pago completado por el total, moneda COP y solicitud aprobada. También comprueba que el reporte financiero filtre COP. Son comprobaciones del código del borrador y del verificador; no certifican que la base activa tenga estas definiciones.


### Gastos pagados y conservación del histórico — 19 nov 2026

Se detectó que la RPC de anulación permitía cambiar a `voided` un gasto que ya estaba pagado. Como el reporte solo suma gastos `active` y `paid`, esa anulación retiraba el importe de periodos históricos sin crear un movimiento compensatorio. Se corrigió el borrador para permitir anular únicamente gastos pendientes. La función de trigger también exige que el gasto permanezca pendiente durante la anulación y el verificador de integración comprueba ambas condiciones. Los gastos pagados deben conservarse; una corrección de un pago ya realizado requiere un procedimiento de reversión auditado que todavía no forma parte de este alcance.


## Revisión de acceso a perfiles y membresías — 19 nov 2026

Se consultaron en modo solo lectura las políticas y privilegios del proyecto Supabase activo `cqixlrwbqatbhzmpygiz`.

**Hallazgos activos:**
- `profiles` tiene RLS habilitado y no concede SELECT a `anon`. Su política `profiles_select_self_or_owner` permite que el propietario técnico lea todos los perfiles, además del suyo.
- `business_memberships` tiene RLS habilitado y no concede SELECT a `anon`. Su política activa `memberships_select_self_admin_owner` permite lectura de todas las membresías al propietario técnico, además de la cuenta propia y administradores de negocio.
- `authenticated` no tiene UPDATE de tabla completo sobre `profiles`, pero sí tiene UPDATE por columna para `display_name`, `phone` y `avatar_url`. No tiene UPDATE sobre `platform_role`, `is_blocked` ni `blocked_reason`.
- La política de UPDATE del perfil limita la fila a `id = auth.uid()`.

**Corrección preparada en `correcciones-funcionales`:**
- La política de lectura de perfiles se sustituye por `profiles_select_self`, limitada al usuario autenticado.
- La lectura de membresías queda limitada a la propia cuenta o al administrador activo del negocio. Se elimina el bypass global del propietario técnico.
- La gestión técnica de usuarios y membresías debe continuar por Edge Functions/RPC de servidor, con operaciones explícitas y sin conceder acceso general a datos personales.

**Verificador:** se añadieron comprobaciones para exigir las políticas anteriores y asegurar que `authenticated` no pueda modificar `platform_role`, `is_blocked` ni `blocked_reason`.

**Pendiente:** ejecutar el paquete en staging y probar dos usuarios de negocios distintos, un cliente sin membresía y el propietario técnico. La base activa no se modificó; las políticas nuevas son borradores en GitHub.


### Verificación de dependencias de cuenta en Supabase activo — 19 nov 2026

Una consulta estrictamente de solo lectura confirmó que la base activa todavía no contiene `public.customer_favorites` ni `orders.customer_user_id`. Por tanto, el código de favoritos y el historial de pedidos vinculados a una cuenta dependen de migraciones que aún no se han aplicado. La ausencia de estas estructuras no debe confundirse con un error de interfaz.

La cuenta web actualmente incluye autenticación, historial previsto y favoritos previstos, pero no ofrece todavía formularios para editar el perfil ni descargar/exportar los datos personales. Tampoco hay un flujo de autoservicio para solicitar eliminación de cuenta. Estas funciones quedan como trabajo pendiente y no se deben simular con controles que no ejecuten una operación real.

Las políticas más restrictivas para perfiles y membresías se añadieron a `business-admin-boundaries.sql` en `correcciones-funcionales`; el verificador exige que no exista lectura global del propietario técnico. No se ejecutó la migración en Supabase activo.


## Revisión complementaria de derechos y exposición de datos — 19 nov 2026

### Comprobación adicional de la base activa

Se consultó el catálogo del proyecto Supabase `cqixlrwbqatbhzmpygiz` en modo de solo lectura. La lista de migraciones registradas llega hasta `secure_public_job_application_submission` (12 migraciones); no incluye la migración `customer-account-migration.sql` ni las migraciones posteriores de permisos financieros.

Hallazgos confirmados en el esquema activo:

- `customer_favorites` y `orders.customer_user_id` no están instalados.
- `profiles` permite SELECT por la política `profiles_select_self_or_owner`, que conserva lectura global para el propietario técnico.
- `business_memberships` conserva `memberships_select_self_admin_owner`, con lectura global del propietario técnico.
- `orders` concede a `authenticated` SELECT por columna sobre datos de contacto y entrega (`customer_name`, `customer_phone`, `customer_email`, `delivery_address`, `delivery_notes`), importes, estado/método de pago y `public_tracking_token`.
- La política activa `orders_members_select` permite esa lectura a miembros del negocio y también conserva el bypass `private.is_platform_owner()`. Por tanto, los permisos de columna amplían la información accesible a empleados y administradores del negocio respecto del mínimo operativo.
- `audit_logs` permite SELECT de `details` a usuarios autenticados sujetos a la política de auditoría. El contenido de ese JSON debe mantenerse minimizado y no debe contener secretos ni datos de contacto innecesarios.

La rama ya contiene un diseño más restrictivo: elimina el bypass técnico directo de pedidos, retira SELECT general y concede un conjunto limitado de columnas operativas. Los importes se consultan mediante RPC autorizadas. El cambio sigue siendo un borrador hasta aplicar y probar el paquete en staging.

### Alcance de la lectura operativa en la rama

La concesión propuesta para los miembros del negocio mantiene visibles nombre, teléfono, dirección y notas de entrega, porque pueden ser necesarios para preparar y entregar el pedido. No concede lectura directa de correo, método/estado de pago, importes, token de seguimiento ni vínculo interno con la cuenta. Esta exposición operativa debe revisarse con el negocio y limitarse a empleados cuyas tareas realmente requieran esos datos; RLS por negocio no sustituye la minimización por función.

### Procedimiento de consultas y reclamos

Como referencia de diseño para Colombia, la Ley 1581 de 2012 reconoce, entre otros, los derechos a conocer, actualizar y rectificar datos, solicitar prueba de autorización, conocer el uso dado a los datos y acceder gratuitamente a ellos. La supresión o revocatoria no es automática en todos los casos: debe evaluarse frente a las condiciones legales y a deberes legales o contractuales de conservación.

La ley establece, como regla general:
- Consultas: máximo 10 días hábiles; si no es posible responder, se informa el motivo y la nueva fecha, que no puede superar 5 días hábiles adicionales.
- Reclamos completos: máximo 15 días hábiles desde el día siguiente a su recepción; si no es posible responder, se informa el motivo y la nueva fecha, que no puede superar 8 días hábiles adicionales.
- Si el reclamo está incompleto, se requiere completar dentro de los 5 días siguientes a su recepción.

El sistema todavía no registra fechas de recepción, vencimientos, prórrogas, subsanaciones, responsable asignado, respuesta ni evidencia de notificación. Estos campos deben formar parte del futuro módulo de solicitudes de titulares. La clasificación entre consulta y reclamo debe definirse al recibir la solicitud, no inferirse solo por un botón de “eliminar cuenta”.

**Fuente normativa consultada:** Ley 1581 de 2012, artículos 8, 11, 12 y 14 a 18, compilación oficial de Cancillería: https://cancilleria.gov.co/normograma/compilacion/docs/ley_1581_2012.htm. Esta nota es un criterio técnico de implementación, no sustituye revisión jurídica del aviso, de las finalidades ni de la relación entre MiEje Market y cada negocio.

### Responsables y encargados del tratamiento

No se debe asumir que MiEje Market o cada negocio tiene automáticamente una única calidad jurídica para todos los datos. La calidad de responsable o encargado depende de quién decide las finalidades y medios del tratamiento y de quién trata datos por cuenta de otro. Antes de habilitar solicitudes, definir por finalidad y conjunto de datos: quién responde al titular, quién ejecuta la instrucción, cómo se trasladan solicitudes entre plataforma y negocio y qué acuerdo documenta esas responsabilidades.

### Decisión técnica recomendada

No crear todavía un borrado automático de cuentas ni una exportación que prometa contener “todos los datos”. Primero debe existir un inventario de datos por finalidad y responsable, incluyendo Auth, perfiles, pedidos, artículos, favoritos, postulaciones, CV, Storage, logs y datos conservados por cada negocio. Después implementar un registro de solicitudes con acceso restringido, verificación proporcional de identidad, plazos, estados, trazabilidad y resolución parcial cuando ciertos registros deban conservarse.

### Estado de esta revisión

- Catálogo y políticas de Supabase: consulta de solo lectura completada.
- Cambios en datos o configuración activa: ninguno.
- Cambios funcionales de derechos de titulares: no implementados.
- Documento de auditoría: ampliado con exposición efectiva de columnas y procedimiento de consultas/reclamos.
- Pendiente: validar la política de datos con asesoría jurídica, decidir la asignación de responsabilidades por negocio, aplicar migraciones en staging y probar acceso con cuentas de distintos roles.


## Auditoría de los textos legales visibles en la interfaz — 19 nov 2026

Se inspeccionaron los textos que `app.js` presenta en las vistas legales `privacidad`, `datos` y `terminos`, además de los consentimientos del checkout y del formulario de vacantes en `index.html` y `app.js`.

### Hallazgo crítico: los textos todavía describen un prototipo sin transmisión de datos

Los tres textos contienen afirmaciones incompatibles con el flujo de la rama:

1. **Política de privacidad:** afirma que el formulario de pedido solo muestra una vista previa y no envía datos.
2. **Tratamiento de datos personales:** afirma que el pedido es una demostración, que solo muestra una alerta y que no almacena ni envía información.
3. **Términos y condiciones:** afirma que el carrito/formulario son demostrativos, que no se recibe una compra y que “Revisar pedido” solo muestra una vista previa local.
4. **Checkout real de la rama:** `app.js` envía nombre, teléfono, dirección, notas de entrega, método de pago, artículos y evidencia de consentimiento a la Edge Function `create-public-order`. La función procesa la creación del pedido en el backend.
5. **Vacantes:** `app.js` envía nombre, contacto, mensaje, respuestas personalizadas y, si se adjunta, una hoja de vida al flujo `create-job-application`; el archivo se carga al bucket privado `job-applications-private`.

Por tanto, si esta rama se despliega con esos textos sin corregirlos, la información que se presenta a las personas no describirá el tratamiento real. Es un bloqueo previo a cualquier lanzamiento comercial.

### Identidad y canales sin completar

Los textos de privacidad, tratamiento y términos todavía contienen marcadores como `[COMPLETAR]` para razón social, identificación, domicilio, correo de privacidad y contacto. El canal para consultas y reclamos no está definido. No se debe inventar esa información ni publicar los textos como versión definitiva mientras falte.

### Consentimiento del checkout

- La casilla obligatoria está enlazada a la vista de Política de privacidad.
- La casilla lleva la versión `privacy-2026-11-19-v1`.
- `app.js` envía `privacy_consent` y `privacy_consent_version` a `create-public-order`.
- La Edge Function de la rama valida esa versión.
- Los borradores SQL de la rama prevén persistir la evidencia de consentimiento, pero la migración no está instalada en la base activa.
- El texto de la casilla debe identificar con claridad quién trata los datos, las finalidades necesarias para gestionar el pedido y el vínculo entre la plataforma y el negocio que recibe el pedido. La versión actual no resuelve esa distribución de responsabilidades.

### Consentimiento de vacantes

- La casilla se genera en `app.js` y usa `job-application-2026-11-19-v1`.
- El servidor valida consentimiento y versión tanto al solicitar carga del CV como al enviar la postulación.
- El formulario no enlaza de forma visible el consentimiento con una política específica de tratamiento; el texto solo dice “Autorizo el tratamiento de mis datos para gestionar esta postulación”.
- Se recogen datos de identificación/contacto, mensaje, respuestas personalizadas y potencialmente CV. La política visible debe explicar quién recibe la postulación, para qué se utiliza, quién puede consultarla, cuánto tiempo se conserva y cómo ejercer derechos.
- El bucket CV de la base activa es privado, pero el flujo de rama no está desplegado y el diseño de retención/antimalware sigue pendiente.

### Requisitos mínimos antes de reescribir/publicar los textos

No se modificaron los textos visibles en esta revisión porque faltan datos esenciales del responsable y la definición jurídica del modelo de plataforma/negocios. Antes de redactar una versión final se debe confirmar:

1. Razón social o nombre del responsable, identificación y domicilio.
2. Correo/canal formal de privacidad y atención de consultas/reclamos.
3. En cada finalidad (cuenta, pedido, vacante, soporte, seguridad), qué entidad decide la finalidad y cuál actúa por cuenta de otra.
4. Proveedores y destinatarios reales que reciben datos, incluyendo alojamiento, base de datos, almacenamiento de CV, mensajería y pagos cuando se activen.
5. Datos exactos recolectados en cada formulario y campos opcionales.
6. Plazos o criterios de conservación por categoría, y excepciones por obligaciones legales o controversias.
7. Si se enviarán comunicaciones promocionales; deben mantenerse separadas de la autorización necesaria para tramitar pedidos o postulaciones.
8. Procedimiento y canal para consultas, reclamos, corrección, supresión y revocatoria, con registro de términos y responsables.

### Criterio normativo usado para esta revisión

La Ley 1581 de 2012 exige informar finalidades, derechos y datos de contacto del responsable al solicitar autorización y conservar prueba de la autorización cuando corresponda. El Decreto 1074 de 2015 y sus reglas sobre políticas y avisos precisan el contenido mínimo. La SIC distingue política de tratamiento y aviso de privacidad; aceptar una política genérica no sustituye por sí solo la autorización expresa, previa e informada cuando sea exigible. Fuentes consultadas:

- Ley 1581 de 2012, artículos 4, 8, 12, 14 a 18: https://www.cancilleria.gov.co/normograma/compilacion/docs/ley_1581_2012.htm
- SIC, concepto sobre políticas de tratamiento: https://sedeelectronica.sic.gov.co/publicaciones/boletin-juridico/concepto/politicas-de-tratamiento-de-datos-personales
- SIC, criterio sobre consentimiento y diferencia entre política y autorización: https://sedeelectronica.sic.gov.co/sites/default/files/estados/072022/RE74924-2021.pdf
- Decreto 1074 de 2015, contenido mínimo de políticas y avisos, según material normativo publicado por SIC: https://sedeelectronica.sic.gov.co/sites/default/files/normativa/Resolucion-72126-2023.pdf

### Estado

- Textos y formularios inspeccionados: sí.
- Contradicción entre texto legal y flujo real de la rama: confirmada.
- Cambios en la interfaz legal: no realizados; faltan datos de identidad y decisiones sobre responsables/encargados.
- Recomendación: bloquear el lanzamiento comercial de checkout y postulaciones hasta corregir los textos, confirmar evidencia persistente en staging y validar el aviso con asesoría jurídica colombiana.


## Auditoría de conservación, eliminación y archivos — 19 nov 2026

### Contraste de solo lectura con Supabase activo

Proyecto consultado: `cqixlrwbqatbhzmpygiz`. No se ejecutaron escrituras.

Conteos observados en esta consulta:
- `orders`: 0
- `order_items`: 0
- `profiles`: 1
- `business_memberships`: 0
- `job_applications`: 0
- `job_application_upload_sessions`: 0
- `audit_logs`: 0
- Objetos en `job-applications-private`: 0
- Objetos en `business-assets`: 0

Los conteos describen el estado en el momento de la consulta, no garantizan que sigan iguales. La lista de migraciones activas llega a 12 entradas y no incluye las migraciones de cuentas/clientes, inmutabilidad de auditoría ni los borradores de conservación que están en la rama.

### Dependencias de eliminación de cuentas

La estructura activa muestra:
- `profiles.id → auth.users.id` con eliminación en cascada: borrar el usuario Auth también elimina su perfil.
- `business_memberships.user_id → profiles.id` con `ON DELETE RESTRICT`: una membresía todavía asociada puede impedir eliminar el perfil y, por consecuencia, la cuenta Auth.
- `audit_logs.actor_id → profiles.id` y `job_applications.reviewed_by → profiles.id` con `ON DELETE SET NULL`: se conserva el evento/postulación, pero se pierde el vínculo directo con el perfil eliminado.
- La migración de clientes aún pendiente propone `orders.customer_user_id → auth.users.id ON DELETE SET NULL`: los pedidos quedarían conservados y desvinculados de la cuenta. Los favoritos usarían `ON DELETE CASCADE`.

No existe todavía un flujo completo que resuelva membresías, propiedad de archivos, sesiones abiertas, solicitudes pendientes y evidencia antes de eliminar una cuenta. No debe ofrecerse un botón de eliminación inmediata como si cubriera todo el sistema.

### Dependencias de eliminación de negocios y vacantes

En la base activa, las FK de `job_applications.business_id` y `job_applications.content_page_id` tienen `ON DELETE CASCADE`. Las sesiones temporales también se eliminan en cascada. Esto significa que borrar un negocio o una página de vacante puede borrar las filas SQL de postulaciones.

Los objetos CV están en Storage y no se eliminan automáticamente por una FK de PostgreSQL. La Edge Function `cleanup-job-application-data` de la rama solo procesa sesiones de carga vencidas y archivos temporales sin postulación asociada; no aplica una política de retención a postulaciones completas ni borra CV asociados a una postulación histórica. Por tanto, borrar una página/negocio podría dejar objetos CV sin su fila de referencia. Hasta diseñar y probar un proceso coordinado, se debe archivar/desactivar la página o el negocio y bloquear su eliminación física cuando existan postulaciones con CV.

### Qué elimina hoy la limpieza preparada

La función `cleanup-job-application-data`:
- requiere el secreto independiente `JOB_APPLICATION_CLEANUP_SECRET`;
- procesa sesiones de carga vencidas;
- elimina archivos temporales que no estén asociados a una postulación;
- conserva los CV vinculados a postulaciones;
- elimina registros de rate limit vencidos;
- no elimina postulaciones completas, CV asociados, cuentas Auth, pedidos ni auditoría histórica.

La función no está desplegada en el proyecto activo y no se encontró un programador activo que demuestre su ejecución periódica. No debe presentarse como una política integral de retención.

### Precauciones específicas de Supabase

La documentación oficial de Supabase indica que:
- borrar un usuario Auth no invalida inmediatamente un access token JWT ya emitido; el token puede seguir vigente hasta su expiración;
- no se puede borrar un usuario que todavía sea propietario de objetos de Storage; se deben eliminar los objetos o reasignar su propiedad;
- los objetos deben eliminarse mediante la API de Storage, no borrando filas directamente desde SQL, porque eso puede dejar archivos huérfanos.

Fuentes:
- https://supabase.com/docs/guides/auth/managing-user-data
- https://supabase.com/docs/guides/storage/security/ownership
- https://supabase.com/docs/guides/storage/management/delete-objects

### Matriz de conservación propuesta para decisión — no son plazos aprobados

| Categoría | Tratamiento requerido antes de fijar plazo |
|---|---|
| Perfil y datos de cuenta | Eliminar o anonimizar al terminar la finalidad, salvo vínculos o deberes vigentes. |
| Pedidos, pagos y reembolsos | Conservar el registro comercial mínimo cuando exista obligación legal/contable o controversia; desvincular la cuenta cuando proceda. |
| Líneas de pedido e inventario | Mantener snapshots y movimientos necesarios para integridad y trazabilidad; no borrar en cascada. |
| Favoritos y preferencias | Eliminar al cerrar cuenta o al retirar la finalidad, una vez instalada la migración pendiente. |
| Postulaciones y CV | Definir plazo por proceso de selección y finalidad; separar CV de evidencia mínima de la decisión cuando ya no se requiera el documento. |
| Sesiones temporales de carga | Eliminar tras vencimiento efectivo del token firmado, con margen y ejecución programada comprobada. |
| Logs de auditoría | Conservar eventos mínimos, inmutables y sin datos de contacto o secretos; aprobar un periodo y acceso por rol. |
| Archivos de negocio | Mantener solo mientras el negocio/servicio y su finalidad lo justifiquen; aplicar proceso de eliminación desde Storage API. |

La normativa colombiana exige que la conservación sea razonable y necesaria según la finalidad y las obligaciones legales o contractuales; no se asigna un plazo universal a todas las categorías. Una vez agotada la finalidad, procede la supresión salvo deber de conservación aplicable. Fuentes: Ley 1581 de 2012 y Decreto 1074 de 2015 (compilación normativa), además de criterios de la SIC:
- https://cancilleria.gov.co/normograma/compilacion/docs/ley_1581_2012.htm
- https://www.igac.gov.co/sites/default/files/transparencia/normograma/ley_1581_de_2012.pdf
- https://sedeelectronica.sic.gov.co/sites/default/files/normativa/Resolucion_1645_de_2023.pdf

### Decisiones y correcciones requeridas antes de producción

1. No borrar físicamente negocios o páginas de vacantes mientras existan postulaciones o CV asociados; implementar archivo lógico y un proceso coordinado de retención.
2. Diseñar un flujo de eliminación de cuenta por servidor: verificar identidad, listar dependencias, transferir/revocar membresías, revisar propiedad Storage, revocar sesiones, desvincular pedidos cuando corresponda, eliminar datos no sujetos a conservación y registrar resultado mínimo.
3. Evitar que el registro de auditoría dependa de una FK obligatoria al perfil; conservar identificador técnico mínimo del actor o un identificador seudonimizado cuando la política aprobada lo permita, sin mantener innecesariamente datos personales.
4. Para pedidos, definir qué campos personales deben suprimirse/anonimizarse y cuáles deben mantenerse por obligaciones contables, fiscales, contractuales o defensa de reclamaciones.
5. Definir plazos aprobados para CV, postulaciones, archivos temporales, auditoría y archivos de negocio; configurar un scheduler privado y verificar cada ejecución.
6. Probar la operación con cuentas de cliente, empleado, administrador, propietario técnico y usuarios con objetos Storage, primero en staging.

### Estado de esta revisión

- Catálogo, migraciones, FK y conteos activos: consultados en solo lectura.
- Eliminación de cuenta/negocio: no ejecutada.
- SQL, Auth, Storage y datos activos: sin cambios.
- Riesgo de CV huérfanos por cascadas de negocio/página: documentado.
- Limpieza de CV históricos y política integral de retención: pendiente.
- Plazos de conservación: no inventados; requieren aprobación jurídica y operativa.
