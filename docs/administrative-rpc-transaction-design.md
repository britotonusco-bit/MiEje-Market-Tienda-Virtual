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
