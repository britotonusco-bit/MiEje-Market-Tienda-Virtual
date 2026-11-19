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


## Registro explícito de reconciliación de invitaciones — 19 nov 2026

Se añadió un indicador separado para identificar cuando una asignación se completa usando una invitación pendiente que Auth ya había creado. La RPC `create_business_membership_assignment` ahora recibe `p_existing_invitation`, rechaza que se marque simultáneamente como invitación nueva y existente, y registra `business.member_invitation_reconciled` cuando corresponde. Las invitaciones nuevas conservan `business.member_invited`; las asignaciones normales conservan `business.member_assigned`.

La Edge Function envía ese indicador únicamente cuando encuentra la cuenta existente con correo sin confirmar y `invited_at`. No vuelve a llamar `inviteUserByEmail` para ese caso. La auditoría incluye `existing_invitation_reconciled` y mantiene `invitation_sent` como indicador de correo enviado en la operación actual. El verificador exige la nueva firma y el evento específico.

La firma SQL y sus permisos deben aplicarse como parte de la migración coordinada: no se ejecutó SQL ni se desplegó la Edge Function. La modificación permanece en `correcciones-funcionales`; falta probar el flujo con cuentas ficticias en staging, incluido el fallo posterior al envío y el reintento.


### Compatibilidad de la firma RPC

Al ampliar la firma PostgreSQL, `CREATE OR REPLACE FUNCTION` no sustituye automáticamente una función con distinto número de parámetros: puede dejar la sobrecarga anterior disponible. Por eso el borrador ahora elimina explícitamente la firma antigua de siete argumentos antes de crear la nueva de ocho, y el verificador exige que la antigua ya no exista. Antes de aplicar esta migración en staging debe comprobarse que no haya dependencias SQL que impidan ese `DROP`; no debe ejecutarse parcialmente ni en producción sin respaldo y revisión del plan de migración.


## Auditoría de revocación de invitaciones y conservación de otras membresías — 19 nov 2026

### Hallazgo en la rama

No existe una acción `revoke_invitation`/`cancel_invitation` en `technical-business-management`, no existe una RPC de revocación en `administrative-membership-rpcs-draft.sql` y tampoco hay control para esa operación en `panel-tecnico.html` o `panel-live.js`. Por tanto, actualmente el panel no permite revocar una asignación invitada pendiente.

### Hallazgo en Supabase activo (consulta de solo lectura)

En el proyecto activo `cqixlrwbqatbhzmpygiz`:

- `business_memberships` contiene `id`, `business_id`, `user_id`, `role`, `status`, `blocked_reason`, `created_by`, `created_at` y `updated_at`; no tiene un estado de invitación separado ni `invitation_id`.
- No se encontraron funciones públicas con nombres relacionados con invitaciones o `membership_assignment`.
- El único trigger no interno de `business_memberships` observado fue `memberships_set_updated_at`; no está instalado el trigger de protección del último administrador preparado en la rama.
- La policy activa de lectura permite consultar membresías propias, del propietario técnico y del administrador del negocio. Esto no implementa revocación.

No se realizaron escrituras ni se modificó la base activa.

### Semántica segura que debe implementarse

La operación que falta debe denominarse **revocar asignación pendiente al negocio**, no eliminar la cuenta ni prometer que invalida por sí sola el enlace de correo de Supabase Auth.

1. Solo puede dirigirse a una membresía que corresponda a una invitación todavía no aceptada, verificada en servidor mediante Auth (`email_confirmed_at` ausente y `invited_at` presente). La interfaz no puede declarar por sí sola que una cuenta está pendiente.
2. La mutación debe afectar únicamente la membresía del `business_id` indicado. No debe borrar `auth.users`, borrar el perfil, suspender globalmente la cuenta ni revocar todas las sesiones, porque el mismo usuario podría tener otras membresías o utilizar su cuenta como cliente.
3. Debe bloquear la fila de negocio y la membresía, volver a validar el estado pendiente dentro de la operación y registrar actor, negocio, usuario objetivo, membresía, motivo y resultado en `audit_logs` dentro de la misma transacción.
4. Si la persona ya confirmó su correo, la operación de revocación de invitación pendiente debe rechazarse. La baja de una persona que ya aceptó requiere el flujo normal de suspensión/eliminación de membresía y sus protecciones, incluida la regla del último administrador.
5. Una vez retirada la membresía, aunque la persona complete el enlace de Auth que ya recibió, no debe obtener acceso a ese negocio. La cuenta y sus otras membresías permanecen intactas.
6. La revocación de la asignación no garantiza invalidar un enlace de invitación que ya fue enviado. La invalidación del enlace es un proceso separado de Auth y debe comprobarse con la documentación y pruebas de Supabase antes de ofrecerla como resultado.
7. Debe ser idempotente: un segundo intento no crea otro evento de revocación ni altera otras membresías. Debe devolver un resultado claro si ya no existe la asignación pendiente.

### Decisión de seguridad

No se implementó todavía una acción de revocación. El esquema actual crea la membresía con `status='active'` antes de la aceptación del correo y no conserva un estado inequívoco `invited/pending`. Añadir una operación segura exige primero introducir una señal persistente de invitación pendiente, migrar la creación de membresías y actualizar `resolve-my-access`/los controles de panel para que una membresía pendiente nunca otorgue acceso antes de aceptar. Implementar solo un botón que borre o suspenda una membresía activa podría afectar administradores reales o no distinguir una invitación de una cuenta confirmada.

La revisión queda documentada como brecha funcional. No se modificó Auth, no se borraron cuentas ni membresías y no se desplegaron funciones.


## ACC-07 — La sesión de verificación de invitación puede obtener acceso antes de completar la contraseña — 19 nov 2026

### Hallazgo de seguridad

La revisión conjunta de `aceptar-invitacion.js`, `resolve-my-access/index.ts`, `technical-business-management/index.ts` y `login.js` identifica un riesgo alto de orden de activación:

1. `invite_member` crea la membresía con el estado que devuelve `create_business_membership_assignment`; la función no marca la membresía como pendiente de aceptación.
2. `aceptar-invitacion.js` procesa `verifyOtp({ type: 'invite' })`, obtiene y conserva una sesión autenticada (`persistSession: true`) y solo ejecuta `signOut({ scope: 'local' })` después de cambiar la contraseña.
3. `resolve-my-access` valida el token con `auth.getUser`, pero para las membresías solo comprueba `status='active'` y que el negocio esté activo. No verifica que el proceso de incorporación haya terminado.
4. `login.js` invoca `resolve-my-access` tras el inicio de sesión, y los paneles también usan sesiones existentes. Por tanto, la sesión temporal generada al verificar el enlace podría consultar las asignaciones activas antes de que la persona termine de establecer su contraseña. El flujo actual no demuestra que ese acceso anticipado esté bloqueado.

Esto no demuestra que una persona externa haya accedido; es una brecha de diseño reproducible que requiere prueba controlada en staging.

### Corrección necesaria antes de cerrar ACC-07

No basta con ocultar botones ni con confiar en `invited_at` o `email_confirmed_at`: la verificación OTP puede confirmar el correo antes de que se complete el establecimiento de la contraseña, y esos campos por sí solos no representan de forma fiable el final del onboarding.

La solución debe introducir un estado de incorporación persistente y confiable en servidor. Requisitos mínimos:

- Las asignaciones creadas para invitaciones nuevas y recuperadas deben quedar en estado pendiente, sin ser elegibles para `resolve-my-access` ni para las comprobaciones de acceso a panel.
- La aceptación debe completar la verificación del enlace y el establecimiento de contraseña, y luego llamar a una operación de servidor autenticada que valide el contexto y marque la incorporación como completada.
- La operación final debe confirmar la identidad desde el JWT validado por Auth, comprobar que la invitación/membresía sigue pendiente y activar únicamente la membresía correspondiente; la escritura y la auditoría deben ser atómicas.
- Si se revocó la asignación, la operación final no puede reactivarla. Si la cuenta tiene otras membresías, no debe modificarlas.
- `resolve-my-access`, el registro de acceso y las funciones privadas de autorización deben excluir cualquier membresía pendiente, no solo la pantalla de inicio de sesión.
- Las cuentas existentes y las membresías históricas requieren una migración de compatibilidad explícita; no deben quedar bloqueadas por un valor por defecto aplicado sin clasificación.

La implementación exige coordinar esquema, RPC, Edge Functions, página de aceptación, validadores de panel y verificador de integración. No se hizo un parche parcial que pudiera dejar una ruta alternativa abierta.

### Estado

**Abierto — severidad alta.** La revisión estática confirmó los cuatro puntos del flujo descrito. No se ejecutó una prueba de navegador con enlace real, no se modificó Auth ni la base activa, y no se desplegó ninguna función. La próxima implementación debe hacerse en la rama de trabajo como un cambio coordinado y probarse con cuentas ficticias en staging antes de considerar cerrado el hallazgo.


### Diseño técnico detallado para completar ACC-07 sin activar invitaciones cruzadas

La invitación de Supabase confirma el correo y permite terminar la configuración de la cuenta. `verifyOtp` entrega una sesión autenticada; por eso, el hecho de que el correo esté confirmado no demuestra que la contraseña ya se haya configurado ni que una asignación concreta haya sido aceptada. La aplicación no debe tratar `email_confirmed_at` como señal de onboarding completado.

#### Registro individual de invitación

El flujo debe incorporar una entidad propia por invitación, independiente de `business_memberships`, con al menos:

- `id`, `business_id`, `membership_id`, `user_id` (nullable hasta conocer la cuenta), `email_normalized`, `role`, `job_title`.
- `status` restringido a `pending`, `accepted`, `revoked`, `expired`, `failed`.
- `token_hash` único, nunca el token original; `created_at`, `expires_at`, `accepted_at`, `revoked_at`, `created_by`.
- Restricción para impedir más de una invitación pendiente para la misma asignación/negocio y usuario/correo, sin impedir que una misma persona reciba invitaciones independientes de distintos negocios.
- RLS habilitada y sin lectura pública. Solo RPC/Edge Function de servidor podrá crear, consultar o cambiar el estado.

El token debe generarse con un generador criptográficamente seguro, incluirse en el `redirectTo` de esa invitación y guardarse únicamente como hash. La aceptación presentará ese token a una Edge Function autenticada; la función buscará su hash, comprobará expiración/estado y verificará que `auth.uid()` corresponde a la cuenta destinataria. Así, aceptar una invitación no activa por accidente otras membresías pendientes del mismo correo.

#### Orden transaccional y recuperación

1. Crear el registro de invitación y la asignación pendiente en una RPC transaccional, sin otorgar acceso.
2. Enviar el correo con `inviteUserByEmail` desde servidor, pasando una URL de retorno que incluya el token de invitación de aplicación.
3. Si el envío falla, dejar un estado recuperable y auditable; no presentar la invitación como enviada. La reconciliación debe reusar el mismo registro, sin crear cuentas o tokens duplicados.
4. En la página de aceptación, verificar el enlace de Supabase, solicitar la contraseña y enviarla por HTTPS a una Edge Function dedicada. Esa función valida JWT, correo confirmado, token individual, estado pendiente y vigencia; actualiza la contraseña mediante Auth Admin desde servidor y llama a una RPC que acepta la invitación y activa solo la membresía asociada en una misma transacción de base de datos.
5. Si la actualización de contraseña funciona pero la RPC de activación falla, la invitación permanece pendiente y se permite reintentar la finalización con el mismo token; no se crea otra cuenta ni se reactiva otra membresía.
6. Al revocar, cambiar `status` a `revoked` en la misma operación que retira la asignación; la RPC de aceptación debe bloquear y volver a validar el registro para impedir carreras entre aceptar y revocar.
7. `resolve-my-access` y todas las funciones/RLS que autorizan operaciones de negocio deben exigir membresía activa y ausencia de onboarding pendiente. La validación de panel no puede ser la única barrera.

#### Compatibilidad y alcance

- Las membresías históricas y las asignaciones a cuentas ya confirmadas deben clasificarse explícitamente como existentes/completadas; no convertirlas masivamente a pendientes.
- La invitación Auth puede ser compartida por más de una asignación futura; por eso el estado de aceptación debe ser por invitación de aplicación, no un indicador global de la cuenta.
- Los enlaces de Auth tienen expiración configurable (la documentación actual indica una hora por defecto) y pueden consumirse por sistemas de previsualización de correo. El proceso debe contemplar reenvío controlado y un enlace/acción de confirmación manual, sin desactivar la verificación de Auth.
- No se deben usar `user_metadata` como fuente de autorización: es información editable por el usuario.

**Decisión de implementación:** no crear una simple columna booleana `onboarding_completed` en `profiles` ni bloquear toda la cuenta por invitación. El estado debe ser por invitación y membresía para soportar varios negocios, invitaciones concurrentes y revocación aislada.


## ACC-08 — Primer borrador del esquema de invitaciones individuales — 19 nov 2026

Se añadió `database/security/business-invitations-draft.sql` en la rama `correcciones-funcionales`. Es un borrador de implementación; todavía no se ejecuta en Supabase y no sustituye el flujo de invitación actual.

### Qué incorpora el borrador

- Tabla `business_invitations` con estado por invitación, negocio, usuario, correo normalizado, rol, cargo, vencimiento, actor y fechas de aceptación/revocación.
- SHA-256 del token de invitación; nunca guarda el token original.
- RLS habilitada y privilegios de tabla limitados a `service_role`.
- Índices únicos para impedir invitaciones pendientes duplicadas por negocio/correo y negocio/usuario.
- RPC para preparar invitación, vincular usuario Auth, marcar envío fallido, aceptar y revocar.
- La membresía se crea como `suspended` con una marca exacta de invitación pendiente. La función `private.has_business_role` observada en Supabase activo exige `m.status = 'active'`, por lo que ese estado no concede permisos. El resolver de acceso de la rama también filtra membresías `active`.
- La aceptación activa solo la membresía asociada al token, tras validación de la Edge Function.
- La revocación conserva la fila histórica de membresía como `suspended` con marca `Invitación revocada`, conserva la cuenta Auth y no modifica otras membresías.
- Aceptación y revocación bloquean negocio e invitación para serializar operaciones concurrentes.

### Dependencias que todavía faltan

1. Modificar `technical-business-management` para generar un token aleatorio criptográficamente seguro, guardar su hash mediante `prepare_business_invitation`, enviar el enlace con `redirectTo` y después vincular la cuenta devuelta por Auth.
2. Crear una Edge Function privada de aceptación que valide JWT con `getUser`, compare el correo autenticado con el correo invitado, exija correo confirmado, actualice la contraseña mediante Auth Admin y llame a `accept_business_invitation`.
3. Añadir a la interfaz técnica la lista de invitaciones pendientes y la acción de revocación con motivo.
4. Cambiar `aceptar-invitacion.js` para enviar el token individual y completar la activación solo después de guardar la contraseña.
5. Añadir pruebas de concurrencia, expiración, reintento, correo equivocado, dos negocios y conservación de membresías históricas.

**No se debe desplegar ni aplicar este SQL todavía.** Las funciones actuales de invitación siguen usando el flujo anterior y aún no escriben en `business_invitations`; por tanto, el borrador no está conectado a la aplicación. La verificación del paquete se amplió para exigir tabla, RLS, permisos, RPC, helper de roles e índices cuando se ejecute en un entorno de ensayo.


### ACC-08 — Integración inicial en Edge Function y página de aceptación

Se conectó en la rama el primer tramo de aplicación:

- `technical-business-management` genera un token aleatorio de 256 bits con Web Crypto y calcula su SHA-256.
- Prepara la invitación en la tabla antes de llamar a Auth, y añade `invitation_id` y el token original al enlace de retorno. El token original solo permanece en memoria y en el enlace enviado; la tabla conserva únicamente el hash.
- Tras recibir el usuario de Auth, vincula su cuenta a una membresía suspendida. Si el vínculo falla después de enviar el correo, el mismo intento puede reconciliarse sin reenviar el correo.
- Las cuentas existentes y confirmadas conservan la asignación directa normal; no se cambia su contraseña ni se envía invitación innecesaria.
- Se añadieron las acciones de servidor `list_business_invitations` y `revoke_invitation`, protegidas por la autorización técnica y MFA existente.
- Se creó `supabase/functions/accept-business-invitation/index.ts`. Verifica el JWT mediante `getUser`, exige correo confirmado, compara usuario/correo/token/expiración, actualiza la contraseña mediante Auth Admin y llama a la RPC de aceptación.
- `aceptar-invitacion.js` ya no cambia la contraseña directamente desde el navegador: invoca la Edge Function y solo cierra la sesión tras recibir confirmación de activación.
- Se configuró `verify_jwt = true` para la nueva función y se añadió `Referrer-Policy` mediante meta tag en la página de aceptación.

### Limitaciones y pruebas aún pendientes

- En la primera integración solo existían las acciones de servidor. La bandeja y el control de revocación se añadieron posteriormente en ACC-08, descrito más abajo.
- No se ha implementado un flujo de reenvío de invitaciones antiguas que ya existían antes de este esquema. Esas cuentas se rechazan de forma segura y requieren terminar el enlace anterior o una renovación controlada.
- El dominio de GitHub Pages debe estar permitido en Supabase Auth Redirect URLs para el retorno con parámetros de invitación; debe comprobarse en staging.
- La Edge Function de aceptación, la función técnica y el SQL no se han ejecutado con Deno/SQL parser ni probado en navegador.
- El SQL continúa siendo un borrador. No se aplicó en Supabase activo, no se desplegó ninguna Edge Function y no se enviaron correos reales.


### ACC-08 — Estado posterior: acciones del panel técnico y expiración

Se completó la conexión de la bandeja de invitaciones en `panel-tecnico.html` y `panel-live.js`:

- El técnico puede seleccionar un negocio y consultar sus invitaciones pendientes.
- La lista muestra correo, rol, cargo y vencimiento, con paginación.
- La acción de revocar exige motivo y confirma que solo se retira la asignación de esa invitación.
- El servidor verifica nuevamente la identidad técnica y MFA antes de listar o revocar.
- Las invitaciones vencidas se marcan como `expired` al consultar la bandeja o al intentar aceptarlas. La creación de una invitación nueva también marca vencidas las anteriores del mismo correo y negocio antes de insertar la nueva.

La revocación conserva la fila histórica de membresía en estado suspendido con motivo `Invitación revocada`; no elimina la cuenta Auth ni otras membresías.

**Estado del código en la rama:** el flujo de preparación, envío, vinculación, aceptación, listado, expiración y revocación ya tiene componentes SQL/Edge/UI coordinados. Sigue siendo una implementación no desplegada. La verificación 19/19 es estática; no equivale a ejecutar SQL ni probar el correo real.
