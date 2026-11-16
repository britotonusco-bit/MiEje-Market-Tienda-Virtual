# Auditoría de mutaciones administrativas — 16 nov 2026

## Alcance

Revisión estática de la rama `correcciones-funcionales`, centrada en las acciones `create_business`, `invite_member`, `update_member_assignment`, `block_member`, `unblock_member`, `set_business_status` y `moderate_business_content`.

No se ejecutaron mutaciones en Supabase, no se enviaron invitaciones, no se modificaron membresías, no se desplegó código y no se fusionó ninguna rama.

## Controles comunes observados

- La Edge Function valida el JWT con `auth.getUser(token)`.
- Consulta el perfil desde el servidor y rechaza perfiles inexistentes o marcados como bloqueados.
- Si el perfil es `platform_owner`, exige nivel MFA `aal2` en servidor.
- Después de la acción de registro de acceso, las acciones administrativas requieren `platform_owner`.
- Las escrituras usan el cliente servidor creado con `SUPABASE_SERVICE_ROLE_KEY`; la clave no debe llegar al navegador.
- Los roles de invitación están limitados a `business_admin` y `employee`.

Estos controles de la rama no corrigen por sí solos la versión 6 desplegada ni las políticas RLS activas. La corrección de producción sigue pendiente.

## Hallazgos por acción

### 1. `create_business`

La acción crea solo la ficha base (nombre, categoría y slug), sin modificar logo, pagos, horarios ni otros datos comerciales. Esto respeta la separación acordada entre el panel técnico y el administrador del negocio.

La creación y el evento `audit_logs` son dos operaciones separadas. La función ya responde con éxito y una advertencia si el negocio se creó pero falló la auditoría; esto evita inducir un reintento que chocaría con el slug único.

**Pendiente:** mover la inserción del negocio y la auditoría a una única operación transaccional, o conservar un mecanismo de reconciliación claramente visible.

### 2. `invite_member`

Controles positivos:
- exige que el negocio exista y esté activo;
- valida correo, nombre, cargo y rol;
- evita asignar una segunda membresía al mismo usuario y negocio;
- no asigna membresía si Supabase no confirma la invitación de un usuario nuevo;
- deja constancia de si se envió correo o se asignó una cuenta ya existente.

Riesgos pendientes:
- Para un usuario Auth ya existente, crea la membresía directamente sin reenviar invitación ni comprobar si el correo está confirmado o si la cuenta puede iniciar sesión. Debe definirse un flujo separado de asignación, confirmación y recuperación.
- No se consulta `profiles.is_blocked` al resolver el usuario existente. La autorización posterior puede rechazarlo mediante los helpers de rol, pero la acción podría crear una membresía activa para una cuenta bloqueada. Conviene rechazarla explícitamente antes de asignar acceso.
- El correo de invitación puede enviarse antes de crear el perfil y la membresía. Si una operación posterior falla, puede quedar un usuario invitado sin acceso al negocio. Hace falta un flujo de compensación/reintento o una bandeja de invitaciones pendientes.
- No se observa un límite atómico de invitaciones por técnico, negocio y correo.
- La membresía y el evento de auditoría se guardan por separado.

**Prioridad:** alta para validar el estado global del usuario y diseñar recuperación de invitaciones incompletas; media para rate limit y atomicidad de auditoría.

### 3. `update_member_assignment`

La función lee la membresía, cuenta administradores activos y luego actualiza la fila con condiciones sobre el estado anterior. La actualización condicional protege frente a cambios concurrentes sobre esa misma membresía, pero no basta para serializar cambios en dos administradores distintos.

El borrador SQL incorpora un trigger que bloquea la fila del negocio antes de contar administradores y rechaza quitar, trasladar o suspender la última membresía administrativa activa. El trigger es `SECURITY INVOKER`; las escrituras están reservadas al servidor y el rol ejecutor debe tener los permisos de lectura requeridos.

**Pendiente:** probar en un entorno aislado dos cambios simultáneos sobre administradores diferentes, además de cambio de rol y eliminación. No se ha demostrado aún el comportamiento bajo concurrencia.

### 4. `block_member` y `unblock_member`

Ambas acciones requieren propietario técnico. La suspensión exige motivo y comprueba el último administrador; la reactivación exige que el negocio esté activo y requiere motivo.

La comprobación en la Edge Function tiene una ventana de concurrencia. El trigger del borrador SQL debe ser la defensa final para impedir que dos suspensiones simultáneas retiren al último administrador. La reactivación no debe poder activar una membresía si el negocio está suspendido o cerrado.

La modificación y la auditoría son operaciones separadas; ante fallo de auditoría se devuelve una advertencia.

**Pendiente:** pruebas transaccionales y de concurrencia, además de comprobar el comportamiento si el negocio cambia de estado durante la reactivación.

### 5. `set_business_status`

La acción restringe los estados a `active`, `suspended` y `closed`; exige motivo al suspender y limpia los datos de suspensión al reactivar o cerrar.

El cambio de estado y la auditoría son dos operaciones separadas. Si falla la auditoría, la función puede responder error aunque el estado ya haya cambiado, lo que puede provocar reintentos confusos. Tampoco se observa una condición sobre el estado anterior para detectar que otra operación modificó el negocio durante la solicitud.

**Pendiente:** RPC transaccional con auditoría y control del estado anterior, además de definir si un cierre es reversible y bajo qué condiciones.

### 6. `moderate_business_content`

La decisión está limitada a `approved` o `rejected`; el rechazo retira la publicación de la vista pública. La acción está detrás del control técnico de la Edge Function.

La actualización y la auditoría son operaciones separadas. La actualización no compara el estado de moderación previamente leído, por lo que dos decisiones concurrentes pueden sobrescribirse; la respuesta podría no reflejar el cambio final.

**Pendiente:** operación transaccional que registre el estado anterior y nuevo, y que detecte cambios concurrentes.

## Matriz de prioridad

| Prioridad | Hallazgo | Acción recomendada |
|---|---|---|
| Alta | Usuario Auth existente puede recibir membresía sin comprobar bloqueo global ni confirmación | Validar estado del perfil/cuenta y definir asignación o reinvitación |
| Alta | Invitación enviada y luego falla la creación de membresía | Añadir recuperación de invitaciones incompletas |
| Alta | Último administrador bajo concurrencia | Mantener el trigger y ejecutar pruebas simultáneas en ensayo |
| Alta | Mutación y auditoría no atómicas | RPC transaccionales para cambios sensibles |
| Media | Sin límite atómico de invitaciones | Añadir rate limit servidor |
| Media | Cambios concurrentes de estado/moderación | Comparación del estado anterior y RPC transaccional |
| Media | Listado de miembros incluye correo y teléfono | Minimizar datos devueltos según necesidad del panel |

## Próximas pruebas necesarias

1. Dos suspensiones simultáneas de administradores distintos del mismo negocio.
2. Cambio simultáneo de rol y suspensión sobre administradores diferentes.
3. Reactivación de membresía mientras el negocio cambia de estado.
4. Usuario existente con perfil bloqueado o correo sin confirmar.
5. Invitación enviada y fallo posterior al crear perfil o membresía.
6. Fallo deliberado de auditoría para comprobar que no queda una mutación sin rastro.
7. Dos decisiones simultáneas sobre la misma publicación.
8. Reintentos de creación e invitación para confirmar respuestas idempotentes o conflictos claros.

## Estado

- Revisión estática de la rama: realizada.
- Correcciones de producción: no aplicadas.
- Migraciones: no ejecutadas.
- Pruebas de concurrencia, MFA, invitaciones y fallos de auditoría: pendientes.
- Despliegue y fusión: no realizados.
