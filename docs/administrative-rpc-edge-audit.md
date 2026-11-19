# Auditoría de operaciones administrativas, RPC y Edge Functions

**Proyecto:** MiEje Market Independiente  
**Supabase:** `cqixlrwbqatbhzmpygiz`  
**Código de referencia:** rama `correcciones-funcionales`  
**Fecha:** 16 de noviembre de 2026  
**Tipo de revisión:** lectura de solo lectura de la base activa, versiones desplegadas de Edge Functions y código/migraciones de la rama.  
**No se ejecutaron cambios de base de datos ni despliegues.**

## 1. Resultado general

La rama contiene un diseño más seguro para las operaciones técnicas y comerciales que el que está desplegado actualmente. Sin embargo, hay una diferencia importante entre los dos estados:

- **Supabase activo:** Edge Function técnica versión 6; solo existen siete funciones SQL públicas de aplicación relacionadas con las operaciones revisadas.
- **Rama `correcciones-funcionales`:** la Edge Function técnica fue ampliada para exigir MFA AAL2 y delegar mutaciones sensibles a RPC transaccionales. El panel de negocio también utiliza nuevas RPC para inventario, finanzas, pagos y cancelaciones.
- **Las RPC nuevas aún no están instaladas en Supabase activo.** Desplegar el código de la rama sin aplicar primero el paquete SQL correspondiente haría que varias acciones respondieran con errores de función inexistente.

La auditoría confirma que no se debe publicar ni desplegar el paquete por partes. Se necesita una secuencia coordinada, pruebas con cuentas de cada rol y un entorno de ensayo antes de aplicar cambios.

## 2. Diferencias entre las funciones desplegadas y la rama

### 2.1 Edge Functions activas en Supabase

| Función | Versión activa | JWT verificado por gateway |
|---|---:|---|
| technical-business-management | 6 | Sí |
| create-public-order | 3 | No |
| track-public-order | 1 | No |
| resolve-my-access | 2 | Sí |
| get-public-storefront | 2 | No |
| create-job-application | 2 | No |

Las funciones públicas sin verificación JWT no son automáticamente inseguras: las de pedido, seguimiento y postulación aplican validaciones propias y límites de uso. Se deben revisar como endpoints públicos, no como funciones privadas.

### 2.2 MFA del propietario técnico

La versión 6 activa de `technical-business-management` valida el token con `auth.getUser`, consulta el perfil y rechaza perfiles inexistentes o bloqueados. Sin embargo, **no exige nivel de autenticación AAL2** antes de ejecutar las acciones técnicas.

La versión de la rama añade una comprobación de `auth.mfa.getAuthenticatorAssuranceLevel(token)` y rechaza las acciones del propietario técnico si `currentLevel` no es `aal2`. El control está en el servidor, no depende de que la interfaz oculte botones.

**Prioridad crítica:** la protección MFA existe en el código de la rama, pero no se considera activa en Supabase hasta desplegar y probar esa versión. También debe comprobarse que el propietario tenga un factor MFA enrolado y que el flujo de login pueda completar el segundo factor.

### 2.3 RPC técnicas que la rama espera y que no existen todavía en la base activa

La Edge Function técnica de la rama invoca estas 13 funciones:

- `create_platform_financial_record_transactional`
- `create_platform_payroll_record_transactional`
- `resolve_platform_payroll_record`
- `update_platform_ai_settings_transactional`
- `update_platform_public_settings_transactional`
- `create_technical_business_transactional`
- `create_business_membership_assignment`
- `update_business_membership_assignment`
- `set_technical_business_status`
- `suspend_business_membership`
- `reactivate_business_membership`
- `moderate_business_content_transactionally`
- `resolve_access_block_request`

La consulta del catálogo SQL activo no encontró ninguna de esas funciones. Sus definiciones están repartidas entre borradores de migración de la rama.

### 2.4 RPC del panel de negocio que faltan en Supabase activo

El archivo `panel-live.js` utiliza estas operaciones:

| RPC | Estado en Supabase activo |
|---|---|
| `get_business_admin_order_financials` | No existe |
| `get_business_admin_profit_report` | No existe |
| `pay_business_expense` | Existe |
| `void_business_expense` | Existe |
| `attach_business_expense_receipt` | No existe |
| `register_business_expense` | Existe |
| `adjust_business_inventory` | No existe |
| `save_business_payment_methods` | No existe |
| `mark_order_payment_received` | No existe |
| `complete_order_refund` | No existe |
| `request_order_cancellation` | No existe |
| `decide_order_cancellation` | No existe |

**Conclusión funcional:** nueve de las doce RPC únicas del panel de negocio no están presentes en la base activa. Las funciones existentes no significan que el flujo completo esté listo: hay dependencias SQL, permisos y tablas que también deben estar instalados.

## 3. Operaciones del panel técnico activo

La versión activa usa una clave de servicio desde el servidor y comprueba el usuario autenticado y su perfil antes de permitir acciones técnicas. El uso de la clave de servicio debe permanecer exclusivamente en el entorno servidor.

Se identificaron estas operaciones que escriben datos y luego insertan el registro de auditoría como una segunda petición:

- Crear negocio.
- Crear invitación/asignación de miembro.
- Cambiar estado del negocio.
- Suspender membresía.
- Reactivar membresía.
- Aprobar o rechazar contenido.

En esas acciones, la mutación y la inserción en `audit_logs` no forman una sola transacción. Si la primera operación funciona y la auditoría falla, el cambio puede quedar aplicado aunque el endpoint responda con error. Un reintento puede duplicar invitaciones o producir conflictos de estado.

La rama mejora varias de estas operaciones al trasladarlas a RPC que hacen la modificación y la auditoría dentro de una transacción SQL. El borrador es una mejora de diseño, pero todavía necesita pruebas con el rol de ejecución real.

### 3.1 Crear negocio

La versión activa inserta el negocio y después registra el evento `business.created`. Si falla la auditoría, el negocio ya existe.

La RPC de la rama `create_technical_business_transactional` crea solo la ficha básica (nombre, categoría y slug) y registra el evento en la misma transacción. Esto respeta la separación acordada: el técnico crea el espacio del negocio, pero el administrador configura su identidad comercial.

### 3.2 Invitar y asignar usuarios

La versión activa puede enviar una invitación de Auth, crear/actualizar el perfil, insertar la membresía y registrar auditoría como operaciones independientes. Si un paso posterior falla, puede quedar una invitación enviada sin asignación terminada o una membresía sin su evento de auditoría.

La rama mejora la búsqueda del usuario, valida el estado del negocio y delega la asignación a `create_business_membership_assignment`, que verifica el perfil y el bloqueo global, controla membresías duplicadas, bloquea el negocio durante la operación y guarda auditoría en la misma transacción.

**Límite que permanece:** el envío de correo de Auth es un efecto externo y no puede revertirse como parte de una transacción PostgreSQL. Debe existir una forma de reintentar la asignación de la misma cuenta sin crear invitaciones o membresías duplicadas. La rama ya devuelve estados distintos para correo enviado, asignación incompleta y usuario ya asignado; esas rutas necesitan pruebas de integración.

### 3.3 Cambiar rol, suspender o reactivar membresías

El borrador SQL de la rama usa bloqueos de fila y conserva al menos un administrador activo por negocio cuando se cambia o suspende la membresía del último administrador. También impide reactivar una membresía si el negocio está suspendido o cerrado, o si el perfil está bloqueado globalmente.

En Supabase activo no se encontró un disparador equivalente para impedir la suspensión o degradación del último administrador. El código activo de suspensión puede cambiar la membresía y luego auditar, sin una operación transaccional que proteja el conteo concurrente.

**Prioridad alta:** no permitir que una carrera entre dos operaciones deje un negocio sin administrador activo.

### 3.4 Moderar contenido

La versión activa actualiza la publicación y luego inserta la auditoría por separado. Dos decisiones simultáneas pueden sobrescribirse y el resultado de la auditoría puede no reflejar el último estado.

La RPC `moderate_business_content_transactionally` de la rama bloquea la publicación, registra el estado anterior y nuevo y guarda la auditoría dentro de la misma transacción.

## 4. Operaciones financieras de gastos: hallazgo activo

Las tres funciones de gastos presentes en Supabase activo son `SECURITY INVOKER`, requieren una sesión, rechazan al propietario técnico, comprueban negocio activo y rol de administrador, y bloquean la fila para evitar algunos cambios duplicados.

No obstante, la revisión de permisos SQL encontró que `authenticated` conserva INSERT, SELECT y UPDATE directos sobre `business_expenses`. Las políticas RLS permiten insertar y actualizar gastos del negocio propio. El disparador actual limita ciertas modificaciones, pero no reemplaza una autorización completa por operación ni registra auditoría.

Hallazgos concretos:

1. Un administrador puede intentar insertar directamente un gasto sin pasar por `register_business_expense`.
2. La política de INSERT no exige por sí sola que un gasto marcado como pagado tenga método válido y fecha de pago coherente.
3. El disparador de UPDATE permite la transición pendiente → pagado si se completan método y fecha, pero no verifica que el método esté dentro del conjunto permitido.
4. Las funciones activas `register_business_expense`, `pay_business_expense` y `void_business_expense` no insertan directamente un evento de auditoría.
5. No hay un trigger de auditoría activo en `business_expenses`; el trigger encontrado es un guardián de cambios.

El borrador `database/finance/business-expense-audit-draft.sql` aborda esta brecha retirando INSERT/UPDATE/DELETE directos y sustituyéndolos por operaciones controladas que validan el administrador del negocio, bloquean el gasto y registran auditoría en la misma transacción.

**Prioridad crítica:** la interfaz que use una RPC no impide que un usuario llame directamente a la tabla desde la API. Los permisos deben bloquear también la vía directa.

## 5. Pedidos, pagos y métodos de pago

### 5.1 Creación de pedidos

La RPC activa `create_public_order` es `SECURITY DEFINER`, fija `search_path` vacío y solo concede ejecución a `service_role`. La Edge Function pública valida los datos, comprueba que el método de pago esté habilitado para el negocio y luego invoca la RPC. La RPC vuelve a comprobar negocio activo, productos, cantidades, inventario, precios y costos, bloquea filas de productos y realiza pedido, líneas, descuento de inventario y auditoría en una transacción.

Controles positivos:
- no acepta precios enviados por el navegador;
- limita el número de productos y las cantidades;
- bloquea filas de producto para evitar sobreventa concurrente;
- rechaza productos que no pertenecen al negocio o no están activos;
- crea pedido, artículos, costos históricos y auditoría de forma transaccional;
- la función SQL no es ejecutable por `anon` ni `authenticated`.

Brechas que siguen abiertas y ya constan en la auditoría del checkout:
- no hay clave de idempotencia, por lo que un reintento puede crear pedidos duplicados;
- el método de pago se comprueba en la Edge Function antes de llamar la RPC, pero no se bloquea ni revalida dentro de la transacción de creación;
- la función activa guarda el estado inicial `pending`, mientras que el flujo nuevo de la interfaz utiliza `received`; la migración de estados está solo en la rama;
- la RPC no registra consentimiento de privacidad ni versión del aviso.

### 5.2 Rate limit del checkout

La Edge Function obtiene la IP desde `cf-connecting-ip` y, como alternativa, desde el primer valor de `x-forwarded-for`. Si se utiliza el encabezado alternativo sin verificar que proviene de un proxy confiable, el valor podría ser controlado por el solicitante y reducir la eficacia del límite por IP.

Debe verificarse el comportamiento real del gateway y utilizar una fuente de IP confiable. No se debe confiar sin validación en un encabezado enviado directamente por el cliente.

### 5.3 Cancelaciones y reembolsos

Las funciones `request_order_cancellation`, `decide_order_cancellation` y `complete_order_refund` están en borradores SQL y no existen en Supabase activo. Por tanto, el flujo de cancelación y reembolso del panel no está completo en la base activa.

El diseño distingue correctamente:
- solicitud de cancelación por administrador o empleado;
- decisión de aprobación/rechazo por administrador;
- reposición de inventario al aprobar cancelación;
- registro del reembolso únicamente después de que el pago se haya conciliado y el reembolso se haya realizado externamente.

Las RPC no deben describirse como una pasarela que mueve dinero: registran el resultado de una operación de pago/reembolso externa.

## 6. Postulaciones y archivos

La RPC activa `submit_public_job_application` es `SECURITY DEFINER`, fija `search_path` vacío y solo concede ejecución a `service_role`. Comprueba el consentimiento booleano, que la vacante esté publicada/aprobada y que el negocio esté activo. Si hay CV, consume una sesión de carga vinculada al negocio, la vacante y la ruta antes de insertar la postulación.

Esto limita la exposición de la RPC y mantiene el envío público detrás de la Edge Function. Siguen pendientes los hallazgos del informe de privacidad: fecha y versión del consentimiento, verificación del contenido real del archivo, análisis antimalware y política de retención.

## 7. Permisos y modelo de ejecución de las RPC de la rama

Las nuevas RPC administrativas de la rama están definidas como `SECURITY INVOKER`, fijan `search_path` vacío y revocan ejecución de `PUBLIC`, `anon` y `authenticated`, concediéndola a `service_role`. Esto coincide con el flujo de la Edge Function técnica, que invoca esas RPC mediante el cliente servidor con la clave de servicio.

Las funciones reciben `p_actor_id`, pero no deben considerarse seguras por ese parámetro aislado. La defensa depende de que:
- solo `service_role` pueda ejecutar esas funciones;
- la clave de servicio nunca salga del servidor;
- la Edge Function obtenga el usuario mediante `auth.getUser(token)`;
- la Edge Function derive `p_actor_id` del usuario verificado, nunca del cuerpo JSON del cliente;
- la función compruebe el rol técnico y el bloqueo global del perfil;
- MFA AAL2 se compruebe en el servidor antes de ejecutar cualquier acción técnica.

La revisión del código de la rama confirma que el actor se toma del usuario verificado y que la comprobación AAL2 se realiza en el endpoint. Las pruebas deben verificar también los GRANT efectivos después de instalar las migraciones.

## 8. Hallazgos priorizados

| Prioridad | Hallazgo | Estado |
|---|---|---|
| Crítica | MFA AAL2 no exigido por la Edge técnica activa v6 | Corregido en rama; despliegue pendiente |
| Crítica | Nueve RPC del panel de negocio y trece RPC técnicas no existen en la base activa | Borradores en rama; migración pendiente |
| Crítica | INSERT/UPDATE directos de gastos permiten omitir validación/auditoría completa | Borrador de corrección pendiente |
| Alta | Mutaciones técnicas activas y auditoría son operaciones separadas | RPC transaccionales en rama |
| Alta | La versión activa no protege con trigger al último administrador ante concurrencia | Guardián en rama |
| Alta | Invitación por correo y asignación de membresía pueden quedar en estados intermedios | Reintento/reconciliación en rama; pruebas pendientes |
| Alta | La validación del método de pago no se repite dentro de la transacción del pedido | Pendiente |
| Alta | La IP alternativa del rate limit depende de confiar en el proxy que añade el encabezado | Verificación de infraestructura pendiente |
| Media | La moderación activa puede sufrir cambios concurrentes y auditoría separada | RPC transaccional en rama |
| Media | Cambios de estado de pedido usan vocabulario antiguo en la base activa | Migración de estados en rama |

## 9. Secuencia de integración recomendada

No desplegar Edge Functions antes de que sus RPC y permisos estén disponibles. La secuencia debe ser:

1. Preparar un entorno de pruebas independiente con copia de esquema y datos ficticios.
2. Revisar y ordenar las migraciones SQL por dependencias: roles y helpers, permisos de tablas, RPC administrativas, auditoría, inventario, finanzas, métodos de pago, cancelaciones y reembolsos.
3. Aplicar las migraciones en ensayo y verificar las funciones, grants y políticas efectivas.
4. Probar con cuentas separadas: propietario técnico, administrador A, empleado A, administrador B, empleado B y cliente.
5. Probar acciones simultáneas: dos suspensiones de administradores, dos compras del último inventario, doble pago de gasto, doble cancelación, doble reembolso y dos decisiones de moderación.
6. Probar fallos deliberados de auditoría y de envío de correo para confirmar que no quedan cambios parciales sin posibilidad de recuperación.
7. Verificar que un usuario autenticado no pueda llamar directamente a las RPC técnicas ni escribir directamente en gastos.
8. Desplegar Edge Functions compatibles con las migraciones ya verificadas.
9. Ejecutar pruebas de navegador y revisar logs/Advisor antes de autorizar publicación.

## 10. Estado de esta auditoría

- Inventario de RPC activas: revisado.
- RPC esperadas por la rama frente a RPC activas: comparadas.
- Edge Functions desplegadas y versiones: revisadas.
- Permisos de gastos y triggers: revisados.
- Definiciones de RPC sensibles: revisadas.
- Pruebas de integración con usuarios reales: pendientes.
- Pruebas de concurrencia: pendientes.
- SQL de escritura: no ejecutado.
- Edge Functions: no desplegadas.
- `main` y GitHub Pages: sin cambios.

**Conclusión:** el diseño de la rama avanza hacia operaciones transaccionales y controles de MFA, pero todavía no está listo para producción. Primero se debe validar el paquete completo en un entorno de ensayo; no se debe mezclar código nuevo con una base que aún carece de sus RPC dependientes.
