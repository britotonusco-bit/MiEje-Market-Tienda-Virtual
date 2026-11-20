# Auditoría de autenticación, MFA y sesiones

**Fecha:** 20 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Estado:** revisión estática del código; pendiente de pruebas en staging.

## Resultado de la revisión

### Inicio de sesión

- El cliente utiliza `signInWithPassword` y después consulta `resolve-my-access`; no decide los permisos usando datos enviados por el navegador.
- `resolve-my-access` valida el JWT mediante `auth.getUser(token)`, consulta el perfil en servidor y rechaza perfiles bloqueados.
- Solo devuelve membresías activas asociadas a negocios activos. Las membresías pendientes o suspendidas no aparecen como rutas autorizadas.
- Se normalizó el mensaje de error de credenciales para no mostrar directamente los mensajes del proveedor Auth en el formulario de inicio de sesión.
- Las cuentas sin una membresía activa no llegan a un panel de negocio.

### MFA del propietario técnico

- El inicio de sesión del propietario exige un factor TOTP verificado antes de navegar al panel técnico.
- El cliente comprueba `currentLevel === 'aal2'` después de verificar el código.
- El panel técnico vuelve a comprobar AAL2 antes de cargar sus datos.
- `technical-business-management` vuelve a validar el nivel AAL2 en servidor para las acciones técnicas. La interfaz no es la única barrera.
- El alta inicial del factor muestra QR y secreto manual; staging debe comprobar el enrolamiento, el primer challenge, la verificación y los siguientes inicios de sesión.
- La rama no incorpora todavía un flujo de recuperación de MFA para pérdida del dispositivo. Debe existir un procedimiento administrativo seguro y probado antes de depender del MFA como único segundo factor.

### Sesiones, renovación y cierre

- Supabase Auth administra la renovación del token; `panel-live.js` escucha `TOKEN_REFRESHED` y `USER_UPDATED`.
- El panel revalida la sesión y los permisos cada 30 segundos y al volver a una pestaña visible.
- Si falla la validación, se cierra la sesión local del navegador y se redirige al login.
- El cierre manual del panel ahora declara explícitamente `signOut({ scope: 'global' })`; si falla, intenta cerrar al menos la sesión local.
- La recuperación de contraseña también solicita cierre global después de cambiarla y tiene fallback local.

### Suspensión y revocación de permisos

- El perfil bloqueado se rechaza en `resolve-my-access` y en `technical-business-management`.
- La suspensión o revocación de membresía, o la suspensión del negocio, elimina esa ruta de `resolve-my-access`; el panel detecta el cambio en la siguiente revalidación.
- La autorización debe seguir verificándose en cada RPC, Edge Function y política RLS. La revalidación del navegador es una defensa adicional, no un control de acceso suficiente.
- La recuperación de contraseña no modifica `profiles.is_blocked`, membresías ni estado del negocio; por tanto, no debe restituir permisos.

## Bloqueador de seguridad conocido en la base activa

En la auditoría previa de la base Supabase activa se detectaron políticas RLS que incluían un bypass para `platform_owner` en varias tablas sensibles y permisos directos sobre columnas personales/financieras. Los borradores de la rama intentan retirar esos accesos amplios, pero no se han aplicado.

Esto significa que el MFA de la interfaz y de la Edge Function técnica no basta por sí solo para proteger las consultas directas al Data API si la base activa conserva esas políticas. Un usuario autenticado como propietario podría intentar consultar directamente tablas desde un cliente propio, sin pasar por el formulario del panel.

**Bloqueador:** no considerar protegidos los datos sensibles por el solo hecho de exigir AAL2 en la pantalla técnica. Antes de cerrar la auditoría, hay que aplicar el conjunto revisado de políticas/grants en un proyecto de staging, probar accesos directos con AAL1/AAL2 y cada rol, y solo después planificar cualquier cambio en producción con autorización expresa. Esta revisión no ejecutó SQL ni modificó la base activa.

## Riesgo residual que requiere decisión técnica

El cierre global de Auth revoca los refresh tokens, pero los access tokens JWT ya emitidos pueden seguir siendo aceptados hasta su expiración. La comprobación de `getUser(token)` valida el token, pero por sí sola no garantiza revocación instantánea de un JWT que todavía no ha vencido.

Para operaciones que necesiten revocación inmediata de una sesión concreta, hace falta evaluar una comprobación server-side del claim `session_id` contra el estado de sesiones de Auth, o un mecanismo equivalente de revocación consultado por cada operación sensible. No se añade esa dependencia a ciegas: requiere validar permisos de lectura de `auth.sessions`, comportamiento de Auth hospedado, coste y compatibilidad con RLS/RPC antes de diseñar el cambio.

La ventana de revalidación de 30 segundos solo afecta a la interfaz del panel. No se debe prometer que cierra de inmediato otras pestañas o que invalida JWT ya emitidos.

## Cambios de esta revisión

- `login.js`: errores de credenciales normalizados para evitar revelar detalles internos de Auth.
- `panel-live.js`: alcance global explícito en el cierre manual, con fallback local.
- No se modificó la rama `main`.
- No se ejecutó SQL, no se desplegaron Edge Functions, no se cambiaron ajustes de Auth hospedado y no se enviaron correos.

## Matriz de pruebas obligatorias en staging

| Área | Caso | Resultado esperado |
|---|---|---|
| Login | Contraseña incorrecta y correo no registrado | Mensaje visible equivalente; sin revelar existencia de cuenta |
| Login | Cuenta sin confirmar o bloqueada | No entra a ningún panel |
| Login | Usuario sin membresía activa | No obtiene ruta de panel |
| MFA | Propietario sin factor TOTP | Puede completar enrolamiento y verificación inicial |
| MFA | Código incorrecto o challenge vencido | No obtiene AAL2 ni abre el panel |
| MFA | Propietario con factor verificado | AAL2 antes de mostrar datos técnicos |
| MFA | Llamada directa a Edge técnica con AAL1 | Respuesta denegada |
| Sesión | Renovación normal del token | Continúa con permisos vigentes |
| Sesión | Refresh token revocado | La sesión deja de renovarse y el panel redirige al login |
| Sesión | Cierre global desde un navegador | Otros dispositivos pierden capacidad de renovar; medir hasta cuándo sigue aceptándose el JWT vigente |
| Sesión | Falla el cierre global | Se intenta cierre local y se muestra el estado sin afirmar revocación total |
| Suspensión | Bloqueo global con panel abierto | Las operaciones servidoras se deniegan; la interfaz se cierra al revalidar |
| Membresía | Suspender o revocar una membresía | El usuario pierde acceso solo a ese negocio |
| Negocio | Suspender el negocio | Admin y empleados pierden acceso al panel de ese negocio |
| Recuperación | Enlace vencido, alterado o reutilizado | No permite cambiar contraseña |
| Recuperación | Contraseña cambiada | Se solicita cierre global y no se eliminan bloqueos ni membresías suspendidas |
| Concurrencia | Revocar mientras el usuario realiza una operación | La operación sensible vuelve a validar autorización y no depende de la UI |

## Condiciones para cerrar esta etapa

1. Ejecutar todos los casos en un proyecto Supabase de staging aislado.
2. Confirmar el comportamiento real de cierre global y vigencia de JWT con dos navegadores/dispositivos.
3. Probar RLS y RPC con usuarios de cada rol, no solo con el propietario.
4. Verificar el flujo de recuperación del segundo factor TOTP.
5. Resolver el riesgo residual de revocación de sesión inmediata para operaciones que lo requieran.
6. Registrar evidencias y resultados antes de considerar terminada la auditoría.

**No considerar esta auditoría como certificación de seguridad ni como prueba funcional completa hasta superar la matriz de staging.**
