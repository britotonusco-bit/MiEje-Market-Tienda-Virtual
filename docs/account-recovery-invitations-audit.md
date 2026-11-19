# Auditoría de recuperación de cuentas, invitaciones y auditoría de actividad

**Fecha:** 16 de noviembre de 2026  
**Proyecto Supabase:** MiEje Market Independiente (`cqixlrwbqatbhzmpygiz`)  
**Rama revisada:** `correcciones-funcionales`

## Alcance

Revisión de los flujos web de inicio de sesión, MFA del propietario, recuperación de contraseña y aceptación de invitaciones; del código servidor para asignar usuarios; y de la tabla de auditoría activa. Se separan hallazgos del proyecto activo de cambios realizados únicamente en la rama.

No se enviaron correos, no se modificaron usuarios de Auth, no se cambiaron ajustes de Auth, no se ejecutaron SQL y no se desplegó código.

## Resumen de hallazgos

| ID | Hallazgo | Severidad | Estado |
|---|---|---|---|
| ACC-01 | Usuario existente sin confirmar puede recibir membresía sin reenvío de confirmación | Alta | Pendiente |
| ACC-02 | La aceptación de invitación valida el tipo del enlace y actualiza la contraseña | Correcto con pruebas pendientes |
| ACC-03 | Recuperación de contraseña depende del evento `PASSWORD_RECOVERY` y tiene espera máxima de 10 segundos | Media | Diseño defensivo; requiere prueba real |
| ACC-04 | La URL de recuperación conservaba parámetros después de validar el enlace | Media | Corregido solo en la rama |
| ACC-05 | Los detalles del evento de acceso guardaban el correo además de `actor_id` | Baja / privacidad | Corregido solo en la rama |
| AUD-01 | `service_role` puede actualizar y borrar auditoría; no hay trigger de inmutabilidad | Alta | Pendiente de diseño |
| AUD-02 | No hay una tabla propia de ciclo de invitación/reenvío/revocación | Media-alta | Pendiente |
| CFG-01 | Comentario de `config.toml` describía el secreto antiguo de limpieza | Baja / documentación | Corregido solo en la rama |

## ACC-01 — Invitaciones pendientes y cuentas existentes

La rama actual distingue tres escenarios:

1. **Correo sin cuenta en Auth:** se envía una invitación con `inviteUserByEmail`. Después, la Edge Function intenta crear la membresía mediante `create_business_membership_assignment`, que registra la membresía y la auditoría en una transacción.
2. **Cuenta existente sin confirmar y con `invited_at`:** se considera una invitación pendiente. No se envía otro correo; se intenta finalizar la asignación mediante la RPC. La RPC es idempotente frente a una membresía ya existente: devuelve `already_assigned` y no duplica la fila.
3. **Cuenta existente sin confirmar y sin `invited_at`:** la Edge Function rechaza la asignación y no crea una membresía nueva.

La membresía de una invitación recién enviada se crea con estado `active` antes de que el destinatario complete la aceptación del correo. El acceso efectivo sigue dependiendo de que la persona pueda completar el flujo de Auth y luego iniciar sesión. Conviene evaluar en staging si el modelo debe distinguir explícitamente membresías invitadas pendientes de las activas; no cambiarlo sin revisar el comportamiento de todos los paneles y consultas de acceso.

**Limitación que permanece:** no existe un flujo de reenvío controlado ni una operación de revocación de invitación desde el panel. Una cuenta con invitación vencida puede quedar sin una ruta operativa para recibir un enlace nuevo.

**Corrección de documentación:** la descripción anterior que decía que cualquier cuenta existente no confirmada podía recibir una membresía sin reenvío era demasiado amplia. El comportamiento depende de `invited_at`, como se detalla arriba.

**Pruebas obligatorias en staging:** cuenta nueva; cuenta confirmada; cuenta existente no confirmada sin invitación; invitación pendiente con membresía ausente; invitación pendiente con membresía ya creada; fallo de RPC después del envío; enlace vencido; reenvío limitado; revocación; negocio suspendido. Usar únicamente cuentas y correos ficticios.

## ACC-02 — Aceptación de invitación

`aceptar-invitacion.js` exige que el enlace incluya el tipo `invite` en los parámetros de consulta o fragmento. Si recibe `token_hash`, verifica el OTP de tipo invitación. Luego exige una sesión y permite actualizar la contraseña con un mínimo de 10 caracteres. Después cierra la sesión local y redirige al login.

La página no confía únicamente en una sesión que ya estuviera guardada en el navegador: requiere que el enlace se identifique como invitación. Tras verificar, limpia la URL visible con `history.replaceState`.

**Pendiente:** probar enlace válido, vencido, reutilizado, alterado, cuenta equivocada, correo no confirmado, cambio de contraseña fallido y retorno a login. Confirmar en Auth que las URL de redirección permitidas incluyen únicamente la URL de ensayo mientras se prueban estos flujos.

## ACC-03 — Recuperación de contraseña

`recuperar-clave.js` usa `resetPasswordForEmail` y una respuesta genérica: “Si el correo corresponde a una cuenta registrada…”. Esto reduce la exposición de si un correo tiene cuenta. La página de cambio de contraseña escucha `PASSWORD_RECOVERY` antes de consultar la sesión y no acepta una sesión ordinaria como autorización para cambiar la clave.

El flujo espera hasta 10 segundos el evento. Si no llega, muestra que el enlace no se validó. Esto puede ocurrir por diferencias de red, intercambio PKCE, configuración de URL o correo; requiere prueba en el navegador y con los ajustes reales de Auth.

**Pendiente:** probar correo correcto, correo no registrado, enlace vencido, enlace reutilizado, navegador con sesión previa, PKCE, fragmento de URL, redirección y límites de envío de correo. No desactivar la validación específica de `PASSWORD_RECOVERY` para “arreglar” fallos de enlace.

## ACC-04 — Limpieza de URL de recuperación

La versión de rama de `actualizar-clave.js` ahora limpia consulta y fragmento de la URL solo después de recibir y validar el evento `PASSWORD_RECOVERY`. Así no se elimina el código antes de que Supabase lo intercambie, pero tampoco queda en la barra de direcciones después de validar.

Cambio solo en `correcciones-funcionales`; no está publicado.

## ACC-05 — Minimización de datos en auditoría

El evento `panel.login` ya identifica al usuario mediante `actor_id`. La rama elimina el correo electrónico del JSON `details`, que era redundante y aumentaba la cantidad de datos personales guardados.

Cambio solo en `correcciones-funcionales`; no está desplegado.

## AUD-01 — Auditoría no inmutable ante credenciales privilegiadas

En la base activa, `audit_logs` no concede INSERT, UPDATE ni DELETE a `anon` o `authenticated`. La única política SELECT permite lectura al propietario técnico, al administrador del negocio correspondiente o al propio actor.

Sin embargo, la comprobación de privilegios confirmó que `service_role` tiene INSERT, UPDATE y DELETE. La tabla tampoco tiene triggers no internos que bloqueen UPDATE o DELETE. Por tanto, la auditoría está protegida frente a escrituras directas desde los roles normales de la API, pero no es inmutable frente a código backend que use credenciales privilegiadas.

**Corrección necesaria:** decidir y documentar el modelo de retención. Como mínimo, evitar que las funciones de negocio expongan acciones de edición/borrado de auditoría; considerar un trigger de solo inserción que rechace UPDATE/DELETE incluso desde funciones privilegiadas; definir un proceso excepcional de retención/archivo con autorización, doble control y registro externo. No aplicar un trigger a ciegas: verificar primero las tareas de mantenimiento y los requisitos legales de conservación.

**Pruebas:** intentar UPDATE y DELETE con roles anon/authenticated (deben fallar); comprobar que el servicio puede insertar eventos; comprobar que ninguna función de aplicación borra o edita eventos; y validar el mecanismo excepcional de archivo si se implementa.

## AUD-02 — Ciclo de vida de invitaciones incompleto

El flujo de Auth y la membresía no tienen un registro propio que permita administrar explícitamente estados como pendiente, enviado, confirmado, vencido, revocado o fallido. Auth contiene su propio estado de usuario, pero el panel no dispone de una vista completa de los intentos de invitación y su reconciliación.

La rama ya mejora el registro transaccional de la membresía y devuelve si el correo fue enviado; no resuelve por sí sola el reenvío ni la revocación de un enlace pendiente.

**Diseño recomendado:** registro de invitación con identificador, negocio, correo normalizado, rol, cargo, actor que invita, estado, fecha de creación, expiración, fecha de envío, contador/último reenvío, fecha de aceptación y motivo de revocación. No guardar tokens de invitación ni enlaces completos. Asegurar unicidad de una invitación pendiente por correo/negocio y registrar cada transición en auditoría.

Revocar una invitación debe impedir completar la asignación, incluso si el enlace de Auth sigue vigente. La aceptación debe comprobar el registro pendiente, negocio activo, cuenta destinataria y rol previsto. Si no puede verificarse de forma atómica, mantener la membresía inactiva hasta completar la confirmación.

## CFG-01 — Comentario de secreto de limpieza

Se corrigió el comentario de `supabase/config.toml`: la función `cleanup-job-application-data` requiere el secreto independiente `JOB_APPLICATION_CLEANUP_SECRET`, no reutilizar `SUPABASE_SERVICE_ROLE_KEY` como secreto HTTP. Es una corrección documental en la rama; no cambia configuración activa.

## Pruebas de salida

1. Cuenta nueva invitada: correo de invitación, verificación, contraseña, membresía correcta y acceso al panel correspondiente.
2. Cuenta existente confirmada: asignación sin correo duplicado.
3. Cuenta existente no confirmada: reenvío seguro y controlado; no dejar acceso operativo sin confirmación.
4. Invitación vencida o revocada: no debe crear sesión con acceso funcional ni activar membresía.
5. Usuario con membresía suspendida o negocio suspendido: login no debe permitir entrar al panel.
6. Recuperación: solo evento de recuperación válido permite cambiar contraseña; enlace vencido/reutilizado rechazado.
7. MFA: propietario AAL1 rechazado por la función técnica y propietario AAL2 aceptado.
8. Auditoría: mínimo privilegio de lectura, sin PII redundante, sin edición/borrado desde aplicación y trazabilidad de operaciones.
9. Reintentos: fallos de correo, Auth, RPC y base no deben duplicar membresías ni dejar estados imposibles.
10. Todos los ensayos con correos y usuarios ficticios, nunca con cuentas reales.

## Cambios en rama realizados durante esta revisión

- `actualizar-clave.js`: elimina consulta y fragmento de la URL después de validar `PASSWORD_RECOVERY`.
- `supabase/functions/technical-business-management/index.ts`: deja de duplicar el correo en los detalles de `panel.login`.
- `supabase/config.toml`: corrige el comentario para usar `JOB_APPLICATION_CLEANUP_SECRET` independiente.

Los cambios no están desplegados ni publicados. No se modificó Auth ni la base de datos.

## Conclusión

El inicio de sesión, MFA, aceptación de invitaciones y recuperación tienen controles útiles en la rama, pero aún no puede considerarse completo el ciclo de invitaciones. El punto más importante pendiente es el usuario ya existente sin correo confirmado y la capacidad de reenvío/revocación. La auditoría tampoco es inmutable frente a `service_role`; debe definirse una protección de solo inserción antes de declarar cerrada esa parte.


## ACC-06 — Cuenta existente sin correo confirmado y asignación prematura — 19 nov 2026

Se corrigió el flujo de `technical-business-management` en la rama:

- Si la búsqueda encuentra una cuenta de Auth preexistente y `email_confirmed_at` es nulo, la función responde HTTP 409.
- No llama a `create_business_membership_assignment` para esa cuenta.
- Devuelve `assignment_created: false` y `requires_email_confirmation: true`.
- No intenta enviar automáticamente un enlace de confirmación. El reenvío debe ser un proceso separado, con límites y validación de destinatario.

La distinción es importante: las cuentas nuevas creadas mediante `inviteUserByEmail` siguen el flujo de invitación normal, aunque inicialmente no tengan correo confirmado; el bloqueo se aplica a cuentas que ya existían antes de esta operación.

También se reforzó `aceptar-invitacion.js`: después de verificar el enlace y recuperar la sesión, exige que Auth indique `email_confirmed_at`. Si no aparece confirmado, cierra la sesión local y no permite establecer la contraseña desde esa pantalla.

**Límites pendientes:**
- No existe todavía una tabla propia de invitaciones con estados pending/sent/accepted/expired/revoked.
- No existe un mecanismo de reenvío limitado ni de revocación coordinada con Auth.
- El envío de invitación ocurre antes de la RPC que crea la membresía. Si Auth envía el correo y la RPC falla, el correo puede llegar sin que la asignación se haya completado. La función devuelve `invitation_sent: true` y `retryable: true`, pero no hay reconciliación automática.
- No se ha probado la entrega de correos ni los límites reales de SMTP/Auth.
- La lista de usuarios se busca por páginas de hasta 1000 y falla de forma cerrada al alcanzar 20 páginas sin completar la búsqueda; no se debe interpretar una búsqueda incompleta como correo inexistente.

**Pruebas de staging añadidas:**
1. Usuario nuevo: Auth crea invitación, RPC asigna una única membresía y el enlace permite verificar el correo.
2. Usuario existente confirmado: asignación permitida sin enviar invitación duplicada.
3. Usuario existente sin confirmar: HTTP 409 y cero nuevas membresías.
4. Correo duplicado/membresía ya existente: no crear otra membresía ni enviar un segundo correo.
5. Negocio suspendido: rechazar antes de invitar.
6. Fallo de Auth: no crear membresía.
7. Fallo de RPC después del envío: conservar el resultado de envío y completar mediante un reintento controlado, sin volver a invitar.
8. Enlace vencido/reutilizado o correo no confirmado: no activar la cuenta desde la página de aceptación.

Estos cambios están únicamente en `correcciones-funcionales`; no se modificó Auth, no se enviaron correos y no se alteraron usuarios reales.


## Recuperación de una invitación creada sin asignación — 19 nov 2026

Se corrigió un caso parcial del flujo de invitaciones. Auth puede crear una cuenta y registrar `invited_at`, pero la RPC de membresía puede fallar después. Al repetir la operación, el sistema antes bloqueaba toda cuenta existente sin correo confirmado, dejando la invitación pendiente sin una vía de reconciliación desde el panel.

Ahora:

- La Edge Function identifica una cuenta no confirmada con `invited_at` como una invitación ya creada.
- Para esa cuenta no vuelve a llamar `inviteUserByEmail`, no crea otra cuenta y no afirma que haya enviado otro correo.
- Permite reintentar únicamente la RPC transaccional `create_business_membership_assignment`, que comprueba duplicados y registra la membresía y su auditoría.
- Si la cuenta no está confirmada y no tiene `invited_at`, el sistema mantiene el bloqueo y no asigna acceso.
- Si la membresía ya existe, el panel informa que la persona todavía debe aceptar la invitación y confirmar su correo.
- Se corrigió el mensaje del error de envío: ya no promete reenviar la confirmación mediante un reintento.

### Límites que siguen pendientes

Este ajuste reconcilia la membresía cuando la invitación original sí fue creada. No reenvía correos ni renueva enlaces vencidos. Para eso se necesita definir y probar un canal de correo transaccional y un flujo explícito con límites de frecuencia y auditoría. Supabase documenta que `inviteUserByEmail` crea un usuario no confirmado cuando el correo no existe; `generateLink` genera el enlace pero no lo envía por sí mismo, y `resend` está documentado para confirmaciones de signup, no como reenvío administrativo genérico de invitaciones. No se debe tratar esos métodos como intercambiables.

No se desplegó la Edge Function ni se modificó Auth o la base activa. La comprobación realizada es estática; quedan pendientes Deno check, prueba de invitación real, fallo simulado de RPC, reintento y aceptación del correo en staging.


## Revisión del selector de usuarios y estados de acceso — 19 nov 2026

Se revisó la gestión de membresías y la diferencia entre un bloqueo local y uno global.

- La Edge Function ahora incluye `profiles.is_blocked` al listar miembros para el panel técnico.
- El selector distingue membresías activas y suspendidas, y señala las cuentas bloqueadas globalmente.
- Al cambiar de negocio, se limpia la selección anterior para evitar operar sobre una cuenta del negocio previo.
- El formulario propone suspender si la membresía está activa y reactivar si está suspendida.
- Si la cuenta está bloqueada globalmente, el panel explica que reactivar la membresía no elimina el bloqueo global.
- Se añadieron identificadores de solicitud para que una respuesta lenta de un negocio anterior no reemplace los resultados del negocio seleccionado después.
- Se corrigió el estado deshabilitado del selector cuando se limpia la selección de negocio.

### Unicidad de membresías

Una consulta SQL estrictamente de solo lectura a Supabase activo confirmó la restricción validada `UNIQUE (business_id, user_id)`. Esto impide que una misma cuenta tenga dos membresías para el mismo negocio. El borrador de verificación ahora exige que esa restricción exista y esté validada, y comprueba la columna `profiles.is_blocked`.

No se modificó la base activa. No se desplegó la Edge Function. Se realizaron 12 comprobaciones estáticas; siguen pendientes las pruebas de navegador, Deno check y pruebas concurrentes en staging.


## Revisión de consistencia Auth, perfil y membresía — 19 nov 2026

Se contrastaron la Edge Function técnica, `resolve-my-access`, la página de aceptación de invitación, el inicio de sesión y la RPC de asignación.

- `resolve-my-access` valida el token con Auth, rechaza perfiles inexistentes o bloqueados y solo devuelve membresías activas asociadas a negocios activos.
- Suspender una membresía no equivale a bloquear el perfil completo. El filtro por usuario y la evaluación individual de cada membresía permiten conservar las demás asignaciones activas.
- La aceptación exige que el enlace sea de tipo `invite`, verifica el correo, actualiza la contraseña y cierra la sesión local al terminar.
- La RPC de asignación bloquea el negocio y el perfil, rechaza perfiles globalmente bloqueados y evita duplicar la membresía. La creación de la membresía y su registro de auditoría son atómicos.
- El envío de correo de Auth y la escritura SQL no pueden ser una sola transacción. Si el correo se envía y la RPC falla, queda una cuenta invitada sin asignación finalizada; el flujo puede intentar completar la asignación después, pero no reenvía el correo.
- La membresía se crea activa antes de la aceptación del enlace. Esto no equivale a una sesión autenticada, pero es una decisión de ciclo de vida que debe validarse con cuentas ficticias en staging.

No se realizaron cambios en Auth, SQL activo, membresías ni funciones desplegadas. Esta revisión es estática; no prueba entrega de correo, expiración real de enlaces ni comportamiento del proveedor SMTP.
