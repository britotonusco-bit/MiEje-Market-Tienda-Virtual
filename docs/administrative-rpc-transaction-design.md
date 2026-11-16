# Diseño de operaciones administrativas transaccionales

Fecha: 16 nov 2026  
Rama de trabajo: `correcciones-funcionales`

## Propósito y límites

Este documento define el diseño previo a implementar RPC administrativas. No es una migración ejecutable.

No se aplicó SQL, no se modificó Supabase, no se enviaron invitaciones, no se alteraron usuarios o membresías y no se desplegó código. La implementación queda pendiente de verificar el esquema real y los permisos efectivos del proyecto independiente.

## Regla general

Las operaciones que modifican filas de PostgreSQL y sus eventos de auditoría deben ocurrir dentro de una sola transacción. Si falla la escritura de auditoría, la modificación principal también debe revertirse.

Las llamadas externas, como el envío de correo de invitación, no forman parte de una transacción PostgreSQL. No se debe simular atomicidad entre la base de datos y el proveedor de correo.

## Arquitectura propuesta

1. La Edge Function autentica al usuario con `auth.getUser(token)`, verifica que el perfil no esté bloqueado, exige `platform_owner` y valida MFA `aal2`.
2. La Edge Function valida los datos de entrada y llama una función SQL con una cuenta de servicio que nunca se expone al navegador.
3. La función SQL vuelve a comprobar los requisitos críticos de negocio y el actor recibido: perfil existente, no bloqueado y rol técnico correcto. La autorización no debe depender solo de que el navegador o la Edge Function hayan enviado un identificador.
4. La función SQL modifica las filas y escribe `audit_logs` dentro de la misma transacción.
5. La función SQL no debe conceder permisos a `PUBLIC`, `anon` ni `authenticated`. El permiso de ejecución se limita al rol servidor previsto.
6. Preferir `SECURITY INVOKER`. No añadir `SECURITY DEFINER` para resolver errores de permisos. Si una función requiere privilegios elevados por una razón demostrada, documentar el motivo, fijar `search_path` vacío y calificar todos los objetos con su esquema.
7. La función devuelve un resultado explícito: actualizado, no encontrado, conflicto de estado, actor no autorizado o error. No debe ocultar fallos de auditoría.

### Exposición de funciones y tablas

Antes de elegir la ruta RPC, confirmar qué esquemas están expuestos en Data API y cómo se invocarán las funciones desde Edge Functions. Una función en un esquema no expuesto no estará disponible por la ruta REST normal. Si se usa una función en `public`, sus permisos EXECUTE deben restringirse expresamente; estar en un esquema expuesto no significa que deba ser pública.

Además, desde el 30 de octubre de 2026 las tablas nuevas de `public` no quedan expuestas automáticamente a Data API en los proyectos existentes. Los GRANT de tablas y el RLS deben diseñarse por separado; los permisos de ejecución de funciones también se controlan por separado. No agregar GRANT genéricos para resolver errores. Referencia: https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically

## Operaciones que deben ser atómicas

### A. Cambiar rol o cargo de una membresía

Contrato lógico propuesto:
- Entrada: identificador de membresía, nuevo rol permitido, cargo, actor técnico.
- Bloquear la fila del negocio con `FOR UPDATE` para serializar cambios administrativos dentro de ese negocio.
- Bloquear y leer la membresía objetivo.
- Comprobar que el negocio y la membresía existen y que el estado permite la operación.
- Impedir retirar o cambiar el último rol de administrador activo.
- Actualizar rol/cargo y registrar en auditoría el valor anterior y el nuevo.
- Confirmar ambos cambios juntos.

### B. Suspender una membresía

Contrato lógico propuesto:
- Entrada: membresía, motivo obligatorio, actor técnico.
- Bloquear primero la fila del negocio y después la membresía.
- Si se trata de un administrador activo, contar los demás administradores activos bajo el mismo bloqueo.
- Rechazar la operación si deja el negocio sin administrador activo.
- Actualizar estado y motivo; insertar auditoría con el motivo.
- Si la auditoría falla, revertir la suspensión.

### C. Reactivar una membresía

Contrato lógico propuesto:
- Entrada: membresía, motivo obligatorio, actor técnico.
- Bloquear negocio y membresía.
- Comprobar que el negocio continúa activo en el momento de confirmar la operación.
- Reactivar y registrar auditoría dentro de la misma transacción.
- Rechazar si el negocio está suspendido o cerrado.

### D. Cambiar estado del negocio

Contrato lógico propuesto:
- Entrada: negocio, estado permitido, motivo y mensaje público cuando corresponda, actor técnico.
- Bloquear la fila del negocio.
- Comparar el estado anterior y el solicitado para detectar solicitudes repetidas o cambios concurrentes.
- Actualizar estado y datos de suspensión.
- Registrar estado anterior, nuevo estado y motivo en auditoría.
- Confirmar en una sola transacción.

Debe definirse funcionalmente si `closed` es reversible antes de implementar la operación.

### E. Moderar contenido

Contrato lógico propuesto:
- Entrada: contenido, decisión aprobada/rechazada, nota, actor técnico.
- Bloquear la fila del contenido.
- Guardar el estado de moderación anterior.
- Aplicar decisión; el rechazo debe retirar la publicación.
- Registrar auditoría con valores anterior y nuevo.
- Evitar que una decisión concurrente sobrescriba silenciosamente otra.

### F. Crear negocio

La inserción del negocio y su evento de auditoría deben ser atómicos. El técnico solo crea la ficha base; no configura los datos comerciales de la tienda.

## Invitaciones: flujo durable, no transacción distribuida

El envío de correo no puede revertirse si falla una escritura posterior en PostgreSQL. Diseño recomendado:

1. Crear un registro de invitación pendiente con identificador idempotente, negocio, correo normalizado, rol, cargo, actor y estado.
2. Aplicar una restricción única que impida invitaciones duplicadas activas para la misma combinación de negocio y correo.
3. Para cuentas existentes, consultar el perfil y estado Auth; rechazar explícitamente perfiles bloqueados. No asignar automáticamente acceso a una cuenta no confirmada sin un flujo definido de confirmación/recuperación.
4. Para cuentas nuevas, enviar el correo desde el servidor después de guardar la solicitud pendiente.
5. Si el proveedor confirma el envío, cambiar el estado de invitación a enviada. Si falla, conservar el estado pendiente/error y permitir reintento controlado.
6. Crear o activar la membresía con una operación idempotente que valide el estado del negocio y del usuario.
7. Auditar cada transición de estado de la invitación.
8. No reenviar correo ni crear otra membresía por un reintento del mismo identificador.

Estados sugeridos: `pending`, `sending`, `sent`, `accepted`, `failed`, `expired`, `cancelled`. Definir los estados exactos y las transiciones permitidas antes de crear la tabla.

La invitación a un usuario existente debe ser un flujo de asignación distinto al correo de invitación de una cuenta nueva. El sistema debe comunicar con claridad cuál de los dos casos ocurrió.

## Pruebas de aceptación antes de producción

1. Error provocado al insertar auditoría: ni la mutación ni el evento quedan parcialmente aplicados.
2. Dos solicitudes simultáneas para suspender administradores distintos: nunca se elimina el último administrador activo.
3. Cambio de rol simultáneo con suspensión: resultado serializado y consistente.
4. Reactivación concurrente con suspensión/cierre del negocio: no se activa membresía en negocio inactivo.
5. Dos moderaciones simultáneas: una detecta conflicto o se ejecuta en orden serial, con auditoría correcta.
6. Reintento de la misma invitación: no duplica membresía ni correo.
7. Usuario existente bloqueado: no recibe membresía.
8. Correo enviado y fallo posterior: queda un estado recuperable, sin perder la trazabilidad.
9. Usuario sin MFA AAL2 o sin rol técnico: la Edge Function rechaza la operación.
10. Llamada directa a RPC por `anon` o `authenticated`: permiso denegado.
11. Revisión de grants, RLS y Security Advisor después de aplicar cambios en un entorno de ensayo.

## Bloqueos previos a escribir SQL ejecutable

- Verificar las definiciones actuales de `audit_logs`, `businesses`, `business_memberships`, `profiles` y `business_content_pages` en el proyecto independiente.
- Verificar claves, índices únicos, tipos de identificadores, columnas obligatorias y restricciones.
- Verificar permisos del rol que ejecutará las funciones y si el esquema destino está expuesto a Data API.
- Verificar el contrato de respuesta que espera la Edge Function.
- Preparar un entorno aislado para pruebas de concurrencia. El proyecto actual no dispone de staging y no debe usarse producción para pruebas destructivas.

## Estado

- Diseño transaccional: documentado.
- SQL ejecutable: no creado.
- Edge Function: no modificada.
- Supabase: sin cambios.
- Pruebas: pendientes.
- Despliegue/fusión: no realizados.


## Verificación de esquema en Supabase independiente — solo lectura

Consulta realizada el 16 nov 2026 sobre el proyecto independiente. No se modificaron datos.

- `audit_logs`: `id` es `bigint GENERATED ALWAYS AS IDENTITY`; `entity_id` es `text`; `details` es `jsonb NOT NULL DEFAULT '{}'`; `business_id` y `actor_id` admiten NULL. La inserción normal puede omitir `id`.
- `business_memberships`: identificadores UUID; restricción única `(business_id, user_id)); roles permitidos `business_admin` y `employee`; estados `active` y `suspended`; índice por `(business_id, role, status)).
- `businesses`: identificador UUID; slug único; estados permitidos `active`, `suspended`, `closed`.
- `profiles`: `id` enlaza con `auth.users`; `platform_role` solo admite `user` y `platform_owner`; existe `is_blocked`.
- `business_content_pages`: UUID; estados de moderación `pending`, `approved`, `rejected`; existen `moderated_by` y `moderated_at`.
- En `business_memberships` solo se observó el trigger de `updated_at`; el trigger de protección del último administrador del borrador **no está instalado** en el proyecto consultado.
- En `businesses` y `business_content_pages` también se observó únicamente el trigger de `updated_at`.
- Los helpers `private.has_business_role` y `private.business_is_active` existen como `SECURITY DEFINER`, con `search_path` vacío. En la comprobación de permisos, `authenticated` puede ejecutarlos y `anon` no; `service_role` no tiene permiso efectivo de ejecución. Las nuevas funciones servidoras no deben depender de esos helpers sin resolver primero su modelo de permisos.

### Consecuencia para la implementación

El esquema actual sí permite diseñar RPC transaccionales para las operaciones administrativas descritas, pero primero hay que incorporar y revisar el trigger del último administrador en una migración de ensayo. La Edge Function con `service_role` debe ejecutar funciones que usen permisos compatibles con ese rol; no se debe dar acceso global a los helpers privados ni cambiar sus privilegios sin necesidad.

La verificación fue de metadatos, restricciones, índices, triggers y definiciones de funciones. No demuestra que las operaciones se comporten correctamente bajo concurrencia; eso requiere un entorno de ensayo con datos de prueba.


## Revisión del contrato real de la Edge Function — solo lectura

Consulta realizada el 16 nov 2026 sobre `supabase/functions/technical-business-management/index.ts` en `correcciones-funcionales`. No se modificó ni desplegó la función.

### Hallazgos confirmados

- `create_business`: inserta el negocio y luego escribe auditoría en una segunda petición. Si falla auditoría, devuelve `201` con advertencia; el negocio queda creado sin evento correspondiente.
- `invite_member`: para usuarios nuevos envía primero el correo de Auth; después crea/actualiza perfil, crea membresía y registra auditoría en llamadas separadas. Un fallo posterior puede dejar invitación enviada sin membresía o membresía sin auditoría. Para usuarios existentes no se observa una comprobación de `profiles.is_blocked` antes de asignar acceso.
- `update_member_assignment`: lee y cuenta administradores desde la Edge Function, actualiza membresía y registra auditoría por separado. La comprobación del último administrador no está serializada en la misma transacción.
- `block_member`: cuenta administradores, suspende membresía y escribe auditoría en operaciones separadas. Dos solicitudes concurrentes pueden superar la comprobación de último administrador; un fallo de auditoría no revierte la suspensión.
- `unblock_member`: comprueba el estado del negocio antes de reactivar, pero la lectura y actualización no comparten bloqueo transaccional; la auditoría también va separada.
- `set_business_status`: actualiza estado del negocio y después registra auditoría. No compara el estado anterior esperado para detectar una transición concurrente.
- `moderate_business_content`: lee el contenido, actualiza moderación y después registra auditoría. La lectura y escritura no bloquean la fila; una decisión concurrente puede ser sobrescrita.
- `create_platform_financial_record` y `create_payroll_record`: crean el registro y luego intentan auditarlo por separado. Si falla auditoría, el registro financiero queda guardado y la función devuelve advertencia.
- `update_platform_ai_settings`: actualiza configuración y audita por separado; informa advertencia si la auditoría falla.
- `update_platform_public_settings`: actualiza configuración y luego audita. Si falla auditoría, responde con error aunque la configuración ya quedó modificada.
- `resolve_payroll_record` y `resolve_block_request` ya llaman RPC dedicadas. Deben revisarse como ejemplos del patrón transaccional, sin asumir que su implementación o permisos estén validados solo por la llamada desde Edge Function.

### Orden recomendado para cerrar los huecos

1. **Primero:** `update_member_assignment`, `block_member` y `unblock_member`, usando una única operación de base de datos que bloquee la fila del negocio, valide el último administrador, cambie la membresía y escriba auditoría.
2. **Segundo:** `set_business_status` y `moderate_business_content`, con bloqueo de fila, comprobación del estado anterior y auditoría en la misma transacción.
3. **Tercero:** `create_business`, `create_platform_financial_record`, `create_payroll_record` y las dos operaciones de configuración, para eliminar escrituras parciales sin auditoría.
4. **Cuarto:** rediseñar `invite_member` con registro durable/idempotente de invitación y separación entre envío externo de correo y confirmación de membresía. No se debe prometer atomicidad entre PostgreSQL y el proveedor de correo.

### Contrato técnico a conservar

La Edge Function ya valida el JWT, consulta el perfil y exige MFA `aal2` cuando `platform_role` es `platform_owner`. Las nuevas RPC deben recibir el identificador del actor desde el servidor, volver a verificar `profiles.platform_role = 'platform_owner'` y `is_blocked = false`, y limitar EXECUTE al rol de servidor. El cliente no debe poder invocarlas directamente.

La operación de membresía debe bloquear siempre primero la fila del negocio y después la membresía objetivo. Todas las rutas que cambien rol o estado deben respetar ese mismo orden de bloqueo para evitar interbloqueos y carreras. La auditoría debe insertar el estado anterior y el nuevo, sin incluir datos personales innecesarios.

### Estado actualizado

- Esquema real y columnas de las cinco tablas principales: inspeccionados.
- Contrato y secuencia de acciones administrativas de la Edge Function: inspeccionados.
- Huecos de atomicidad: identificados y documentados.
- SQL RPC: todavía no creado ni aplicado.
- Edge Function: sin cambios.
- Supabase: sin cambios.
- Pruebas de concurrencia y fallos de auditoría: pendientes de un entorno aislado.


## Revisión del trigger de último administrador en la rama

El archivo `database/security/business-admin-boundaries.sql` de esta rama ya contiene `private.guard_last_active_business_admin()` y el trigger `guard_last_active_business_admin` sobre `public.business_memberships` para cambios de `role`, `status` o eliminación. El trigger cuenta administradores activos restantes y bloquea la fila del negocio antes de permitir retirar al último.

Esta protección está únicamente en el archivo de la rama: la consulta de metadatos del proyecto Supabase independiente confirmó que el trigger todavía no está instalado allí. No debe considerarse activo en producción.

El trigger es una defensa adicional, no sustituye las RPC transaccionales: no escribe `audit_logs`, no valida el actor técnico, no gestiona la transición de estado del negocio y no resuelve la carrera de reactivación contra una suspensión/cierre del negocio. Las RPC de membresía deben adquirir explícitamente el bloqueo del negocio antes de actualizar la membresía y escribir auditoría en la misma transacción. Mantener el mismo orden de bloqueo en todas las operaciones administrativas reduce el riesgo de interbloqueos.

El trigger está declarado como `SECURITY INVOKER` (sin cláusula `SECURITY DEFINER`) y revoca EXECUTE a `PUBLIC`, `anon` y `authenticated`; el disparador se invoca por la operación de tabla, pero su cuerpo depende de los permisos de lectura del rol que ejecuta la actualización. Antes de habilitarlo, hay que verificar esos permisos con el rol servidor en un entorno aislado.


## Primer borrador de RPC de membresías — revisión de esquema y permisos

Consulta de solo lectura al proyecto independiente, 16 nov 2026:

- La columna public.business_memberships.job_title **no existe todavía en Supabase**. La Edge Function de la rama ya selecciona e inserta esa columna en list_business_members, invite_member y update_member_assignment. Por tanto, desplegar esa Edge Function antes de incorporar la columna produciría errores de esquema en esas acciones.
- La migración de rama database/security/business-admin-boundaries.sql añade job_title, establece su validación de longitud y prepara permisos de lectura. El borrador de RPC también contiene un ADD COLUMN IF NOT EXISTS defensivo; la secuencia debe mantenerse documentada para no tratar el campo como disponible antes de aplicar el cambio de esquema.
- Se verificó que service_role tiene USAGE en public, SELECT/UPDATE sobre businesses y business_memberships, SELECT sobre profiles e INSERT sobre audit_logs. Esto respalda el patrón SECURITY INVOKER para las RPC servidoras, sin conceder ejecución a los roles cliente.

### Borrador preparado

Archivo: database/security/administrative-membership-rpcs-draft.sql.

Incluye tres RPC servidoras:

1. update_business_membership_assignment: cambio de rol/cargo, validación del último administrador, bloqueo de negocio antes de membresía y auditoría atómica.
2. suspend_business_membership: suspensión con motivo, comprobación de último administrador y auditoría atómica.
3. reactivate_business_membership: reactivación solo si el negocio está activo y el perfil de destino no está bloqueado, con auditoría atómica.

Las funciones vuelven a validar que el actor sea platform_owner y no esté bloqueado. El borrador restringe EXECUTE a service_role, usa SECURITY INVOKER y search_path vacío. Se añadió bloqueo FOR SHARE al leer los perfiles del actor y del usuario reactivado/asignado para evitar que un bloqueo global concurrente pase inadvertido durante la operación. El cambio de rol/cargo devuelve sin mutación cuando los valores ya coinciden, evitando auditorías duplicadas por reintentos idénticos.

### Límites pendientes antes de integrar

- El borrador SQL no se ha ejecutado ni probado contra PostgreSQL; la verificación de sintaxis y concurrencia requiere staging.
- La Edge Function aún no invoca estas RPC: sigue usando las operaciones separadas que se identificaron en la auditoría. No se debe considerar corregido el comportamiento hasta adaptar la función y probarla.
- La protección del último administrador del trigger sigue sin estar instalada en Supabase. El borrador de business-admin-boundaries.sql debe revisarse y probarse junto con estas RPC.
- set_business_status también actualiza la fila del negocio. Su futura RPC deberá conservar el mismo orden de bloqueo para que las transiciones de negocio y las operaciones de membresía se serialicen de forma predecible.

### Estado actualizado

- Primer borrador SQL de membresías: guardado en rama.
- Revisión de permisos service_role: verificada por consulta de solo lectura.
- job_title en Supabase: ausente; dependencia confirmada.
- SQL aplicado: no.
- Edge Function adaptada/desplegada: no.
- Pruebas: pendientes de entorno aislado.


## Adaptación de la Edge Function para membresías — solo rama

Se actualizó `supabase/functions/technical-business-management/index.ts` en `correcciones-funcionales` para que las acciones `update_member_assignment`, `block_member` y `unblock_member` llamen respectivamente a `update_business_membership_assignment`, `suspend_business_membership` y `reactivate_business_membership`.

La función ahora interpreta los resultados idempotentes de las RPC y traduce los códigos SQL esperados (`P0002`, `42501`, `23514`, `40001`, `22023`) a respuestas HTTP. Se retiraron de esas tres rutas las escrituras separadas de membresía y auditoría: ambas quedan dentro de la transacción PostgreSQL definida por las RPC.

Verificación realizada: lectura de retorno del archivo en GitHub; se confirmaron los tres nombres de RPC y que las ramas `set_business_status` y `moderate_business_content` permanecen separadas, sin cambios en este paso. No se ejecutó `deno check`, no se desplegó la Edge Function y no se probaron llamadas HTTP porque las RPC aún no están instaladas en Supabase.

**Orden de integración obligatorio:** revisar y aplicar en un entorno de ensayo el esquema y el trigger de `business-admin-boundaries.sql`; revisar y aplicar allí `administrative-membership-rpcs-draft.sql`; solo después probar la Edge Function adaptada. No desplegarla en el proyecto activo mientras esas dependencias no estén instaladas y verificadas.


## Operaciones de negocio y moderación — borrador y adaptación de rama

Se añadieron al mismo archivo SQL dos RPC adicionales:

- `set_technical_business_status`: bloquea la fila del negocio, valida el actor técnico, normaliza motivo y mensaje público, actualiza estado y datos de suspensión, y escribe auditoría en la misma transacción. Mantiene los estados existentes `active`, `suspended` y `closed`; no se ha cambiado la regla funcional sobre si `closed` puede reabrirse.
- `moderate_business_content_transactionally`: bloquea la fila de contenido, valida la decisión `approved`/`rejected`, actualiza nota y datos de moderación, retira de publicación el contenido rechazado y registra el cambio en auditoría dentro de la misma transacción. Aprobar no publica automáticamente el contenido, igual que el comportamiento anterior.

La Edge Function de la rama ya invoca ambas RPC en `set_business_status` y `moderate_business_content`. Se añadió validación de UUID para el identificador de negocio y de contenido. Las cinco RPC del borrador usan `SECURITY INVOKER`, `search_path` vacío, revocan ejecución a `PUBLIC`, `anon` y `authenticated`, y conceden ejecución a `service_role`.

Verificación de lectura de retorno: los nombres de las cinco RPC nuevas coinciden con los llamados correspondientes de la Edge Function. Esta comprobación no equivale a compilación TypeScript ni a ejecución SQL. La función también contiene otras RPC preexistentes para nómina y solicitudes de bloqueo, que no forman parte de este borrador.

Pendiente: pruebas de errores, auditoría y concurrencia en staging; revisión final del contrato de respuesta; integración y despliegue solo después de instalar y verificar las migraciones en un entorno aislado. El proyecto Supabase activo sigue sin cambios.


## Invitaciones y asignación de integrantes — revisión y cambio en rama

### Hallazgos verificados

- La función `private.handle_new_auth_user()` ya se ejecuta después de insertar un usuario en `auth.users` y crea `public.profiles` usando `raw_user_meta_data.display_name`. La Edge Function no debe volver a insertar manualmente el perfil: eso duplicaba trabajo y abría una ventana de carrera innecesaria.
- `profiles` contiene `platform_role`, `is_blocked` y `display_name`. La nueva RPC exige que el perfil del destinatario exista y no tenga bloqueo global antes de asignarle acceso.
- `business_memberships` tiene unicidad por negocio/usuario y campos `role`, `status`, `blocked_reason`, `created_by`; `job_title` aún no está en la base activa y se añade en el borrador SQL que depende de la migración de límites de administrador.
- El flujo anterior enviaba primero el correo y después hacía inserciones separadas en perfil, membresía y auditoría. Si fallaba la última escritura, podía quedar una cuenta Auth sin asignación o una membresía sin evento de auditoría.

### Cambio preparado en la rama

Se añadió `create_business_membership_assignment` a `database/security/administrative-membership-rpcs-draft.sql`. La RPC bloquea el negocio, valida al actor técnico, valida el perfil destinatario y su bloqueo global, evita duplicar una membresía y escribe la membresía más el evento de auditoría en una sola transacción. Usa `SECURITY INVOKER`, `search_path` vacío, revoca ejecución a roles cliente y concede `EXECUTE` solo a `service_role`.

La acción `invite_member` en `supabase/functions/technical-business-management/index.ts` ahora:

1. Valida el identificador del negocio, correo, rol, nombre y cargo.
2. Busca la cuenta existente con paginación limitada. Si llega al límite sin completar la búsqueda, se detiene y no asume que el correo está libre.
3. Para una cuenta nueva, usa `inviteUserByEmail`. Para una cuenta existente sin correo confirmado, usa el flujo `auth.resend` de tipo `signup`; para una cuenta confirmada no envía un correo innecesario.
4. Llama a la RPC para crear la asignación y su auditoría de forma atómica.
5. Devuelve un error recuperable si Auth envió el correo pero la asignación no pudo terminar. La cuenta no debe volver a crearse; el administrador puede reintentar la misma asignación.

Se retiraron de esa acción las inserciones directas en `profiles`, `business_memberships` y `audit_logs`. La función existente que crea perfiles automáticamente permanece como responsable de crear el perfil inicial.

### Configuración de correo pendiente de comprobar

Supabase documenta que el SMTP predeterminado de proyectos hospedados no está destinado a producción y limita los destinatarios a direcciones autorizadas del equipo de la organización. Si MiEje Market sigue usando ese SMTP, eso puede explicar por qué los correos de invitación no llegan a destinatarios externos. No se ha inspeccionado ni modificado la configuración SMTP del proyecto. Antes de probar invitaciones reales, revisar SMTP personalizado, remitente/dominio y límites de envío.

También hay que comprobar que la URL de `aceptar-invitacion.html` esté incluida en las Redirect URLs permitidas de Auth. Si no está permitida, Supabase puede ignorar `redirectTo` y usar la Site URL configurada.

### Límites y pruebas pendientes

- La llamada de correo de Auth y la transacción PostgreSQL no pueden ser una sola transacción distribuida. Si Auth crea el usuario y luego falla la asignación, el flujo deja un usuario pendiente en Auth; el reintento detecta la cuenta y puede volver a enviar la confirmación antes de finalizar la asignación. Una tabla outbox de invitaciones con estado y reintentos sería una mejora posterior si se necesita recuperación automática sin intervención.
- Aún no se ha compilado ni desplegado la Edge Function y las RPC no están instaladas en Supabase.
- Probar en staging: usuario nuevo, usuario existente confirmado, usuario existente sin confirmar, perfil globalmente bloqueado, negocio suspendido, membresía duplicada, SMTP rechazado, fallo de auditoría y dos solicitudes simultáneas.
- Confirmar la URL de redirección permitida y la configuración SMTP antes de cualquier envío externo.

Estado: borrador SQL y Edge Function modificados solo en `correcciones-funcionales`; Supabase activo sin cambios.
