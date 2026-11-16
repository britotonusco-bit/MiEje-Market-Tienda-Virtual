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
