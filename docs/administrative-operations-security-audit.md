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
- `database/integration/verify-integration-package.sql).
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
