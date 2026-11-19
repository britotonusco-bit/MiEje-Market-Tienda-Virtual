# Auditoría de administración de membresías y usuarios

**Fecha:** 16 de noviembre de 2026  
**Proyecto Supabase:** MiEje Market Independiente (`cqixlrwbqatbhzmpygiz`)  
**Rama:** `correcciones-funcionales`

## Alcance

Se revisó el modelo activo de `business_memberships`, sus restricciones, índices, políticas RLS y privilegios; las acciones del panel técnico; la Edge Function candidata; y las RPC SQL preparadas para crear, cambiar, suspender y reactivar membresías.

Todas las consultas al proyecto activo fueron de solo lectura. No se ejecutaron migraciones, no se cambiaron usuarios ni membresías, y no se desplegó código.

## Estado activo de la base de datos

### Tabla `public.business_memberships`

- RLS está habilitado; FORCE ROW LEVEL SECURITY está deshabilitado.
- Restricción única por `(business_id, user_id)`: impide dos asignaciones del mismo usuario al mismo negocio.
- Roles permitidos: `business_admin`, `employee`.
- Estados permitidos: `active`, `suspended`.
- La FK de negocio usa `ON DELETE RESTRICT`.
- La FK de perfil/usuario usa `ON DELETE RESTRICT`: no permite borrar el perfil mientras exista una membresía.
- Índices por negocio/rol/estado, usuario/estado y creador.
- No hay trigger activo para proteger al último administrador; solo existe el trigger de `updated_at`.

### Políticas y permisos

La política SELECT activa permite a usuarios autenticados leer:
- Sus propias membresías.
- Membresías de cualquier negocio si tienen rol de propietario técnico.
- Membresías de un negocio donde sean administrador.

La tabla no permite a `anon` SELECT. Los usuarios autenticados no tienen INSERT, UPDATE ni DELETE directos. `service_role` sí tiene permisos de lectura y escritura, por lo que el backend privilegiado debe seguir validando cada operación y no exponer rutas genéricas de escritura.

No se encontraron RPC activas de administración de membresías con los nombres usados por la versión candidata. Las RPC de la rama siguen siendo borradores.

## Hallazgos

### MEM-01 — No hay protección activa del último administrador
**Severidad: alta. Estado: preparado solo en la rama.**

La tabla activa permite mantener membresías, pero no tiene un trigger que impida retirar al último administrador activo. La rama incluye:
- Validación del último administrador dentro de las RPC de cambio de rol y suspensión.
- Bloqueo de la fila del negocio antes de modificar la membresía, para serializar operaciones concurrentes.
- Trigger `private.guard_last_active_business_admin` como defensa adicional frente a cambios directos privilegiados.

El trigger y las RPC no están instalados en la base activa. La prueba de concurrencia con dos administradores suspendidos casi al mismo tiempo sigue pendiente en staging.

### MEM-02 — La versión activa no tiene operaciones transaccionales de administración
**Severidad: alta. Estado: preparado solo en la rama.**

La rama incorpora RPC que agrupan cada cambio de membresía y su auditoría dentro de una sola transacción:
- `create_business_membership_assignment`
- `update_business_membership_assignment`
- `suspend_business_membership`
- `reactivate_business_membership`

Las RPC verifican el rol técnico y el bloqueo global del actor, validan el negocio y el usuario de destino, y escriben el evento de auditoría en la misma transacción. La Edge Function candidata autentica el JWT y exige MFA AAL2 al propietario antes de llamar a las RPC.

La base activa no tiene estas RPC; por tanto, la versión candidata de la Edge Function no se debe desplegar antes de instalar y validar el SQL en staging.

### MEM-03 — La reactivación podía competir con un bloqueo global de perfil
**Severidad: media. Estado: corregido en el borrador SQL de la rama.**

La RPC candidata `reactivate_business_membership` comprobaba `profiles.is_blocked` sin bloquear la fila del perfil. Una operación concurrente de bloqueo global podía cruzarse con esa comprobación.

Se añadió `FOR SHARE` a la lectura del perfil de destino. Esto serializa la reactivación con la actualización concurrente del bloqueo global. Aunque la reactivación gane primero, un bloqueo global posterior seguirá prevaleciendo en la resolución de acceso y en las funciones protegidas.

Cambio solo en `database/security/administrative-membership-rpcs-draft.sql`; no se ejecutó en Supabase.

### MEM-04 — No existe una acción de eliminación de membresía o usuario en el panel técnico
**Severidad: media; brecha funcional deliberada que debe definirse.**

En la Edge Function y el panel revisados aparecen acciones para invitar, cambiar rol/cargo, suspender y reactivar. No se encontró acción `delete_member`, `remove_member` ni llamada a `auth.admin.deleteUser`.

La ausencia evita borrar accidentalmente una cuenta que podría tener membresías en otros negocios y conserva las relaciones históricas. Sin embargo, el producto necesita definir qué significa “retirar definitivamente” a una persona de un negocio.

**Recomendación:** separar:
1. Suspender el acceso a un negocio (reversible).
2. Retirar definitivamente la membresía de ese negocio, conservando un registro histórico/auditado y verificando que no sea el último administrador.
3. Eliminar una cuenta global, que debe ser un flujo distinto, con comprobación de todas sus membresías, pedidos, historial, obligaciones de conservación y revocación de sesiones. No borrar Auth automáticamente como efecto secundario de retirar una membresía.

Las FKs `ON DELETE RESTRICT` sobre negocio y perfil impiden borrar los registros padre mientras existan relaciones, lo cual evita una eliminación accidental, pero requiere un proceso explícito y auditado.

### MEM-05 — La política SELECT activa concede al propietario técnico lectura directa de todas las membresías
**Severidad: media. Estado: cambio propuesto en la rama.**

La política activa incluye `private.is_platform_owner()` en el SELECT. El borrador `business-admin-boundaries.sql` propone limitar la lectura directa a la propia membresía y al administrador del negocio. El técnico conserva la gestión a través de la Edge Function con autorización del servidor.

Esta separación reduce el acceso directo a datos de usuarios desde el Data API. Debe verificarse que todos los componentes del panel técnico usen exclusivamente la Edge Function y no dependan de SELECT directo.

### MEM-06 — La columna `job_title` no existe en la tabla activa
**Severidad: alta para la versión candidata. Estado: borrador de migración.**

La tabla activa no tiene `job_title`. Las RPC candidatas y el panel técnico sí usan ese campo. La columna se agrega en `business-admin-boundaries.sql`, y el archivo de RPC depende de esa migración.

Debe respetarse el orden documentado: primero revisar y aplicar la migración de límites administrativos en staging; después aplicar las RPC de membresías; luego desplegar y probar la Edge Function candidata. No aplicar directamente sobre el proyecto activo.

## Revisión de acciones del panel técnico

| Acción | Control de la rama | Estado |
|---|---|---|
| Invitar/asignar | Rol técnico, negocio activo, cuenta no bloqueada, unicidad y auditoría transaccional | Pendiente de staging |
| Cambiar rol/cargo | Rol técnico, validación de rol/cargo, protección del último administrador y auditoría | Pendiente de staging |
| Suspender | Motivo obligatorio, protección del último administrador y auditoría | Pendiente de staging |
| Reactivar | Negocio activo, perfil no bloqueado, motivo y auditoría | Pendiente de staging |
| Eliminar membresía | No existe acción | Definir flujo |
| Eliminar cuenta Auth | No existe acción | Flujo global separado |

## Pruebas obligatorias antes de cerrar

1. Un negocio con un solo administrador: no se puede suspender ni degradar ese administrador.
2. Un negocio con dos administradores: se puede suspender uno, pero nunca ambos por operaciones concurrentes.
3. Dos operaciones concurrentes para degradar/suspender a los dos administradores: una debe fallar y el negocio debe conservar un administrador activo.
4. Usuario bloqueado globalmente: no se puede asignar ni reactivar una membresía.
5. Reactivación y bloqueo global simultáneos: el bloqueo global debe prevalecer al final.
6. Usuario con membresías en dos negocios: suspenderlo en uno no debe afectar el otro.
7. Negocio suspendido: no se puede reactivar una membresía dentro de ese negocio.
8. Empleado no puede elevar su propio rol ni modificar membresías ajenas.
9. Administrador de negocio no puede modificar membresías de otro negocio.
10. Propietario técnico con AAL1 no puede llamar a acciones técnicas; con AAL2 solo puede ejecutar acciones permitidas.
11. Fallo al insertar auditoría debe revertir la modificación de membresía.
12. No debe existir una ruta directa del navegador que escriba en `business_memberships`.
13. Confirmar que el panel técnico no depende de SELECT directo si se retira el permiso global de lectura.
14. Definir y probar retiro de membresía sin eliminar la cuenta global ni perder el historial.

## Orden de implementación recomendado

1. Conseguir un entorno de staging independiente y cuentas de prueba para dos negocios.
2. Revisar `business-admin-boundaries.sql` y sus efectos sobre todos los componentes del panel.
3. Aplicar en staging el límite de lectura y la columna `job_title`.
4. Aplicar las RPC transaccionales y el trigger de último administrador.
5. Desplegar la Edge Function candidata con MFA AAL2.
6. Ejecutar pruebas de concurrencia, aislamiento, bloqueo global y fallos de auditoría.
7. Diseñar por separado la retirada definitiva de membresía y la eliminación global de cuenta.

## Referencia de compatibilidad Supabase

Supabase aplica desde el 30 de octubre de 2026 el cambio para que las tablas nuevas de `public` no queden expuestas automáticamente a Data API. Para las futuras tablas de invitaciones o historial, se deben definir explícitamente GRANT, RLS y políticas; no asumir exposición automática. <https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically>

## Conclusión

La rama ya plantea controles importantes para proteger el último administrador, registrar cada cambio junto con su auditoría y separar la gestión técnica de la lectura directa de membresías. Sin embargo, no están activos en Supabase. El diseño debe conservar la diferencia entre suspender, retirar una membresía y eliminar una cuenta global. No se recomienda desplegar las RPC ni la Edge Function hasta disponer de staging y superar las pruebas de concurrencia y aislamiento.
