# Auditoría de funciones administrativas — 16 nov 2026

## Alcance y método

Revisión estática de `supabase/functions/technical-business-management/index.ts` en la rama `correcciones-funcionales`, comparación con la Edge Function `technical-business-management` desplegada en `MiEje Market Independiente` (versión 6), y consultas SQL de solo lectura sobre políticas RLS, permisos de columnas y funciones presentes en la base activa.

No se enviaron invitaciones, no se modificaron cuentas ni membresías, no se ejecutó SQL de escritura, no se desplegaron funciones y no se modificó `main`.

## Resultado ejecutivo

La rama tiene una separación más estricta que la función desplegada, pero la producción todavía conserva dos rutas de acceso que deben corregirse antes de considerar cerrada la seguridad administrativa:

1. La Edge Function desplegada versión 6 no exige MFA AAL2 en servidor. La rama sí lo exige al propietario técnico antes de cualquier acción.
2. La política RLS activa `businesses_admin_update` permite `UPDATE` cuando el usuario es propietario técnico **o** administrador del negocio. Además, `authenticated` conserva permisos de actualización sobre columnas comerciales. Esto permite al propietario técnico modificar directamente la ficha comercial de cualquier negocio mediante la API de datos, sin pasar por la Edge Function ni por su comprobación AAL2. También contradice el modelo acordado: el propietario técnico gestiona la plataforma y los accesos; el administrador configura su tienda.

El borrador `database/security/business-admin-boundaries.sql` elimina la excepción del propietario técnico y limita el UPDATE al administrador del negocio activo. Sigue pendiente de revisión y aplicación controlada.

## 1. Autenticación y separación de acciones

### Rama `correcciones-funcionales`

- Valida el JWT con `auth.getUser(token)`.
- Consulta el perfil desde servidor y rechaza perfiles inexistentes o bloqueados.
- Si el perfil es `platform_owner`, exige `currentLevel === "aal2"` antes de ejecutar las acciones técnicas.
- Después de la excepción controlada de `log_login`, exige `isOwner` para las acciones administrativas restantes.
- Las acciones de panel comercial registran el acceso solo si la membresía coincide con el rol esperado y el negocio está activo.

La estructura evita que un administrador de negocio o empleado invoque las acciones técnicas desde esta Edge Function.

### Función desplegada versión 6

- Valida JWT, perfil y rol `platform_owner`.
- No comprueba el nivel AAL2 en el servidor.
- Conserva un conjunto anterior de acciones y no contiene varias acciones nuevas de finanzas, nómina, configuración IA ni solicitudes técnicas de bloqueo presentes en la rama.

**Conclusión:** no se debe desplegar la versión actual de la rama sin pruebas AAL1/AAL2 en un entorno de ensayo; tampoco debe considerarse protegida la versión desplegada por el solo hecho de que la interfaz solicite MFA.

## 2. Hallazgo crítico: actualización directa de negocios por el propietario técnico

En la base activa se observó:

- RLS habilitado en `public.businesses`.
- Política `businesses_admin_update` con la condición `is_platform_owner() OR has_business_role(... business_admin ...)`.
- Permisos de columna `UPDATE` para `authenticated` en campos comerciales como nombre, categoría, descripción, ciudad, contacto, logo, horarios, tipo de negocio, tarifa de domicilio y pedido mínimo.

Por tanto, un propietario técnico autenticado puede actualizar esos campos directamente a través de la API de datos, sin pasar por `technical-business-management`. La política RLS no exige AAL2 y el rol técnico recibe capacidad de edición comercial que no corresponde a la separación de paneles definida.

**Corrección preparada:** `database/security/business-admin-boundaries.sql` reemplaza la política para exigir que la persona sea administrador activo del negocio y que el negocio esté activo. El propietario técnico debe conservar la gestión mediante Edge Function con `service_role`, no mediante edición directa de la ficha comercial.

**Estado:** hallazgo confirmado en producción; corrección solo en borrador. No se aplicó.

## 3. Revisión de acciones administrativas de la rama

| Acción / grupo | Control observado en rama | Resultado |
|---|---|---|
| `list_businesses`, `list_business_members` | Propietario técnico tras la validación de perfil y AAL2 | Correcto en la Edge Function |
| `list_audit_logs`, `list_content_moderation` | Propietario técnico; límites de consulta de 500 y 100 filas respectivamente | Correcto; revisar minimización de datos |
| `create_business` | Propietario técnico; crea solo registro base, nombre, categoría y slug | Respeta la separación comercial |
| `invite_member` | Propietario técnico; negocio debe existir y estar activo; rol limitado a `business_admin` o `employee`; evita membresía duplicada | Parcial; pendientes de flujo de invitación y límite de solicitudes |
| `update_member_assignment` | Propietario técnico; rol limitado; comprueba último administrador; actualización condicional | Riesgo de carrera concurrente |
| `block_member` / `unblock_member` | Propietario técnico; suspensión por negocio; reactivación exige negocio activo | Correcto en flujo ordinario; riesgo de carrera en último administrador |
| `set_business_status` | Propietario técnico; estados permitidos `active`, `suspended`, `closed`; exige motivo al suspender | Control de rol correcto; auditoría no atómica |
| `moderate_business_content` | Propietario técnico; decisión limitada a aprobar/rechazar; rechazo despublica | Correcto en Edge Function |
| `list_block_requests` / `resolve_block_request` | Propietario técnico; resolución usa RPC transaccional | Código preparado; tabla y RPC no existen en base activa |
| Finanzas y nómina de plataforma | Propietario técnico; importes positivos y estados restringidos | Código y migración en rama; tablas y RPC no existen en base activa |
| Configuración pública y de IA | Propietario técnico; validaciones de campos y URLs HTTPS para imágenes | Código preparado; tablas no existen en base activa |

## 4. Hallazgos y riesgos que requieren corrección

### 4.1 MFA de servidor ausente en producción — crítico

La versión 6 desplegada no comprueba AAL2. Un propietario con JWT válido puede invocar las acciones técnicas de esa versión sin que la Edge Function confirme el segundo factor. La rama incorpora la comprobación, pero todavía no está desplegada ni probada.

### 4.2 Política RLS permite al propietario editar negocios directamente — crítico

La política y los permisos de columnas activos permiten modificar la configuración comercial de cualquier negocio sin usar la Edge Function. Esto también evita el control AAL2 aplicado en la rama. Debe aplicarse el borrador de límites de administrador después de revisar grants, columnas y pruebas de acceso.

### 4.3 Comprobación del último administrador no es atómica — alto

En `update_member_assignment` y `block_member`, la rama consulta el número de administradores activos y después actualiza una membresía en otra operación. Dos solicitudes concurrentes sobre administradores distintos podrían superar ambas la comprobación con el mismo conteo y dejar el negocio sin administrador activo.

La actualización condicional de la membresía protege contra cambios sobre esa misma fila, pero no serializa operaciones sobre dos administradores diferentes. La protección debe trasladarse a una RPC transaccional que bloquee la fila del negocio (o un bloqueo equivalente), vuelva a contar administradores y haga el cambio y la auditoría en la misma transacción.

### 4.4 Auditoría separada de la operación — alto

Varias acciones actualizan primero el negocio, membresía o contenido y escriben `audit_logs` después. Si la inserción de auditoría falla, el cambio principal puede quedar guardado sin su registro. En algunos casos la Edge Function responde con error aunque la modificación ya se realizó, lo que puede inducir reintentos.

Debe consolidarse cada mutación sensible y su evento de auditoría en una RPC transaccional o una operación de servidor que garantice atomicidad. Mientras tanto, la interfaz debe distinguir claramente una operación aplicada con advertencia de auditoría de una operación no aplicada.

### 4.5 Invitaciones sin límite específico y sin reenvío para usuarios existentes — medio

La rama no aplica un límite de solicitudes por propietario, negocio y correo. Además, cuando el correo ya corresponde a un usuario Auth, la función crea la membresía sin enviar una nueva invitación. Esto puede ser correcto si el usuario ya tiene una cuenta utilizable, pero no resuelve el caso de una cuenta existente que aún no confirmó correo o necesita recuperar el acceso.

Se debe definir un flujo explícito para usuarios existentes/no confirmados y añadir limitación atómica de invitaciones en servidor. No se debe reenviar ni crear membresías a ciegas.

### 4.6 Datos personales en consultas administrativas — medio

La lista de miembros devuelve correo Auth y datos de perfil; los registros de auditoría incluyen detalles JSON y el evento de inicio de sesión guarda el correo. El acceso está reservado al propietario técnico en la Edge Function, pero debe revisarse si cada campo es necesario para la tarea administrativa, limitar la exposición y evitar guardar datos personales redundantes en eventos.

## 5. Funciones y tablas que aún no existen en la base activa

Las consultas de solo lectura no encontraron estas tablas en el proyecto activo:

- `access_block_requests`
- `platform_financial_records`
- `payroll_records`
- `platform_ai_settings`
- `platform_public_settings`

Tampoco se encontró la función SQL `resolve_access_block_request(uuid,text,text,uuid)` ni `resolve_platform_payroll_record(uuid,text,text,uuid)`.

Los borradores correspondientes están en la rama, pero las acciones que dependen de ellos no pueden considerarse operativas en producción. La función de resolución de solicitudes de bloqueo concede ejecución solo a `service_role` y verifica que el identificador de técnico corresponda a un propietario no bloqueado; la Edge Function es quien valida la sesión y AAL2 antes de llamar el RPC. El RPC de nómina también está limitado a `service_role` y se invoca desde la acción técnica.

## 6. Puntos que sí están bien encaminados

- El propietario técnico no puede asignar roles fuera de `business_admin` y `employee` mediante la acción de invitación.
- El alta de negocio en la rama crea solo la ficha base; la configuración comercial queda para el administrador del negocio.
- Las acciones técnicas de la rama rechazan perfiles bloqueados.
- Las solicitudes de bloqueo están diseñadas para suspender solo una membresía, no la cuenta global.
- El RPC de resolución de solicitudes bloquea la solicitud, valida el último administrador y registra auditoría dentro de la misma transacción.
- El RPC de nómina bloquea el registro, permite una sola resolución y combina el cambio de estado, el movimiento financiero y la auditoría en una transacción.
- La política RLS de `business_content_pages` no concede al administrador del negocio permisos de actualización sobre `moderation_status`; además, la lectura pública exige que el contenido esté aprobado y el negocio activo. No se encontró una vía directa de autoaprobación con los grants revisados.

## 7. Próximos pasos recomendados

1. Corregir la política RLS `businesses_admin_update` para retirar el bypass del propietario técnico y aplicar el borrador de límites de negocio tras pruebas controladas.
2. Preparar una RPC transaccional para cambios de roles/suspensiones que proteja el último administrador frente a concurrencia y escriba auditoría atómicamente.
3. Completar el flujo de invitación/reinvitación y el límite de solicitudes.
4. Aplicar en un entorno de ensayo las migraciones de configuración, finanzas/nómina y solicitudes de bloqueo; probarlas antes de producción.
5. Probar la función técnica con sesiones AAL1 y AAL2, y solo después planificar el despliegue.
6. Revisar la minimización de datos en listados de miembros y auditoría.

## Estado final de esta auditoría

- Revisión estática de la función técnica en rama: realizada.
- Comparación con Edge Function desplegada versión 6: realizada.
- Consultas SQL de políticas RLS, permisos de columnas, tablas y funciones: realizadas en modo lectura.
- Pruebas E2E, MFA AAL1/AAL2, concurrencia e invitaciones: pendientes; no hay entorno de ensayo disponible.
- SQL de escritura, cambios Auth, despliegues, cambios de membresía, fusión de PR y publicación: no realizados.
