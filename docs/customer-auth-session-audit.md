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
