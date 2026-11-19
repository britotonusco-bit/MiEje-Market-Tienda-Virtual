# Auditoría de sesiones, MFA y revocación de acceso

**Fecha:** 19 de noviembre de 2026  
**Proyecto Supabase:** MiEje Market Independiente (`cqixlrwbqatbhzmpygiz`)  
**Rama revisada:** `correcciones-funcionales`

## Alcance y límites

Se revisaron `login.js`, `panel-live.js`, `resolve-my-access`, `technical-business-management`, `supabase/config.toml`, políticas RLS activas y código de Edge Functions desplegado. Las consultas SQL fueron exclusivamente de lectura. No se leyeron credenciales, tokens ni registros de usuarios individuales; no se modificaron Auth, sesiones, factores MFA, base de datos ni despliegues.

La configuración de expiración de JWT, duración máxima de sesión, inactividad y sesión única se administra en Auth settings. La integración disponible no expone esos ajustes del Dashboard, por lo que no se afirma que estén activados o desactivados.

## Hallazgos

| ID | Hallazgo | Severidad | Estado |
|---|---|---|---|
| SES-01 | El panel revalida usuario, perfil, negocio y membresía cada 30 segundos y al volver a primer plano | Correcto en rama |
| SES-02 | El panel no reacciona inmediatamente a todos los eventos de Auth; depende del intervalo o de volver a la pestaña | Media | Mejora recomendada |
| MFA-01 | La rama exige AAL2 en UI y en la Edge Function técnica | Correcto en rama |
| MFA-02 | La función técnica desplegada en Supabase versión 6 no contiene comprobación AAL2 del lado servidor | Crítica | Pendiente de despliegue autorizado |
| SES-03 | La configuración real de expiración, inactividad y sesión única no pudo verificarse desde las herramientas disponibles | Media | Verificación manual pendiente |
| RLS-01 | Las políticas activas todavía incluyen bypass de propietario técnico en perfiles, membresías y directorio de negocios | Alta | Divergencia activa ya identificada en auditorías anteriores |

## SES-01 — Revalidación de acceso en el panel

En la rama, `panel-live.js`:
- Comprueba la sesión mediante `auth.getUser()`.
- Consulta `resolve-my-access` al iniciar.
- Revalida cada 30 segundos.
- Revalida al volver la pestaña a estado visible.
- Comprueba que el perfil siga habilitado.
- Para panel técnico, comprueba rol `platform_owner` y AAL2.
- Para panel de negocio o empleado, comprueba que siga existiendo una membresía activa con el rol y negocio solicitados.
- Si no puede verificar el acceso, cierra la sesión local y redirige al login.

La Edge Function `resolve-my-access` consulta el perfil y las membresías actuales en servidor y filtra membresías inactivas y negocios que no estén activos. Por eso una suspensión se detecta en la siguiente revalidación; no es una revocación instantánea del contenido que ya está renderizado.

## MFA-01 / MFA-02 — Propietario técnico

En la rama:
- `login.js` inicia sesión con contraseña y exige TOTP para propietario técnico.
- Comprueba el nivel resultante `aal2`.
- `panel-live.js` vuelve a comprobar AAL2 al abrir el panel y en cada revalidación.
- `technical-business-management` valida JWT, perfil no bloqueado y `getAuthenticatorAssuranceLevel(token)`; rechaza cualquier propietario que no tenga `aal2`.

En el proyecto Supabase activo, la Edge Function `technical-business-management` está en versión 6. Su código desplegado no contiene `getAuthenticatorAssuranceLevel` ni una comprobación `aal2`. Por tanto, la protección del navegador no equivale a una exigencia del servidor: una llamada directa autenticada a esa función podría omitir el paso MFA que sí exige la rama.

**Acción requerida:** desplegar la versión de rama que contiene la comprobación AAL2, pero únicamente después de las pruebas de staging y con autorización expresa. No se desplegó durante esta auditoría.

## SES-02 — Eventos de sesión

Actualmente, si Supabase cierra la sesión o la renovación falla entre dos comprobaciones, el panel puede permanecer visible hasta el siguiente intervalo o hasta que el usuario vuelva a la pestaña. Las operaciones del servidor siguen sujetas a validación de JWT, permisos y RLS, pero la interfaz puede tardar hasta aproximadamente 30 segundos en retirarse.

Se recomienda añadir escucha a `SIGNED_OUT`, `TOKEN_REFRESHED` y `USER_UPDATED`, difiriendo cualquier consulta de Auth fuera del callback. El intento de modificación automática de `panel-live.js` no se guardó porque GitHub devolvió un conflicto de actualización; por tanto, el código actual conserva el intervalo y el evento de visibilidad sin esa mejora adicional.

## SES-03 — Ajustes de Auth que deben comprobarse en Dashboard

No se pudieron leer los valores reales de Auth settings. Revisar manualmente en Supabase Dashboard, Authentication → Settings → Sessions:
1. **Time-box user sessions:** establecer una duración positiva adecuada para cuentas administrativas.
2. **Inactivity timeout:** establecer un periodo positivo para sesiones inactivas.
3. **Single session per user:** valorar activarlo para la cuenta propietaria técnica; considerar el impacto operativo en administradores y empleados que usan varios dispositivos.
4. **JWT expiry:** mantener un valor corto razonable; la documentación de Supabase recomienda generalmente el valor predeterminado de una hora y desaconseja superar una hora.

Los límites de sesión no se aplican necesariamente de forma retroactiva inmediata; Supabase los verifica durante la renovación del token. Consultar la guía oficial: https://supabase.com/docs/guides/auth/sessions

## RLS-01 — Divergencias confirmadas en base activa

La consulta de solo lectura mostró que las políticas activas aún contienen:
- `profiles_select_self_or_owner`, con lectura de perfiles por propietario técnico.
- `memberships_select_self_admin_owner`, con lectura global de membresías por propietario técnico.
- `businesses_admin_update` y `businesses_public_directory_authenticated` con bypass `is_platform_owner()`.

La rama contiene políticas más restrictivas en `database/security/business-admin-boundaries.sql` y comprobaciones en `database/integration/verify-integration-package.sql`. No se aplicaron esas correcciones a la base activa.

## Pruebas pendientes en staging

1. Propietario con contraseña solamente: panel técnico y todas las acciones servidoras deben rechazar AAL1.
2. Propietario con TOTP válido: acceso AAL2 permitido.
3. Propietario que pierde AAL2: próxima revalidación debe cerrar acceso.
4. Usuario bloqueado mientras mantiene el panel abierto: debe salir al siguiente chequeo.
5. Membresía suspendida o negocio suspendido mientras el panel está abierto: debe salir al siguiente chequeo.
6. Sesión cerrada en otra pestaña: el panel debe redirigir al login.
7. Token expirado con renovación correcta: la sesión continúa y permisos se revalidan.
8. Token expirado con renovación fallida: acceso se cierra.
9. Dos dispositivos: comprobar el comportamiento según el ajuste de sesión única.
10. Inactividad y duración máxima: confirmar expiración real según los valores elegidos en Auth settings.

## Conclusión

La rama tiene controles de revalidación y MFA adecuados para el panel técnico. Sin embargo, no se puede considerar cerrada la seguridad MFA mientras la función desplegada siga en versión 6 sin comprobación AAL2. Tampoco se puede afirmar que haya expiración por inactividad o sesión única sin revisar los valores reales del Dashboard.

No se modificó el proyecto Supabase activo ni se desplegó código.
