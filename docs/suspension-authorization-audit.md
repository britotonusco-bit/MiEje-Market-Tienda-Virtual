# Auditoría de suspensión y autorización de acceso

**Fecha:** 20 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Estado:** revisión estática. No se ejecutó SQL, no se desplegaron funciones y no se modificó Supabase activo.

## Alcance

Se revisaron `resolve-my-access`, `technical-business-management`, `login.js`, `panel-live.js`, los borradores de RPC de membresías, suspensión de negocios y solicitudes de bloqueo, y las políticas propuestas en `business-admin-boundaries.sql`.

## ACC-16 — Separación entre bloqueo global, suspensión de membresía y suspensión del negocio

El código de la rama distingue tres estados que no deben confundirse:

| Estado | Efecto esperado |
|---|---|
| `profiles.is_blocked = true` | La cuenta completa no obtiene rutas de panel ni puede usar la Edge Function técnica. |
| `business_memberships.status = 'suspended'` | La persona pierde acceso únicamente al negocio asociado a esa membresía. |
| `businesses.status = 'suspended'/'closed'` | Los administradores y empleados pierden acceso a ese negocio, aunque su cuenta y otras membresías sigan activas. |

### Controles encontrados

1. **Acceso inicial:** `resolve-my-access` valida el JWT con Auth, consulta el perfil en servidor y rechaza `is_blocked`. Devuelve únicamente membresías `active` cuyos negocios también están `active`.
2. **Operaciones técnicas:** `technical-business-management` rechaza perfiles inexistentes o bloqueados antes de procesar acciones. Para `platform_owner`, además exige AAL2 en servidor.
3. **Panel abierto:** `panel-live.js` vuelve a consultar `resolve-my-access` cada 30 segundos y al recuperar visibilidad. Si el perfil o la ruta dejan de estar autorizados, cierra la sesión local y redirige al login. Esto protege la interfaz; no sustituye la autorización de cada operación.
4. **Suspensión de membresía:** `suspend_business_membership` solo cambia la fila de la membresía seleccionada, registra auditoría y evita suspender al último administrador activo.
5. **Reactivación de membresía:** `reactivate_business_membership` exige que el negocio esté activo y comprueba `profiles.is_blocked = false` del usuario objetivo antes de reactivar. No puede reactivar membresías pendientes o revocadas por invitación.
6. **Suspensión del negocio:** `set_technical_business_status` modifica el estado del negocio con autorización del propietario técnico y registro de auditoría. Al dejar de estar activo, el negocio desaparece de las rutas devueltas por `resolve-my-access`.
7. **Solicitudes de bloqueo de un administrador:** la RPC `resolve_access_block_request` suspende la membresía de esa persona en ese negocio, no modifica `profiles.is_blocked` y no elimina otras membresías.
8. **Invitaciones:** las membresías pendientes y revocadas conservan marcas internas y no se pueden reactivar con la RPC administrativa genérica.

## ACC-17 — No existe un flujo completo de bloqueo global desde el panel

La revisión del código de la rama encuentra acciones para suspender y reactivar membresías, suspender/reactivar negocios y resolver solicitudes de bloqueo local. No encuentra una acción administrativa específica y completa para establecer o retirar `profiles.is_blocked`.

El formulario del panel técnico puede mostrar que una cuenta está bloqueada globalmente, pero su control de estado opera sobre la membresía seleccionada. El propio mensaje de la interfaz advierte que reactivar esa membresía no elimina el bloqueo global.

**Decisión pendiente:** definir si el propietario técnico tendrá un flujo global de bloqueo/desbloqueo, qué motivos lo permiten, qué verificación adicional exige, cómo se recupera una cuenta bloqueada por error y cómo se audita. No se debe reutilizar `block_member`/`unblock_member` para modificar `profiles.is_blocked`: esas acciones están diseñadas para una sola membresía.

No se implementa un desbloqueo global improvisado. Podría devolver acceso a todos los negocios de una cuenta y requiere una autorización de mayor alcance.

## Límites de la revisión

- `business_is_active` y `has_business_role` se invocan ampliamente en las políticas propuestas, pero sus definiciones no están incluidas como código fuente en los archivos SQL revisados. Su comportamiento efectivo debe comprobarse en la base de staging y en la base activa mediante consultas de solo lectura.
- El borrador `business-admin-boundaries.sql` retira bypasses de `platform_owner` y limita permisos directos; no se ha aplicado. En la base activa ya se habían detectado bypasses RLS para el propietario técnico y grants directos sobre columnas sensibles. Por tanto, no se puede afirmar que el aislamiento esté ya garantizado en producción.
- La comprobación de acceso del navegador ocurre cada 30 segundos. Un JWT ya emitido puede seguir siendo aceptado hasta expirar si una operación no consulta el estado vigente del perfil/membresía/negocio en servidor o RLS.
- Las consultas estáticas no prueban concurrencia real entre suspensión, reactivación y operaciones de negocio.

## Pruebas obligatorias en staging

1. Perfil global bloqueado intenta login, abrir panel técnico, abrir panel de negocio y llamar directamente a Edge Functions/RPC.
2. Perfil global bloqueado intenta recuperar contraseña: puede cambiarla si el enlace es válido, pero continúa bloqueado después.
3. Suspender una membresía en negocio A: pierde acceso a A y conserva acceso a negocio B.
4. Reactivar esa membresía con perfil global bloqueado: la RPC debe rechazarla.
5. Reactivar una membresía con negocio suspendido o cerrado: la RPC debe rechazarla.
6. Reactivar el negocio: no debe reactivar automáticamente membresías suspendidas individualmente.
7. Suspender un negocio con administradores y empleados conectados: todos pierden la ruta a ese negocio; otras membresías continúan disponibles.
8. Suspender el último administrador activo: debe rechazarse.
9. Solicitud de bloqueo aprobada: suspende solo la membresía indicada; rechazada: no modifica la membresía.
10. Invitación pendiente o revocada: la reactivación genérica debe rechazarse.
11. Ejecutar las mismas pruebas con llamadas directas a Data API y RPC, no solo desde la interfaz.
12. Repetir con dos sesiones y operaciones concurrentes para comprobar que no se use una autorización obsoleta.

## Conclusión

La separación lógica de los tres tipos de suspensión está representada correctamente en las funciones y borradores de la rama. La reactivación local respeta el bloqueo global y el estado del negocio; la suspensión de negocio no equivale a bloquear la cuenta completa.

Quedan dos bloqueadores: definir el proceso administrativo de bloqueo global y verificar en staging las funciones de autorización, RLS y RPC. No se considera aprobada la seguridad hasta superar las pruebas anteriores y corregir los bypasses ya identificados en la base activa.
