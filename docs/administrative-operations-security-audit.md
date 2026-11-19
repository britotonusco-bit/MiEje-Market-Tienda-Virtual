# Auditoría de operaciones administrativas, roles y auditoría inmutable

**Fecha:** 19 de noviembre de 2026  
**Repositorio:** `britotonusco-bit/MiEje-Market-Tienda-Virtual`  
**Rama:** `correcciones-funcionales`  
**Proyecto Supabase activo consultado:** `cqixlrwbqatbhzmpygiz`

## Alcance

Se compararon:
- `supabase/functions/technical-business-management/index.ts` en rama y versión desplegada.
- `database/security/administrative-membership-rpcs-draft.sql`.
- `database/security/business-admin-boundaries.sql`.
- `database/security/access-block-requests-draft.sql`.
- `database/integration/verify-integration-package.sql`.
- Políticas, privilegios, funciones y triggers activos mediante consultas SQL de solo lectura.

No se modificó Auth, la base de datos activa, usuarios, membresías, negocios ni funciones desplegadas.

## Hallazgos críticos en Supabase activo

### ADM-01 — La Edge Function desplegada sigue usando escrituras directas

La función `technical-business-management` activa es versión 6. Su código:
- Inserta negocios directamente en `businesses` y luego inserta auditoría en una operación separada.
- Invita usuarios, inserta perfiles/membresías y registra auditoría en pasos separados.
- Cambia el estado del negocio con UPDATE directo y luego inserta auditoría.
- Suspende y reactiva membresías con UPDATE directo y luego inserta auditoría.
- No usa las RPC transaccionales que ya están preparadas en la rama.

Esto permite que una mutación quede guardada aunque falle el registro de auditoría posterior. Las operaciones concurrentes tampoco cuentan con las protecciones transaccionales preparadas en la rama.

### ADM-02 — Las RPC administrativas de rama no están instaladas

Consultas de catálogo de PostgreSQL en todos los esquemas no encontraron estas funciones en el proyecto activo:
- `create_business_membership_assignment`
- `update_business_membership_assignment`
- `suspend_business_membership`
- `reactivate_business_membership`
- `set_technical_business_status`
- `moderate_business_content_transactionally`
- `create_technical_business_transactional`

La rama las define en `database/security/administrative-membership-rpcs-draft.sql`. Ese archivo permanece como borrador y no se aplicó.

### ADM-03 — La protección del último administrador no está activa

En `business_memberships` solo se observó el trigger `memberships_set_updated_at`. No aparece `guard_last_active_business_admin`.

La rama contiene esa protección en `database/security/business-admin-boundaries.sql`. Bloquea la fila del negocio y evita suspender, eliminar o degradar simultáneamente al último administrador activo.

### ADM-04 — Las políticas activas conservan acceso global del propietario técnico

Las políticas activas consultadas todavía incluyen:
- `profiles_select_self_or_owner`: permite al propietario técnico leer todos los perfiles.
- `memberships_select_self_admin_owner`: permite al propietario técnico leer todas las membresías.
- `businesses_admin_update`: incluye bypass `is_platform_owner()`.
- `businesses_public_directory_authenticated`: incluye bypass de propietario técnico.

La rama prepara políticas más limitadas en `business-admin-boundaries.sql`. No se aplicaron a producción.

### ADM-05 — `audit_logs` no es inmutable en la base activa

La consulta de privilegios confirmó que `service_role` conserva SELECT, INSERT, UPDATE, DELETE y TRUNCATE sobre `audit_logs`. No se observó trigger de protección en esa tabla. La política SELECT permite lectura a propietario técnico, administradores del negocio asociado y actores.

La rama ahora incluye el borrador `database/security/audit-log-immutability-draft.sql`, que:
- Bloquea UPDATE y DELETE mediante trigger.
- Bloquea TRUNCATE mediante trigger de sentencia.
- Revoca UPDATE, DELETE y TRUNCATE, también a `service_role`.
- Conserva SELECT/INSERT conforme a los flujos actuales.

El verificador de integración comprueba ambos triggers y privilegios.

### ADM-06 — Solicitudes de bloqueo no están instaladas

La tabla `access_block_requests` no aparece en el catálogo activo. La rama tiene el borrador `database/security/access-block-requests-draft.sql` y una acción técnica para resolver solicitudes. No puede considerarse disponible hasta instalar y verificar su esquema y RPC.

### ADM-07 — No existe eliminación de cuentas desde la función técnica revisada

La función desplegada no contiene acción `deleteUser` ni eliminación global de usuarios. La rama tampoco expone una acción de borrado global desde la interfaz técnica revisada. Las acciones existentes son asignación, cambio de rol/cargo, suspensión y reactivación de membresías, y suspensión/reactivación de negocios. Esto evita que una eliminación global accidental borre el acceso de una persona a todos sus negocios, pero deja pendiente definir un proceso formal de eliminación de cuenta y retención de auditoría/datos.

## Controles ya preparados en la rama

1. Todas las mutaciones de membresía bloquean primero el negocio y después la membresía.
2. Las RPC verifican que el actor sea `platform_owner` y no esté bloqueado.
3. La creación, cambio de rol, suspensión y reactivación insertan auditoría en la misma transacción.
4. No permiten retirar al último administrador activo.
5. La reactivación exige negocio activo y perfil global no bloqueado.
6. Las RPC están diseñadas como SECURITY INVOKER, con `search_path` vacío y EXECUTE exclusivo de `service_role`.
7. La Edge Function obtiene el actor desde el JWT validado; no confía en un actor_id enviado por el navegador.
8. La rama técnica exige AAL2 antes de ejecutar operaciones del propietario.

## Cambios hechos en esta revisión

- Se reforzó `database/integration/verify-integration-package.sql` para comprobar que las RPC técnicas sean SECURITY INVOKER, fijen `search_path` vacío y solo sean ejecutables por `service_role`.
- Se añadió comprobación del trigger del último administrador activo.
- Se creó `database/security/audit-log-immutability-draft.sql`.
- Se reforzó el verificador para exigir protección de UPDATE/DELETE/TRUNCATE de `audit_logs`, sin quitar INSERT de servidor.
- Este informe documenta las diferencias entre la rama y el proyecto activo.

## Pruebas necesarias en staging antes de desplegar

1. Crear negocio y provocar fallo de auditoría: toda la transacción debe revertirse.
2. Invitar usuario y provocar fallo en la asignación: registrar el estado parcial de Auth y permitir reconciliación sin invitación duplicada.
3. Intentar suspender el último administrador: debe fallar sin alterar la membresía.
4. Ejecutar dos suspensiones concurrentes de administradores: solo debe completarse una si la otra dejaría el negocio sin administrador.
5. Cambiar rol de administrador a empleado cuando sea el último administrador: debe fallar.
6. Reactivar membresía con negocio suspendido o perfil global bloqueado: debe fallar.
7. Intentar invocar las RPC con anon/authenticated: debe fallar por privilegios.
8. Intentar UPDATE/DELETE/TRUNCATE de audit_logs con service_role: debe fallar.
9. Confirmar que todas las acciones permitidas escriben exactamente un evento de auditoría dentro de la misma transacción.
10. Confirmar que la acción técnica exige AAL2 también mediante llamada directa a la Edge Function.

## Estado final

La rama tiene un diseño transaccional más seguro, pero la función activa sigue siendo la versión 6, con escrituras directas y sin las RPC ni el trigger de último administrador. El historial de auditoría activo permite alteración por service_role. Estos hallazgos impiden dar por cerrada la seguridad administrativa de producción.

No se ejecutó SQL de escritura, no se desplegó código y no se modificaron datos reales.


## Revisión adicional — moderación y solicitudes de bloqueo

### MOD-01 — La RPC de moderación de la rama bloquea y audita de forma atómica

`moderate_business_content_transactionally`:
- Valida que el actor sea propietario técnico y no esté bloqueado.
- Bloquea la publicación con `FOR UPDATE`.
- Acepta únicamente `approved` o `rejected`.
- Rechazar retira la publicación de la vista pública.
- Repetir exactamente la misma decisión y nota no vuelve a escribir ni genera un segundo evento.
- Un cambio real actualiza moderación y escribe auditoría en la misma transacción.

La función no publica automáticamente al aprobar: conserva el valor actual de `is_published`. La aprobación de moderación y la decisión comercial de publicar quedan separadas.

### MOD-02 — La política activa de contenido conserva lectura global técnica

En Supabase activo, `business_content_pages_admin_read` permite SELECT mediante `private.is_platform_owner()`. La rama reemplaza esa política por:
- Lectura pública de publicaciones aprobadas y publicadas en negocios activos.
- Lectura administrativa únicamente del negocio activo propio.

La RPC técnica de moderación no está instalada en el proyecto activo. La tabla sí existe y tiene RLS, pero no se verificó moderación segura de extremo a extremo en producción.

### BLK-01 — Las solicitudes de bloqueo no existen todavía en Supabase activo

Las consultas de solo lectura devolvieron:
- `public.access_block_requests`: inexistente.
- `public.resolve_access_block_request(uuid,text,text,uuid)`: inexistente.

Por tanto, la pantalla/acción de solicitudes preparada en la rama no debe considerarse operativa en el proyecto activo.

### BLK-02 — Controles del borrador de solicitudes

La rama:
- Solo permite a un administrador activo solicitar bloqueo de un integrante activo del mismo negocio.
- No permite que el administrador solicite su propio bloqueo.
- Limita la escritura autenticada a negocio, solicitante, objetivo y motivo.
- Usa índice único parcial para impedir dos solicitudes pendientes del mismo usuario/negocio.
- Solo permite resolver al propietario técnico no bloqueado.
- Bloquea la solicitud y, para aprobación, el negocio y la membresía.
- Evita bloquear al último administrador activo.
- Suspende únicamente la membresía del negocio indicado, no el perfil global.
- Registra la decisión en `audit_logs` dentro de la transacción.
- Una solicitud ya resuelta no se procesa de nuevo; la repetición devuelve conflicto y no genera otro evento.

Las solicitudes globales no se pueden crear por la política: `business_id` debe ser distinto de NULL. Si el negocio se elimina, la FK deja la solicitud histórica con `business_id = NULL`; puede rechazarse, pero no aprobarse porque ya no existe una membresía de ese negocio.

### BLK-03 — Verificador reforzado

Se amplió `verify-integration-package.sql` para comprobar:
- Índice único parcial de solicitudes pendientes por negocio/usuario.
- Privilegios de inserción por columna, sin permitir que el usuario fije estado o datos de resolución.
- RPC de resolución como SECURITY INVOKER, `search_path` vacío, bloqueo de fila, validación de propietario, protección del último administrador y auditoría.
- RPC de moderación con bloqueo, autorización y auditoría.

### Pruebas pendientes

- Enviar dos solicitudes simultáneas para el mismo integrante/negocio; debe sobrevivir una sola.
- Intentar insertar la solicitud con otro `requested_by`, estado aprobado o `resolved_by`; debe rechazarse.
- Resolver simultáneamente una misma solicitud con aprobación y rechazo; solo una decisión debe completarse.
- Repetir la resolución tras una respuesta perdida; debe devolver conflicto sin duplicar auditoría ni volver a suspender.
- Intentar bloquear al último administrador; la transacción debe revertirse.
- Confirmar que una cuenta suspendida en un negocio conserva su membresía en los demás.
- Moderar dos veces la misma publicación con la misma decisión/nota; la segunda llamada no debe generar auditoría adicional.
- Moderar con actor AAL1 o perfil bloqueado; la Edge Function debe rechazarlo.
- Comprobar que un administrador de negocio no puede leer publicaciones privadas de otro negocio ni datos de moderación globales.

No se ejecutaron migraciones, escrituras SQL ni despliegues.


### MOD-03 — La moderación activa no es atómica

La Edge Function desplegada versión 6 sí tiene la acción `moderate_business_content`, pero su implementación:
1. Lee la publicación.
2. Actualiza `business_content_pages` directamente.
3. Inserta el evento en `audit_logs` en una llamada separada.

Si la actualización funciona y el INSERT de auditoría falla, el contenido queda moderado sin evidencia correspondiente. Tampoco usa bloqueo transaccional de la fila mediante la RPC nueva.

La rama reemplaza ese flujo por `moderate_business_content_transactionally`. La función activa tampoco contiene la comprobación AAL2 que ya está preparada en la rama para la función técnica. Por ello no debe considerarse protegida contra llamadas directas con una sesión técnica de nivel AAL1.


## Auditoría transversal de `audit_logs` — 19 nov 2026

### AUD-01 — La tabla activa está vacía

Consulta SQL de solo lectura en Supabase activo `cqixlrwbqatbhzmpygiz`:
- `public.audit_logs` existe.
- Tiene columnas `id`, `business_id`, `actor_id`, `action`, `entity_type`, `entity_id`, `details`, `created_at`.
- La secuencia `public.audit_logs_id_seq` está asociada al identificador.
- La tabla tiene RLS habilitado y una policy SELECT.
- La consulta agregada devolvió cero eventos; por tanto, no hay eventos históricos con los que validar la cobertura real, la antigüedad o la integridad del historial.
- No se observaron triggers en la tabla.
- `service_role` conserva SELECT, INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER y REFERENCES.
- La policy activa `audit_logs_owner_or_business_admin_select` permite lectura global al propietario técnico, lectura de todos los eventos del negocio al administrador y lectura de eventos propios al actor.

### AUD-02 — La rama limita la lectura directa

Se actualizó `database/security/business-admin-boundaries.sql`:
- Se elimina la policy con bypass global `is_platform_owner()`.
- El panel técnico obtiene el historial global mediante la Edge Function autenticada y con rol técnico/MFA; no necesita SELECT global desde el navegador.
- La lectura directa queda limitada a un negocio activo.
- El administrador activo puede leer los eventos de su negocio.
- Un administrador o empleado activo puede leer sus propios eventos de ese negocio.
- No se concede lectura directa a usuarios anónimos ni a miembros de otros negocios.

El verificador exige la policy nueva y rechaza cualquier policy SELECT de `audit_logs` que incluya `is_platform_owner()`.

### AUD-03 — Inmutabilidad y calidad de metadatos

El borrador `database/security/audit-log-immutability-draft.sql` ahora incluye:
- Bloqueo de UPDATE y DELETE por trigger.
- Bloqueo de TRUNCATE por trigger.
- Revocación de UPDATE/DELETE/TRUNCATE a PUBLIC, anon, authenticated y service_role.
- Conservación de INSERT para el servidor.
- Validación de acción y entidad no vacías, longitudes máximas, `details` como objeto JSON y máximo 16 KiB.
- `created_at` fijado por PostgreSQL con `transaction_timestamp()` en cada INSERT.
- Comentario de columna que prohíbe almacenar contraseñas, tokens, documentos, teléfonos, correos y datos personales innecesarios.

No se exige `actor_id NOT NULL` porque puede existir auditoría de sistema y la FK histórica usa `ON DELETE SET NULL`. Las operaciones administrativas de usuario deben pasar siempre el actor obtenido del JWT validado.

### AUD-04 — Textos libres en eventos

Las RPC de rama incluyen motivos y notas de suspensión, reactivación, moderación y solicitudes de bloqueo. Esos campos son útiles para explicar una decisión, pero son texto libre y podrían contener datos personales introducidos por error.

Se añadieron avisos junto a los formularios de motivos en `panel-tecnico.html` y `panel-negocio.html`, indicando que no deben introducir contraseñas, teléfonos, correos, documentos ni datos personales innecesarios. Los límites de tamaño de los formularios y el límite global de 16 KiB del evento reducen el volumen, pero no detectan automáticamente PII en texto libre.

### AUD-05 — Consulta del historial

La acción `list_audit_logs`:
- Solo está disponible después de validar al propietario técnico.
- Permite filtrar por negocio.
- Ahora limita cada respuesta a un máximo de 100 eventos.
- Valida que el filtro de negocio tenga formato UUID.
- Devuelve los nombres visibles de los actores que siguen teniendo perfil.

El contador de eventos utiliza `count: exact`; la tabla de panel muestra hasta 100 eventos recientes. No se ha implementado paginación histórica por cursor.

### AUD-06 — Retención no definida

No se encontró una política de retención, archivo o particionado para `audit_logs`. Tampoco se identificó una automatización de purga. El borrador favorece conservar el historial sin modificaciones ni borrados, pero eso no sustituye una política formal de conservación, acceso y tratamiento de datos.

Antes de producción debe decidirse un plazo de conservación y, si el volumen crece, un mecanismo de archivo que preserve integridad y disponibilidad. No debe añadirse una purga automática hasta que exista una regla aprobada y compatible con las obligaciones legales y de investigación.

### Verificaciones estáticas añadidas

- Trigger BEFORE INSERT de validación y timestamp.
- Función de trigger SECURITY INVOKER con `search_path` vacío.
- Policy de lectura directa limitada por negocio/rol y sin bypass técnico global.
- Triggers de UPDATE/DELETE y TRUNCATE.
- Privilegios de service_role: INSERT conservado; UPDATE/DELETE/TRUNCATE revocados.

No se ejecutaron migraciones ni escrituras SQL. El conteo de eventos en la base activa fue solo agregado y devolvió cero.


## Revisión adicional de invitaciones y cambios de membresía — 19 nov 2026

Se contrastó el formulario del panel técnico con las acciones de la Edge Function y las RPC transaccionales del borrador SQL.

- El selector de miembros devuelve el identificador de la membresía (`business_memberships.id`), no el identificador de Auth. Se cambió el nombre del campo HTML a `membership_id` y el panel ahora envía ese campo explícitamente para suspender o reactivar.
- La Edge Function valida el formato UUID de la membresía en los cambios de rol/cargo, suspensión y reactivación. También exige motivos de al menos cinco caracteres para suspender/reactivar.
- Los cambios de rol/cargo llaman a `update_business_membership_assignment`; suspensión y reactivación llaman a sus RPC transaccionales. Los procedimientos borrador verifican el actor técnico, bloquean el negocio antes que la membresía y protegen la existencia de al menos un administrador activo.
- La suspensión/reactivación de una tienda llama a `set_technical_business_status`; la decisión se registra en auditoría dentro de la RPC.

### Limitación que sigue pendiente en invitaciones

El envío de correo de Auth y la asignación de membresía son dos operaciones distintas: primero se crea/envía la invitación y después se ejecuta la RPC transaccional. Si Auth envía el correo pero la RPC falla, puede quedar una cuenta invitada sin membresía. Se corrigió el mensaje de error para no prometer un reenvío automático: el usuario debe aceptar y confirmar el correo antes de volver a intentar la asignación. Si el correo no llega, el panel todavía no ofrece un flujo de reenvío; requiere revisión de Auth.

Esta separación no se puede hacer atómica con una sola transacción PostgreSQL. Antes de producción hace falta un proceso idempotente de reconciliación y un flujo de reenvío limitado y auditado.

No se desplegó la Edge Function ni se aplicó el borrador SQL. La revisión es estática; no se probaron correos, confirmaciones, concurrencia ni restricciones en staging.


### Corrección adicional: motivo de reactivación de una tienda

La revisión encontró que el formulario pedía una nota al reactivar una tienda, pero la RPC borraba el motivo de suspensión y también perdía la nota de reactivación antes de escribir la auditoría. Se corrigió el borrador:

- Se conserva el texto de la decisión en una variable separada del motivo de suspensión que queda en la ficha del negocio.
- Si cambia el estado, el servidor exige un motivo de al menos cinco caracteres.
- El registro de auditoría guarda `decision_reason` tanto al suspender como al reactivar.
- La ficha pública/administrativa sigue limpiando el motivo de suspensión y el mensaje público al reactivar.
- El formulario y la Edge Function también exigen el motivo para cualquier cambio de estado.

El verificador SQL ahora comprueba que la RPC contenga la persistencia de `decision_reason`. No se aplicó el borrador a Supabase activo.


## Revisión de cambios de rol y estados concurrentes — 19 nov 2026

Se comprobó la lógica de las RPC transaccionales de asignación, cambio de rol, suspensión y reactivación:

- Las operaciones de membresía usan el bloqueo de la fila del negocio como punto de serialización y después bloquean la membresía concreta. Así, dos cambios simultáneos dentro del mismo negocio no pueden calcular a la vez que ambos son el último administrador.
- El cambio de rol de administrador a empleado cuenta los demás administradores activos y rechaza retirar el último rol administrativo.
- La suspensión aplica la misma protección al último administrador activo.
- La reactivación exige que el negocio esté activo y que el perfil no tenga bloqueo global.
- Los cambios efectivos escriben su registro de auditoría dentro de la misma transacción; los estados ya aplicados devuelven una respuesta idempotente sin crear un evento duplicado.
- Se añadieron comprobaciones al verificador para exigir bloqueos, protección del último administrador y auditoría en las tres RPC.
- En la interfaz, cambiar el negocio ahora limpia la cuenta y los campos de rol/cargo anteriores. Mientras se carga la lista, se deshabilita el envío del formulario. Antes de enviar, se comprueba que la membresía seleccionada pertenezca al negocio elegido. Después de guardar, se limpian los campos para evitar mostrar una selección antigua.

Estas comprobaciones son de código y no equivalen a una prueba de concurrencia real. Aún faltan Deno check, ejecución del verificador en una base de staging y pruebas simultáneas que intenten degradar o suspender al último administrador. No se aplicaron migraciones ni se modificó la base activa.
