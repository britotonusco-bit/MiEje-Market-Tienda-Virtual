# Auditoría de autenticación de clientes y sesiones — 14 nov 2026

## Alcance y método

Revisión estática de los archivos de la rama `correcciones-funcionales` y consultas de solo lectura al proyecto Supabase `MiEje Market Independiente` (`cqixlrwbqatbhzmpygiz`). No se enviaron correos, no se crearon ni modificaron cuentas, no se alteró la configuración de Auth, no se ejecutó SQL de escritura y no se desplegaron funciones.

## Estado del código revisado

- `cuenta.html` / `cuenta.js`: registro e inicio de sesión de clientes con correo y contraseña. El registro pasa `display_name` como metadata y define `emailRedirectTo` hacia `cuenta.html`. Si Supabase requiere confirmación, la interfaz informa que debe revisar el correo.
- `private.handle_new_auth_user()`: el trigger `on_auth_user_created` crea `profiles(id, display_name)` y no toma el rol desde metadata editable. No asigna membresías ni privilegios internos.
- `recuperar-clave.js`: llama `resetPasswordForEmail` y dirige a `actualizar-clave.html`; la respuesta de éxito es genérica y no confirma si el correo existe.
- `actualizar-clave.js`: mantiene deshabilitado el formulario hasta recibir el evento `PASSWORD_RECOVERY`; una sesión ordinaria almacenada no basta para autorizar el cambio. Tras actualizar la contraseña intenta cerrar la sesión.
- `login.js`: inicia sesión y consulta la Edge Function `resolve-my-access`; solo enruta a paneles si hay perfil válido y membresías activas. El propietario pasa por MFA TOTP/AAL2 en la interfaz antes de entrar al panel técnico.
- `aceptar-invitacion.js`: exige que el enlace esté marcado como invitación y valida el token antes de permitir definir la contraseña. Al completar la activación cierra la sesión.

## Estado observado en Supabase

- El proyecto está activo y saludable.
- Se encontró 1 usuario Auth confirmado y 1 perfil.
- La tabla `auth.sessions` tenía 0 sesiones al momento de la consulta. Por tanto, no había sesiones activas disponibles para una prueba de revocación.
- El trigger `on_auth_user_created` está instalado en `auth.users` y ejecuta `private.handle_new_auth_user()`.
- Los permisos de actualización de `profiles` para `authenticated` se limitan a `avatar_url`, `display_name` y `phone`; no incluyen `platform_role` ni `is_blocked`.
- Las funciones `private.has_business_role` y `private.is_platform_owner` comprueban `profiles.is_blocked = false`. Por ello, un perfil bloqueado deja de satisfacer las comprobaciones RLS en las siguientes operaciones protegidas, aunque el JWT existente no desaparezca por ese solo hecho.
- La tabla `customer_favorites` todavía no existe en el proyecto activo. Su creación y sus políticas están en `database/customers/customer-account-migration.sql`, pendiente de aplicación. El historial requiere además `orders.customer_user_id` y `get_customer_order_history()`, también pendientes según el paquete de integración.

## Hallazgos y pendientes

1. **Confirmación de correo y URL de retorno:** el código cliente envía `cuenta.html` como URL de retorno, pero no fue posible leer la configuración Auth del proyecto mediante las consultas disponibles. Antes de habilitar registros reales se debe comprobar en el Dashboard que la confirmación de correo esté habilitada y que la URL exacta de GitHub Pages esté en Redirect URLs permitidas. También debe probarse la plantilla de correo y la entrega SMTP.
2. **Recuperación de contraseña:** el flujo está implementado en código, pero no se probó con un correo real ni con un enlace vigente/vencido. Se requiere prueba controlada de envío, retorno, cambio y cierre de sesión.
3. **Sesiones:** no se encontraron sesiones activas para validar expiración, renovación o cierre remoto. El bloqueo de perfil invalida las comprobaciones de rol basadas en RLS, pero la revisión no encontró una revocación explícita de todas las sesiones Auth al bloquear una cuenta. Para una garantía inmediata de revocación se debe diseñar y probar un flujo que revoque refresh tokens/sesiones y considerar que un access token JWT ya emitido puede seguir siendo criptográficamente válido hasta expirar; las operaciones sensibles deben comprobar estado de cuenta/sesión en servidor.
4. **Favoritos e historial:** no funcionarán completamente en el proyecto activo hasta aplicar las migraciones pendientes y probar aislamiento entre dos cuentas. Los pedidos de invitado no se vinculan retroactivamente a una cuenta.
5. **Pruebas E2E:** no se realizaron registros, envíos de correo ni cambios de contraseña, para no generar cuentas o afectar usuarios. El proyecto no tiene un entorno staging disponible en este momento.

## Resultado

La estructura de registro, inicio de sesión, recuperación y aceptación de invitaciones existe en la rama de trabajo. La revisión de código no demuestra todavía que los correos lleguen ni que las URL de Auth estén configuradas correctamente. Favoritos e historial dependen de migraciones pendientes. El control RLS sí consulta el estado de bloqueo del perfil, pero falta cerrar y probar la revocación de sesiones Auth.

## Auditoría del historial de compras y favoritos (16 Nov 2026)

### Estado actual observado en Supabase

- La base de datos activa contiene 1 usuario Auth y 1 perfil. El trigger `on_auth_user_created` existe y ejecuta `private.handle_new_auth_user()`, que crea el perfil con `display_name` y no asigna roles desde metadata editable.
- La tabla `orders` existe, pero no contiene todavía la columna `customer_user_id`.
- `public.customer_favorites` no existe todavía.
- `public.get_customer_order_history()` no existe todavía.
- La tabla `orders` contiene 0 pedidos. Por tanto, no se hicieron pruebas con datos de clientes ni se pudo verificar el resultado de una compra real.

### Vinculación de pedidos con la identidad autenticada

- La Edge Function de la rama valida el bearer token con `admin.auth.getUser(bearer)`; no confía en un `customer_user_id` enviado por el navegador.
- Después comprueba que exista un perfil y que `profiles.is_blocked` sea false. Solo entonces deriva el ID de cliente desde `authData.user.id` y lo envía al RPC privado de creación.
- Los pedidos de invitados mantienen `customer_user_id = NULL`; no se vinculan automáticamente después de crear una cuenta.
- La huella de idempotencia incluye el ID de usuario validado por el servidor. Así, reutilizar una clave desde otra cuenta no debe recuperar el pedido de la cuenta anterior.
- La migración de clientes usa `ON DELETE SET NULL` para que borrar una cuenta no elimine pedidos ni su historial comercial.

### Historial y privacidad

- `get_customer_order_history()` es una función `SECURITY DEFINER`, con `search_path` vacío, ejecución revocada a `PUBLIC` y `anon`, y concedida a `authenticated`.
- La función identifica al solicitante mediante `auth.uid()` y limita la consulta a `orders.customer_user_id = auth.uid()`.
- Devuelve como máximo 50 pedidos, con número, estado, método de pago, importes, fecha, negocio y líneas de productos. No incluye teléfono, correo, dirección de entrega, notas ni token privado de seguimiento.
- La función se corrigió para fallar de forma cerrada: exige que exista el perfil y que `is_blocked = false`. Antes solo rechazaba el perfil cuando encontraba explícitamente `is_blocked = true`, lo que permitía continuar si faltaba la fila de perfil.
- La interfaz `cuenta.js` consume el historial mediante el RPC y escapa los textos antes de insertarlos en el HTML. También comprueba que la respuesta corresponda al usuario que sigue activo para evitar renderizar datos de una consulta anterior tras un cambio de sesión.
- Los favoritos se protegen por RLS con `user_id = auth.uid()`; la inserción requiere producto activo y negocio activo, y el usuario solo puede borrar sus propios favoritos. La restricción única impide guardar dos veces el mismo producto para la misma cuenta.

### Interfaz pública de favoritos

- Se encontró que las tarjetas de producto siempre mostraban `♡ Guardar`, incluso cuando el producto ya estaba guardado por la cuenta actual. El servidor sí comprobaba correctamente si el favorito existía antes de insertar o eliminar, pero la etiqueta visual no reflejaba el estado real.
- Se corrigió `app.js` en la rama: al cargar la tienda consulta los IDs favoritos de la cuenta autenticada, muestra `♥ Guardado` para los productos guardados y actualiza el conjunto local después de insertar o retirar un favorito.
- Si no hay sesión, el conjunto se limpia y el usuario es dirigido a `cuenta.html` cuando intenta guardar.
- Esta corrección es de presentación y sincronización de interfaz; la autorización real sigue dependiendo de RLS y de los permisos de la base de datos. El conjunto local del navegador solo controla la etiqueta visual, nunca concede acceso ni sustituye las políticas.
- La consulta inicial depende de que `customer_favorites` esté creada y expuesta en Data API. Mientras la migración y configuración estén pendientes, la consulta puede fallar y los botones no podrán guardar favoritos. No se ha probado en navegador con una tabla activa.

### Requisito adicional de Data API

La migración concede privilegios SQL mínimos y activa RLS en `customer_favorites`, pero eso no garantiza por sí solo que la tabla sea accesible desde `client.from()`. Desde el 30-Oct-2026 las tablas nuevas no se exponen automáticamente por defecto en todos los proyectos. Antes de habilitar favoritos, el propietario debe confirmar en Dashboard > Integrations > Data API que el esquema `public` esté expuesto y que la tabla esté incluida. No se cambió esa configuración durante esta auditoría. <https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically>

### Hallazgos y mejoras pendientes

1. **Perfil ausente en historial:** corregido en el borrador SQL de `database/orders/order-financial-access-draft.sql`; ahora requiere perfil existente y no bloqueado.
2. **Paginación:** el historial devuelve hasta 50 pedidos y no ofrece paginación. Es suficiente para una primera vista, pero se debe diseñar paginación antes de que una cuenta acumule más de 50 pedidos.
3. **Pedidos de invitado:** no se vinculan retroactivamente al crear una cuenta. Debe mantenerse así salvo que se diseñe un proceso independiente de verificación de titularidad; no asociar pedidos solo por coincidencia de correo o teléfono.
4. **Borrado de cuenta:** el FK preserva pedidos y limpia la relación con el usuario. Antes de ofrecer eliminación de cuenta, se debe comprobar la revocación de sesiones y explicar que los pedidos pueden conservarse como registros comerciales sin identificar al usuario.
5. **Data API:** falta confirmar manualmente la exposición de `customer_favorites` en Dashboard; los GRANT SQL y RLS no sustituyen esa configuración.
6. **Pruebas de aislamiento:** faltan pruebas con dos cuentas distintas, invitado, cuenta bloqueada, perfil ausente, negocio suspendido y pedido histórico con producto desactivado.
7. **Paginación y carga:** la consulta agrega hasta 50 pedidos y todas sus líneas en un JSON. Medir la respuesta y paginar si el volumen lo requiere.

### Matriz de pruebas pendiente en staging

- Cliente A consulta solo sus pedidos; Cliente B no puede consultar los pedidos de A.
- Cliente A no puede cambiar la identidad usada para consultar historial.
- Cliente invitado no obtiene historial asociado a una cuenta.
- Un intento autenticado se vincula al ID derivado del JWT verificado por la Edge Function.
- Cambiar de cuenta no permite recuperar un intento idempotente de otra cuenta.
- Perfil bloqueado o inexistente no puede consultar el historial ni crear nuevos pedidos.
- Eliminar una cuenta deja el pedido comercial conservado con `customer_user_id = NULL`.
- Producto desactivado no se puede añadir a favoritos; favorito ya existente puede retirarse aunque el producto deje de estar disponible.
- Dos cuentas no pueden leer ni borrar los favoritos de la otra.
- La tabla de favoritos está incluida en los esquemas expuestos de Data API y responde con los grants y RLS previstos.

### Límites de verificación

Esta revisión fue estática y de solo lectura contra Supabase. La corrección de perfil ausente se guardó solo en `correcciones-funcionales`. No se ejecutó SQL, no se desplegó la Edge Function, no se cambió Data API, no se modificó Auth, no se fusionó el PR y no se publicó GitHub Pages. No se redacta todavía un informe de pruebas porque no se ejecutaron pruebas reales de extremo a extremo.


## Límites de cambios

Este informe se guarda únicamente en `correcciones-funcionales`. No se aplicó SQL, no se modificó configuración Auth, no se desplegó Edge Function, no se fusionó el PR, no se tocó `main` ni se publicó GitHub Pages.


## Corrección añadida después de la auditoría

- `panel-live.js` ahora vuelve a consultar `resolve-my-access` cada 60 segundos mientras el panel está abierto y al regresar a la pestaña.
- Si la sesión deja de ser válida, el perfil aparece bloqueado, desaparece la membresía activa o el propietario pierde AAL2, el cliente cierra su sesión local y vuelve al inicio de sesión.
- La función de acceso devuelve únicamente membresías activas asociadas a negocios activos; la verificación del panel se apoya en esa lista ya filtrada.
- Esta medida reduce el tiempo durante el cual una interfaz abierta puede permanecer visible después de una suspensión. No equivale a revocar en servidor todos los refresh tokens ni invalida por sí sola un JWT ya emitido. Las operaciones de datos continúan dependiendo de RLS y de las validaciones del servidor.
- La revalidación se añadió en `panel-live.js` en la rama `correcciones-funcionales`; requiere que la versión correspondiente de `resolve-my-access` esté desplegada junto con el código antes de publicarse.


## Ajuste de revalidación y cierre de sesión

- La revalidación del panel se ejecuta cada 30 segundos y también cuando el usuario vuelve a la pestaña.
- Cuando detecta pérdida de autorización para el panel actual, cierra únicamente la sesión local (`scope: "local"`). Esto es intencional: una persona puede tener acceso válido a otros negocios y no debe perder todas sus sesiones por la suspensión de una sola membresía.
- La suspensión de una membresía se aplica en servidor y `resolve-my-access` deja de devolverla. Las operaciones protegidas deben seguir comprobando perfil, membresía y estado del negocio en servidor/RLS.
- La revocación global de sesiones debe reservarse para un bloqueo global de la cuenta y ejecutarse desde una operación administrativa de servidor, no desde el navegador cuando pierde acceso a un solo negocio. En el código auditado no se encontró una acción de bloqueo global de perfil que implemente esa revocación.
- Los JWT ya emitidos pueden seguir verificándose hasta su expiración; por eso la comprobación del estado del usuario y de la membresía en cada operación protegida sigue siendo necesaria.
- No se añadieron consultas ni escrituras directas a `auth.sessions`, ni se almacenan JWT de terceros.
- El cambio está en la rama `correcciones-funcionales`; requiere publicar la versión correspondiente para entrar en vigor. No se ha probado con sesiones reales ni se ha desplegado.


## Revisión de configuración y flujos de Auth (14 Nov 2026)

### Código cliente revisado
- `cuenta.js`: registro con `emailRedirectTo` relativo a `cuenta.html`, confirmación de correo contemplada y mensaje cuando Supabase no entrega sesión hasta confirmar. Inicio de sesión por contraseña. La validación de longitud mínima de 10 caracteres está en frontend y debe complementarse con la política de Auth del proyecto.
- `recuperar-clave.js`: usa `resetPasswordForEmail` con destino relativo a `actualizar-clave.html`. El mensaje de éxito es genérico y no confirma si la dirección está registrada.
- `actualizar-clave.js`: no permite cambiar la contraseña solo por tener una sesión ordinaria guardada; exige el evento `PASSWORD_RECOVERY`. Tras el cambio intenta cerrar la sesión.
- `aceptar-invitacion.js`: exige que el enlace tenga tipo `invite`, verifica el token cuando llega como `token_hash`, exige sesión y limpia la URL antes de solicitar contraseña.
- Los destinos relativos de registro y recuperación se resuelven bajo la URL actual de la página; deben probarse desde la URL final de GitHub Pages. La Edge Function de invitaciones usa un destino absoluto a `https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/aceptar-invitacion.html`.

### Configuración del proyecto que no se pudo verificar
La conexión disponible permite consultar estado del proyecto y asesores de seguridad, pero no leer de forma segura la configuración de Auth del Dashboard ni las plantillas/allowlist actuales. Por tanto, no se afirma que estos ajustes estén configurados:
- Confirmación de correo habilitada.
- Site URL y Redirect URLs correctas.
- Plantillas de confirmación, recuperación e invitación.
- SMTP personalizado y remitente verificado.
- Duración del JWT y opciones de sesión.
- CAPTCHA y límites de envío.
- Política de contraseñas configurada en el servidor.

### Recomendaciones antes de producción
1. En Auth > Providers > Email, mantener habilitada la confirmación de correo. La configuración de Auth es la autoridad; la comprobación de 10 caracteres en JavaScript no reemplaza la política del servidor.
2. En Auth > URL Configuration, configurar como Site URL la dirección base de GitHub Pages: `https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/`. Añadir una Redirect URL restringida al mismo directorio del sitio, por ejemplo `https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/**`. No usar comodines globales como `**` sin dominio/ruta restringidos. Revisar también localhost solo si se usa en desarrollo.
3. Revisar las plantillas de Confirm signup, Reset password e Invite user. Mantener el enlace de confirmación estándar `{{ .ConfirmationURL }}`, salvo que se implemente y pruebe un flujo personalizado compatible con la página estática.
4. Configurar SMTP personalizado antes de invitar usuarios externos. El SMTP compartido predeterminado de Supabase es solo para pruebas y restringe los destinatarios a miembros autorizados de la organización; no es un servicio de entrega para clientes generales.
5. Mantener habilitada la protección de contraseñas filtradas. El asesor de seguridad volvió a reportar `auth_leaked_password_protection` como WARN el 14-Nov-2026.
6. La documentación actual de Supabase indica que el control de duración máxima, inactividad y sesión única está disponible desde el plan Pro. La organización del proyecto está en Free; no activar ni presupuestar funciones que el plan actual no ofrece. No se recomienda imponer una sola sesión sin evaluar el uso legítimo en varios dispositivos.
7. Revisar CAPTCHA y límites de Auth antes de abrir registro público a gran escala.

### Estado de verificación
- Auditoría de código: completada estáticamente para los cuatro flujos anteriores.
- Configuración del Dashboard: pendiente de revisión manual por el propietario del proyecto; no accesible mediante las herramientas de solo lectura disponibles.
- Pruebas reales de correo: pendientes. No se enviaron mensajes ni se modificó SMTP, plantillas o URL Configuration.
- Asesor de seguridad actual: un aviso WARN de protección de contraseñas filtradas deshabilitada y tres avisos INFO de RLS sin políticas (tablas de uso interno previamente revisadas).
- No se cambió Auth, no se ejecutó SQL, no se desplegó Edge Function ni se publicó GitHub Pages.


## Auditoría de límites, sesiones y bloqueo de cuentas (16 Nov 2026)

### Límites de solicitudes observados en el proyecto Supabase activo

- **Checkout público:** la Edge Function desplegada `create-public-order` versión 3 llama a `consume_checkout_rate_limit`. La función limita cada IP a 10 solicitudes por ventana de 10 minutos, guarda un hash SHA-256 de la IP y elimina registros con más de 24 horas. La función SQL es `SECURITY DEFINER`, tiene `search_path` vacío y su ejecución está concedida únicamente a `service_role`.
- **Postulaciones laborales:** la Edge Function desplegada `create-job-application` versión 2 llama a `consume_job_application_rate_limit`. El límite es de 5 solicitudes por hash de IP en una ventana de 15 minutos. El contador se consume tanto al solicitar la carga del archivo como al enviar la postulación.
- **Mantenimiento pendiente:** `job_application_rate_limits` conserva una fila por hash de IP y la función de consumo no elimina filas antiguas. La ventana se reinicia, pero los registros históricos pueden acumularse. Antes de ampliar el uso público se debe añadir limpieza programada y verificar su coste.
- **Invitaciones internas:** la función técnica desplegada versión 6 y la versión actual de la rama no tienen un límite de solicitudes específico para `invite_member`. Aunque la acción exige un propietario autenticado, se recomienda añadir un límite atómico en servidor por propietario y destino, con protección adicional por negocio, antes de habilitar invitaciones a gran escala.
- **Registro, inicio de sesión y recuperación:** los formularios no incorporan límites propios en JavaScript. No se debe presentar un contador del navegador como protección real porque se puede omitir. La protección efectiva debe depender de los límites de Supabase Auth, CAPTCHA y configuración del servidor. Los valores actuales de Auth no pudieron leerse desde las herramientas disponibles y quedan pendientes de comprobación manual en Dashboard.

### RLS y permisos de los limitadores

- Las tablas `private.checkout_rate_limits`, `public.job_application_rate_limits` y `public.job_application_upload_sessions` tienen RLS habilitado y cero políticas.
- Los dos RPC de límite consultados no permiten ejecución a `anon` ni a `authenticated`; solo a `service_role`. Las tablas no deben recibir políticas genéricas para silenciar el asesor: son estructuras internas gestionadas por funciones de servidor.
- El asesor de seguridad sigue mostrando tres avisos INFO `rls_enabled_no_policy` para esas tablas y un WARN `auth_leaked_password_protection`. La protección de contraseñas filtradas continúa pendiente de activación en el Dashboard.

### Sesiones y suspensión de acceso

- En `panel-live.js`, la rama vuelve a validar la sesión y la autorización cada 30 segundos y cuando el usuario regresa a la pestaña. Si la cuenta queda bloqueada, la membresía deja de estar activa, el negocio se suspende o el propietario pierde AAL2, la interfaz cierra la sesión local y redirige al inicio de sesión.
- La revalidación del panel no equivale a revocar inmediatamente todos los refresh tokens. La autorización debe seguir comprobándose en cada Edge Function y en RLS. Un JWT ya emitido puede seguir siendo válido criptográficamente hasta su expiración.
- La suspensión de una membresía afecta ese negocio; no es un bloqueo global de la persona. Si el usuario conserva otra membresía activa, debe poder seguir entrando al otro negocio. El cierre local de la sesión del panel suspendido no debe revocar todas sus sesiones.
- `resolve-my-access` desplegada versión 2 rechaza perfiles con `is_blocked` y solo devuelve membresías activas de negocios activos.
- La tabla `auth.sessions` tenía 0 sesiones en la consulta del 16-Nov-2026 y el proyecto tenía 1 usuario Auth. No había sesiones de prueba para comprobar expiración, revocación o suspensión en vivo.

### Diferencia crítica entre rama y función técnica desplegada

- La función `technical-business-management` desplegada versión 6 valida el JWT, el perfil y el rol de propietario, pero no consulta el nivel de autenticación AAL. Por tanto, un JWT válido de nivel AAL1 no queda bloqueado en el servidor por esa función, aunque la interfaz de inicio de sesión muestre el paso MFA.
- La versión de `technical-business-management/index.ts` en `correcciones-funcionales` sí llama `getAuthenticatorAssuranceLevel(token)` y exige `aal2` antes de cualquier acción técnica. La referencia oficial de Supabase confirma que el método acepta un JWT explícito para uso en Edge Functions.
- **No desplegar la función técnica actual hasta revisar y probar esta diferencia.** La corrección está en la rama, no en el servicio activo. Se requiere prueba con un token AAL1 rechazado y otro AAL2 autorizado en un entorno de pruebas antes de desplegar.
- La función técnica desplegada tampoco ofrece un bloqueo global de perfil; las acciones `block_member` y `unblock_member` suspenden o reactivan una membresía concreta. El bloqueo global de perfil debe mantenerse como operación separada, con revocación de sesiones y comprobación del estado en servidor.

### Estado y límites de esta revisión

- Se inspeccionaron las versiones desplegadas de `technical-business-management`, `create-public-order`, `create-job-application` y `resolve-my-access`, además de sus versiones de rama pertinentes.
- Se consultaron definiciones SQL y permisos de los dos RPC de límite, estado RLS de las tablas y conteos agregados de usuarios/sesiones.
- No se hicieron intentos de inicio de sesión, no se enviaron invitaciones ni correos, no se crearon usuarios, no se cambiaron ajustes Auth, no se ejecutó SQL de escritura y no se desplegaron funciones.
- La expiración de JWT, rotación de refresh tokens, CAPTCHA, límites de Auth y política de contraseñas del servidor siguen pendientes de revisión manual en Dashboard.
- No se pudo probar el rechazo AAL1/AAL2 en vivo porque eso requeriría generar sesiones de prueba y llamar a la función administrativa. La discrepancia se confirmó mediante lectura del código desplegado y de la rama.


## Revisión complementaria: suspensión de membresías, roles y revocación de sesiones (16 Nov 2026)

### Suspensión y reactivación de miembros

- La acción `block_member` de la función técnica desplegada versión 6 actualiza una membresía a `suspended` y registra auditoría, pero no comprueba que el usuario suspendido sea el último administrador activo del negocio.
- La versión de la rama `correcciones-funcionales` sí protege ese caso: cuenta administradores activos y rechaza suspender al último. También usa una actualización condicional por estado anterior para reducir carreras concurrentes.
- La rama también hace que `update_member_assignment` impida retirar el rol de administrador al último administrador activo. La versión desplegada debe revisarse y actualizarse antes de considerarla equivalente.
- `unblock_member` comprueba que el negocio esté activo antes de reactivar la membresía. La versión de rama además usa una condición sobre el estado anterior para evitar sobrescribir un cambio concurrente.
- El panel técnico permite suspender o reactivar membresías de un negocio; no existe en esta función una acción separada para bloquear globalmente un perfil Auth.

### Auditoría y consistencia transaccional

- En la rama, las operaciones de suspensión, reactivación y cambio de rol actualizan primero la membresía y escriben el registro de auditoría después.
- Si la inserción de auditoría falla, la operación principal puede quedar aplicada sin registro; la función devuelve `audit_warning`. Es mejor que ocultar el fallo, pero no ofrece atomicidad.
- Antes de producción, estas operaciones deberían moverse a RPCs transaccionales que validen el último administrador, actualicen la membresía y escriban el evento de auditoría en una sola transacción. Si la auditoría falla, toda la operación debe revertirse.
- La acción de invitación de la rama evita crear la membresía cuando el envío de invitación falla y detecta membresías duplicadas. Sin embargo, no hay rate limit de servidor específico para invitaciones. El control no debe implementarse en el navegador ni basarse solo en IP; conviene combinar límites por actor, destino y negocio, con respuesta genérica y registro de intentos.

### Revocación de sesiones: alcance correcto

- Suspender una membresía no debería revocar globalmente las sesiones Auth del usuario: podría tener acceso válido a otros negocios. El mecanismo correcto es denegar de inmediato esa membresía en cada operación protegida y cerrar localmente el panel afectado.
- Bloquear globalmente un perfil es distinto: debe impedir nuevas autorizaciones para todos los negocios y revocar sus refresh tokens/sesiones. No se encontró una acción global implementada en la función técnica desplegada ni en la rama revisada.
- Supabase documenta que `signOut({ scope: 'global' })` termina todas las sesiones y destruye refresh tokens, pero los access tokens JWT ya emitidos pueden seguir siendo válidos hasta su `exp`. Para operaciones especialmente sensibles se puede comprobar el `session_id` del JWT contra `auth.sessions`; esta comprobación debe diseñarse con cuidado y no aplicarse indiscriminadamente a todas las consultas.
- La revalidación del panel cada 30 segundos mejora la experiencia, pero no es un control inmediato de revocación. Cada Edge Function y cada política RLS deben validar el perfil y la membresía activa en el servidor.

### Estado de la corrección

- La rama contiene protecciones para no suspender al último administrador y no retirar su rol, además de actualizaciones condicionales para evitar carreras.
- La función desplegada versión 6 todavía no tiene esas protecciones.
- No se modificó ni desplegó código en esta revisión. No se revocaron sesiones ni se alteraron membresías.
- Quedan pendientes: RPC transaccionales de suspensión/reactivación/roles con auditoría atómica; límite de invitaciones; política explícita de bloqueo global y revocación; limpieza programada de registros antiguos de limitación; pruebas controladas de tokens AAL1/AAL2 y de acceso después de suspensión.


## Continuación de auditoría: alta de clientes, recuperación y perfiles — 16 nov 2026

### Alta de clientes y consentimiento
- `cuenta.html` permite registro de clientes con nombre, correo y contraseña. El formulario no contiene una casilla de aceptación ni un enlace a un aviso de privacidad.
- No se encontró una página legal de privacidad/tratamiento de datos entre los archivos raíz de la rama. No se debe añadir una casilla que afirme que el usuario leyó un documento inexistente ni inventar datos del responsable del tratamiento.
- Antes de abrir el registro a clientes reales, preparar y publicar el aviso/política de privacidad con la información real del responsable, finalidades, derechos, canales de atención, terceros/proveedores y tiempos de conservación. Luego implementar consentimiento versionado y guardar evidencia del consentimiento desde servidor.
- El nombre enviado en `raw_user_meta_data.display_name` es editable por el usuario. El trigger lo copia solo como nombre visible a `profiles.display_name`; no usa esa metadata para asignar roles, membresías, bloqueo ni autorización. Es seguro mantenerlo como dato de presentación, no como permiso.

### Trigger de creación de perfil
Consulta read-only de `private.handle_new_auth_user()` confirmó que:
- inserta solo `id` y `display_name` en `public.profiles`;
- usa `raw_user_meta_data` exclusivamente para nombre visible;
- no asigna `platform_role`, membresías ni privilegios;
- es `SECURITY DEFINER` con `search_path` vacío;
- no tiene permiso EXECUTE para `anon`, `authenticated` ni `service_role` (se invoca únicamente como trigger).

No se identificó escalamiento de privilegios a través del campo de metadata usado en el registro de clientes.

### Recuperación de contraseña
- `recuperar-clave.js` usa `resetPasswordForEmail`, devuelve un mensaje genérico y dirige a `actualizar-clave.html`.
- `actualizar-clave.js` exige el evento Auth `PASSWORD_RECOVERY`; una sesión normal guardada no habilita el cambio. Tras el cambio intenta cerrar la sesión local.
- El formulario de actualización valida 10 caracteres en cliente. Esta validación no reemplaza la política mínima del servidor, que debe revisarse en Auth > Providers > Email.
- No se envió ningún correo ni se probaron enlaces reales. El destino relativo, Site URL, Redirect URLs, plantillas y SMTP siguen pendientes de comprobación en el Dashboard.

### Invitaciones internas
- `aceptar-invitacion.js` exige que el enlace tenga tipo `invite`, verifica `token_hash` cuando está presente, requiere sesión, limpia la URL y permite establecer la contraseña.
- Tras guardar la contraseña cierra la sesión local. El acceso a panel se decide después mediante `resolve-my-access`, no por metadata enviada desde el enlace.
- La invitación sigue dependiendo de la URL permitida y la entrega SMTP. No se enviaron invitaciones en esta auditoría.

### Perfil y ciclo de vida
- El esquema activo de `profiles` contiene nombre, teléfono, avatar, rol de plataforma y campos de bloqueo. No contiene campos de consentimiento ni preferencias de privacidad.
- El borrador de límites administrativos permite al usuario modificar únicamente nombre visible, avatar y teléfono; no rol ni bloqueo.
- No se encontró una función o pantalla pública de autoservicio para solicitar eliminación/corrección de cuenta. La eliminación directa de Auth por el cliente no debe habilitarse: debe diseñarse un proceso controlado que preserve pedidos y registros financieros exigibles, desvincule la cuenta con `ON DELETE SET NULL` cuando proceda, elimine favoritos y trate por separado los datos que deban conservarse.
- El proyecto tiene una cuenta Auth y un perfil en la consulta de esta auditoría. No se consultaron ni copiaron correos ni datos identificables de esa cuenta.

### Riesgo y acciones previas a producción
1. No abrir el registro público hasta que exista aviso de privacidad real, enlace visible y consentimiento registrado con versión y fecha de servidor.
2. Configurar y probar en Auth la confirmación de correo, URL base, redirect allowlist, plantillas y SMTP de producción.
3. Configurar la longitud mínima de contraseña en servidor (al menos 10 caracteres para alinear con los formularios) y revisar la opción de protección contra contraseñas filtradas según plan. El asesor del proyecto sigue mostrando esa protección deshabilitada; la documentación de Supabase indica que está disponible en Pro y superiores.
4. Implementar solicitud de corrección/eliminación y calendario de conservación antes de recopilar datos a escala.
5. Probar recuperación e invitaciones con cuentas de ensayo y enlaces válidos/vencidos antes del despliegue.

### Estado de esta continuación
Solo lectura del proyecto activo y revisión de archivos de la rama. No se alteró Auth, no se crearon ni eliminaron usuarios, no se enviaron correos, no se ejecutó SQL de escritura, no se desplegaron funciones y no se cambió GitHub Pages.


### Compatibilidad Supabase revisada el 16-Nov-2026
- Se revisó el índice oficial de cambios. No aparece un cambio incompatible nuevo de Supabase Auth que obligue a modificar los flujos actuales de email/contraseña, recuperación o MFA de este proyecto.
- El cambio relevante para la integración es que, desde el 30-Oct-2026, las tablas nuevas de `public` ya no quedan expuestas automáticamente a Data API. La migración de favoritos incluye GRANT explícitos y RLS, lo que debe verificarse en el proyecto una vez aplicada; RLS y exposición/grants son controles distintos.
- La breaking change de CLI v3 no afecta los archivos estáticos ni los flujos Auth auditados; sí debe tenerse presente si se actualiza el CLI, porque ahora apunta a entorno local por defecto y confirma cambios alojados.
- Referencias: Supabase Changelog (16-Nov-2026): https://supabase.com/changelog.md. Guía de seguridad de contraseñas: https://supabase.com/docs/guides/auth/password-security.


## Auditoría de postulaciones laborales y hojas de vida — 16 Nov 2026

### Flujo público y protección del archivo
- `app.js` genera el formulario de empleo desde una vacante publicada y aprobada. Recoge nombre, contacto, respuestas adicionales, mensaje, archivo opcional y una casilla de consentimiento.
- La casilla solo dice que autoriza el tratamiento para gestionar la postulación. No enlaza a una política o aviso específico; el consentimiento no queda asociado a versión ni fecha.
- `create-job-application` comprueba que el negocio esté activo y que la vacante pertenezca a ese negocio, sea `job_form`, esté publicada y aprobada.
- La carga se prepara con un UUID de postulación, ruta aleatoria, sesión de 30 minutos y URL firmada de carga sin upsert. La sesión se consume dentro de la transacción de inserción de la postulación.
- El bucket `job-applications-private` está configurado como privado, con límite de 5 MiB y MIME permitidos PDF/DOC/DOCX.
- La Edge Function comprueba extensión, MIME declarado y tamaño indicado por el navegador. Después comprueba que el objeto exista y que los metadatos de tamaño no superen 5 MiB. No inspecciona la firma binaria real del documento ni ejecuta análisis antimalware. El MIME/extension del navegador y los metadatos de Storage no demuestran que el contenido sea seguro.
- El administrador descarga el archivo mediante URL firmada con duración de 300 segundos. La URL es un token portador: puede seguir funcionando hasta expirar aunque se suspenda el negocio o se retire el permiso después de generarla.
- La política Storage actualmente desplegada solo comprueba el primer segmento de la ruta y el rol de administrador. No vincula el segundo segmento al UUID de la postulación ni verifica `job_applications.resume_path`. El borrador `database/security/storage-policy-fix.sql` sí añade esas comprobaciones. La política estricta sigue pendiente de aplicación.

### Permisos de lectura y revisión en panel
- En el proyecto activo, `job_applications` concede SELECT a `authenticated`, y la política SELECT limita la lectura al administrador del negocio. La política desplegada no exige que el negocio esté activo; el borrador de límites administrativos sí añade esa condición.
- Los permisos actuales no conceden UPDATE a `authenticated`, aunque existe una política RLS de UPDATE. Por tanto, la pantalla `loadJobApplications()` que intenta actualizar `status`, `admin_notes`, `reviewed_by` y `reviewed_at` directamente no tiene el privilegio SQL necesario. El botón Guardar puede fallar con permiso denegado.
- La rama ahora incorpora en `business-admin-boundaries.sql` una política UPDATE explícita para administradores de negocios activos, permisos UPDATE limitados a las cuatro columnas que usa la interfaz y un trigger que fija `reviewed_by = auth.uid()` y `reviewed_at = now()` desde la base de datos cuando hay usuario autenticado. No concede UPDATE sobre identidad, negocio, datos del postulante ni ruta de la hoja de vida.
- El estado permitido por la restricción activa es `pending`, `reviewing`, `contacted`, `accepted` y `rejected`. Las notas internas tienen límite de 3000 caracteres.
- La interfaz no registra una entrada independiente en `audit_logs` cuando cambia el estado o las notas. `reviewed_by` y `reviewed_at` dejan trazabilidad básica en la fila, pero no reemplazan un historial de cambios inmutable.

### Límites de solicitudes y limpieza
- La función SQL `consume_job_application_rate_limit` permite cinco solicitudes por hash de IP en 15 minutos. El mismo hash se consumía tanto en `request_upload` como en `submit`; una postulación con CV gastaba dos unidades, a diferencia de una postulación sin archivo.
- La rama cambia el hash para incluir la acción (`request_upload` o `submit`), separando ambos contadores y evitando penalizar doblemente una postulación normal. Cada acción conserva el límite de cinco solicitudes por IP en 15 minutos.
- La tabla `job_application_rate_limits` conserva una fila por hash y no se observó una tarea de limpieza; los contadores se reinician por ventana, pero las filas antiguas pueden acumularse.
- Las sesiones de carga vencidas o consumidas también permanecen en `job_application_upload_sessions`; no se encontró un proceso de limpieza programada en el código inspeccionado. Debe definirse limpieza de registros vencidos y objetos huérfanos, con retención y auditoría.
- En la consulta del proyecto activo, las tablas de postulaciones, sesiones de carga y limitadores estaban vacías (0 filas cada una); no había datos de postulantes que inspeccionar.

### Retención y eliminación
- La tabla `job_applications` tiene claves foráneas con `ON DELETE CASCADE` hacia el negocio y hacia la vacante (relación compuesta negocio/vacante). La política permite que el administrador elimine contenido del negocio.
- Eliminar una vacante con postulaciones puede borrar en cascada los registros de los candidatos. Storage no elimina automáticamente el archivo al borrar la fila SQL, por lo que puede dejar hojas de vida huérfanas en el bucket privado.
- No se encontró una política de retención por antigüedad ni un flujo de eliminación controlada de postulaciones/archivos. Antes de habilitar eliminación de vacantes con candidaturas, se debe cambiar a archivado/no publicado o impedir la eliminación física mientras existan postulaciones. La purga posterior debe coordinar objeto Storage, fila SQL y registro de auditoría.
- La retención de hojas de vida debe tener un plazo definido por el responsable del tratamiento y el propósito de selección. No se inventa un plazo en este informe.

### Correcciones preparadas en la rama
1. `supabase/functions/create-job-application/index.ts`: el contador de límites ahora distingue la acción de solicitud de carga de la acción de envío.
2. `database/security/business-admin-boundaries.sql`: se agrega UPDATE limitado y controlado para que el administrador pueda guardar estado/notas de candidaturas de su negocio activo, con actor y hora asignados por la base de datos.
3. Estas correcciones no están desplegadas ni aplicadas al proyecto activo. Requieren revisión y pruebas con cuentas de negocio aisladas en un entorno de pruebas.

### Bloqueos antes de producción
- Publicar el aviso de privacidad real y enlazarlo desde el formulario; registrar versión, fecha/hora del servidor y evidencia del consentimiento, sin confiar solo en el booleano del navegador.
- Añadir validación del contenido real y análisis antimalware de los CV antes de hacerlos descargables. Mientras no exista ese control, el formato y tamaño no deben confundirse con un análisis de seguridad.
- Corregir las políticas Storage para comprobar la ruta completa y la relación con la postulación.
- Aplicar los permisos UPDATE limitados y probar Guardar como administrador, además de confirmar que empleados y otros negocios no pueden leer ni modificar candidaturas.
- Definir archivado, retención y eliminación coordinada de registros y objetos.
- Añadir limpieza programada para sesiones vencidas, límites antiguos y objetos sin postulación.
- Evaluar CAPTCHA y protección contra abuso adicional antes de aumentar el tráfico público.

### Estado de seguridad y pruebas
- Consultas de solo lectura confirmaron que el bucket es privado; los RPC de envío y rate limit solo permiten EXECUTE a `service_role`; la tabla de postulaciones solo concede SELECT a `authenticated`; no hay privilegios de actualización autenticada en el estado activo.
- RLS de lectura de postulaciones y Storage limita el acceso al administrador, pero la política Storage desplegada necesita endurecimiento de ruta.
- No se descargaron hojas de vida, no se generaron postulaciones, no se enviaron correos, no se subieron ni borraron archivos, no se ejecutó SQL de escritura y no se desplegó Edge Function.



### Asesor de seguridad — consulta de cierre, 16-Nov-2026
El asesor volvió a mostrar:
- 3 avisos INFO `rls_enabled_no_policy`: `private.checkout_rate_limits`, `public.job_application_rate_limits` y `public.job_application_upload_sessions`.
- 1 aviso WARN `auth_leaked_password_protection`: protección contra contraseñas filtradas deshabilitada.

Las tres tablas de control son estructuras internas y las consultas previas confirmaron que los roles API no tienen permisos de acceso; los RPC de rate limit y envío de postulaciones solo permiten ejecución a `service_role`. No se deben crear políticas RLS genéricas para ocultar los avisos. La protección de contraseñas filtradas debe revisarse desde la configuración Auth/plan, no con una política SQL.
