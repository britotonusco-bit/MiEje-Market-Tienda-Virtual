# Paquete de integración — MiEje Market Independiente

**Estado: preparado para staging; NO aprobado para producción.**  
**Proyecto objetivo:** Supabase independiente `cqixlrwbqatbhzmpygiz` (`sa-east-1`).  
**Rama:** `correcciones-funcionales`.

Este paquete ordena los borradores existentes y define cómo probarlos. No aplica cambios por sí mismo. No ejecutar estos archivos en producción ni desde SQL Editor del proyecto live sin aprobación explícita.

## 1. Antes de empezar

1. Crear un proyecto Supabase de ensayo separado. No usar el proyecto original ni el proyecto independiente con datos reales como entorno de pruebas.
2. Confirmar el ref y región del proyecto de ensayo. Comprobar que no sea `ibnwejpbntvoujdawkwh` ni el proyecto de producción `cqixlrwbqatbhzmpygiz`.
3. Guardar una copia/backup recuperable del esquema y datos del entorno de ensayo.
4. Cargar únicamente datos ficticios: dos negocios activos (A y B), uno suspendido, administrador A, empleado A, administrador B, cliente A, cliente B y propietario técnico con MFA.
5. Ejecutar primero `00-preflight.sql` y guardar sus resultados.
6. Si alguna dependencia base falta, detenerse y corregirla antes de seguir. No improvisar cambios en producción.

## 2. Orden de aplicación en staging

**Importante:** el listado de abajo reemplaza el orden preliminar anterior. Incluye los módulos de inventario, métodos de pago, gastos, membresías y limpieza que no estaban en aquella secuencia.

Cada archivo es una unidad independiente. Ejecutar uno a uno, revisar el resultado y detenerse si hay un error.

| Orden | Archivo | Motivo/dependencia |
|---:|---|---|
| 1 | `database/platform/platform-public-settings-draft.sql` | Crea la configuración global que consume `get-platform-public-settings`, que lee únicamente los campos públicos permitidos con credenciales de servidor. |
| 2 | `database/security/business-admin-boundaries.sql` | Establece primero los límites RLS, grants, columnas, membresías y estados de pedido usados por los demás módulos. |
| 3 | `database/security/administrative-membership-rpcs-draft.sql` | Requiere `business_memberships.job_title` creada en el paso 2; crea las RPC transaccionales que invoca la Edge Function técnica. |
| 4 | `database/platform/platform-finance-payroll-draft.sql` | Crea tablas y RPC de finanzas/nómina de plataforma; depende de perfiles, negocios y auditoría base. |
| 5 | `database/ai/ai-settings-draft.sql` | Crea configuración IA por negocio y global; requiere helpers de membresía, perfiles y auditoría. |
| 6 | `database/security/access-block-requests-draft.sql` | Requiere helpers, membresías y la protección de último administrador del paso 2. |
| 7 | `database/security/storage-policy-fix.sql` | Corrige políticas de Storage usando los helpers y el modelo de permisos del paso 2. |
| 8 | `database/customers/customer-account-migration.sql` | Crea `orders.customer_user_id` y favoritos; debe preceder al checkout idempotente y al historial. |
| 9 | `database/inventory/inventory-movements-draft.sql` | Crea el registro de movimientos y el RPC de ajuste; conserva referencias de productos en pedidos, valida que cada línea pertenezca al mismo negocio y protege los snapshots históricos. |
| 10 | `database/security/business-payment-methods-atomic-draft.sql` | Después del paso 2; revoca escrituras directas de métodos de pago y exige usar su RPC desde el panel. |
| 11 | `database/inventory/checkout-inventory-lock-order-draft.sql` | Después de inventario y límites de negocio; sustituye el checkout base y etiqueta movimientos de venta. |
| 12 | `database/orders/checkout-idempotency-draft.sql` | Depende de clientes, métodos de pago, `create_public_order` del paso 11 y `extensions.digest`. Configura las políticas del historial/favoritos e incorpora idempotencia y límite de solicitudes; el paso 8 es la única fuente de verdad del esquema de clientes. |
| 13 | `database/orders/order-financial-access-draft.sql` | Después del checkout; usa `customer_user_id` y `payment_method_name`, y restringe columnas financieras para roles autenticados. |
| 14 | `database/orders/cancellation-flow-draft.sql` | Depende de estados canónicos, helpers, tabla de solicitudes y trigger; requiere inventario para registrar devoluciones y bloquea cancelaciones automáticas de pedidos históricos con productos sin referencia. |
| 15 | `database/orders/refund-flow-draft.sql` | Después de cancelaciones y finanzas; registra el reembolso externo ya realizado, no transfiere dinero. |
| 16 | `database/finance/expense-receipts-storage-draft.sql` | Crea el bucket privado requerido por la RPC de comprobantes. |
| 17 | `database/finance/business-expense-audit-draft.sql` | Después del paso 16 y de los límites de negocio; sustituye escrituras directas por RPC auditadas. |
| 18 | `database/jobs/job-application-consent-draft.sql` | Añade versión y fecha de aceptación a postulaciones existentes; requiere que el esquema base de vacantes ya esté instalado. |
| 19 | `database/maintenance/job-application-cleanup-draft.sql` | Después del paso 18; actualiza la RPC de registro con consentimiento versionado y prepara la limpieza de sesiones vencidas. |
| 20 | `database/jobs/job-application-review-audit-draft.sql` | Después del esquema base de vacantes; valida el catálogo de estados, limita UPDATE del administrador a estado/notas y genera revisor/fecha mediante trigger en PostgreSQL. |



**Paso adicional obligatorio para bases que ya tenían productos:** después del paso 9 y antes de permitir ventas/ajustes, revisar y ejecutar con autorización `database/inventory/inventory-ledger-baseline-draft.sql`. Crea una única línea base para cada producto preexistente con existencias mayores que cero y sin movimientos. Después ejecutar la consulta de solo lectura `database/inventory/verify-inventory-ledger.sql`; las diferencias deben investigarse, no corregirse insertando movimientos arbitrarios.

La normalización histórica de estados y la función `private.enforce_order_status_transition()` quedan centralizadas en el paso 2 (`business-admin-boundaries.sql`). El paso 11 solo sustituye el checkout y registra movimientos de venta; no vuelve a definir el trigger ni repite la conversión. La normalización se ejecuta en una transacción y desactiva el trigger anterior únicamente durante esa conversión.

El paso 8 (`customer-account-migration.sql`) es la única fuente de verdad para `orders.customer_user_id`, su índice y la tabla `customer_favorites`. El paso 12 solo configura las políticas de favoritos y las políticas de lectura necesarias para el historial; ya no vuelve a crear columnas, índices ni la tabla.

Los pasos 1, 3, 4, 5, 6, 7, 18 y 20 son módulos independientes en cuanto a tablas, pero se ordenan aquí para que los helpers y contratos de permisos estén disponibles antes de conectar sus Edge Functions/paneles. El paso 10 debe preceder a la habilitación del flujo de checkout definitivo.


### Endurecimiento MFA del propietario: etapa separada y condicionada

`database/security/owner-mfa-rls.sql` NO forma parte de la primera pasada SQL. Solo aplicarla después de que:
- la interfaz MFA esté publicada en el entorno de ensayo;
- `technical-business-management` desplegada en ese entorno exija AAL2 antes de cada acción sensible;
- el inicio de sesión del propietario, el TOTP y la recuperación estén probados;
- se haya confirmado que no existe una vía de acceso técnico que dependa de un JWT AAL1.

Aplicarla antes de cumplir estas condiciones puede bloquear el acceso del propietario sin que el flujo MFA esté disponible.

## 3. Funciones Edge y configuración

Después de aplicar las migraciones necesarias en staging, desplegar desde esta misma revisión de código, no desde `main`. En la consulta actual, el proyecto independiente tiene seis funciones activas; `get-platform-public-settings` y `cleanup-job-application-data` existen en la rama pero todavía no aparecen desplegadas. Las seis activas también deben actualizarse a la revisión probada:
- `technical-business-management` (MFA/AAL2);
- `resolve-my-access`;
- `create-public-order` (idempotencia y clave publishable);
- `get-public-storefront`;
- `track-public-order`;
- `create-job-application`;
- `get-platform-public-settings` (no está desplegada en el proyecto activo).
- `cleanup-job-application-data` solo después de aplicar y probar la migración 19; configurar su ejecución controlada por separado.

Usar `supabase/config.toml` de esta rama para los valores `verify_jwt`. Antes de desplegar, comprobar secrets del proyecto de ensayo. Nunca copiar ni mostrar service-role keys. No enviar invitaciones ni correos a usuarios reales.

La URL de invitación no se debe probar contra GitHub Pages de producción: `main` aún usa el proyecto Supabase antiguo. Preparar un sitio de ensayo con `supabase-config.js` apuntando al proyecto de ensayo y permitir su URL exacta en Auth Redirect URLs.

## 4. Verificación después de SQL

Ejecutar `verify-integration-package.sql`. Debe terminar sin excepciones. Guardar la salida junto con los resultados de las pruebas manuales. Si falla, detener despliegue y corregir el archivo responsable en la rama.

`verify-order-financial-access.sql` es una comprobación adicional específica de grants financieros; ejecutarla después de `order-financial-access-draft.sql`.

## 5. Pruebas funcionales obligatorias

Usar `docs/security-role-test-matrix.md` como matriz principal. Prioridad mínima:

1. **Aislamiento y catálogo público:** admin A y empleado A no leen ni alteran datos de B; admin B no lee A; técnico no obtiene datos comerciales globales desde Data API. Un visitante anónimo puede consultar únicamente las columnas públicas de negocios activos/suspendidos, productos activos de negocios activos y publicaciones aprobadas; ninguna política anónima debe depender de helpers privados.
2. **Finanzas de plataforma y nómina:** solo el propietario técnico con MFA consulta y registra movimientos; los movimientos son inmutables; la nómina pasa una sola vez de pendiente a pagada o cancelada; al marcarla pagada se crea el gasto financiero y la auditoría en una sola transacción. Registrar un pago no ejecuta transferencias.
3. **Membresías, bloqueos e IA:** no se puede retirar, suspender o degradar al último administrador activo; dos operaciones concurrentes no dejan el negocio sin admin. Solo el administrador activo puede solicitar el bloqueo de otro miembro de su negocio; el técnico con MFA puede aprobar o rechazar, y la aprobación suspende solo esa membresía y deja auditoría. El administrador A solo configura la IA de A; el propietario con AAL2 administra la configuración global; empleados y clientes no pueden modificar ninguna configuración.
4. **Checkout:** invitado y cliente; método deshabilitado; producto inactivo; inventario insuficiente; clave repetida; misma clave con payload distinto; dos compras concurrentes por la última unidad.
5. **Historial/favoritos:** cliente A no accede a los datos de B; favorito de producto inactivo se rechaza; eliminar favorito propio funciona; eliminar cuenta conserva pedidos y limpia la relación.
6. **Finanzas de pedidos:** empleado no lee importes ni confirma pagos; admin solo ve su negocio; pagos duplicados y reembolsos duplicados se rechazan.
7. **Cancelación:** solicitud por empleado/admin, decisión solo admin, inventario se restaura exactamente una vez; pedido entregado no se cancela.
8. **Storage:** admin A carga/lee sus archivos; admin B no puede leer, reemplazar ni borrar archivos de A; visitante no lee documentos privados.
9. **Vacantes:** consentimiento, rate limit, expiración/reutilización de sesión, tamaño/tipo, acceso a postulaciones y URLs firmadas.
10. **MFA y acceso:** propietario AAL2; AAL1 rechazado en acciones técnicas; admin/empleado sin permisos técnicos; invitación y recuperación con correos de ensayo.
11. **Regresión UI:** página pública, login, tres paneles, pedidos, pagos, cuenta e invitaciones sin errores de consola ni respuestas 4xx/5xx inesperadas.

No se considera aprobado si solo pasan consultas SQL. Cada prueba debe registrar rol, negocio, acción, resultado esperado, resultado real y evidencia sin datos personales.

## Auditoría de Storage (16 nov 2026)

El informe completo está en [docs/storage-buckets-and-file-access-audit.md](../../docs/storage-buckets-and-file-access-audit.md).

La inspección de solo lectura del proyecto activo encontró:
- `business-assets`: bucket público de 5 MB con PNG/JPEG/WEBP. Las políticas activas de carga/lectura/actualización/eliminación construyen mal el UUID desde `businesses.name`; el borrador `database/security/storage-policy-fix.sql` corrige la ruta usando `storage.objects.name`.
- `job-applications-private`: bucket privado de 5 MB para PDF/DOC/DOCX. La carga usa token firmado temporal desde Edge Function; la lectura usa URL firmada. Falta probar aislamiento A/B y definir validación del contenido real/antimalware.
- `business-expense-receipts`: no existe en el proyecto activo. El panel ya intenta usarlo; debe aplicarse en staging `database/finance/expense-receipts-storage-draft.sql` antes de habilitar la función de comprobantes.

No se encontraron objetos en los dos buckets existentes, así que no hubo pruebas de descarga o reemplazo con archivos reales. No cambiar los buckets activos ni aplicar políticas hasta disponer de staging y completar la matriz de pruebas del informe.
- La Edge Function `cleanup-job-application-data` ya usa el secreto independiente `JOB_APPLICATION_CLEANUP_SECRET` para autenticar la llamada del programador; `SUPABASE_SERVICE_ROLE_KEY` queda solo como credencial interna del servidor. Configurar ambos secretos en staging antes de probar el proceso.

## 6. Criterios de salida para integrar

- Todos los SQL aplicados sin errores en staging.
- Verificador post-migración y verificador financiero aprobados.
- `platform-finance-payroll-draft.sql` añade movimientos financieros y nómina de plataforma; las tablas quedan reservadas a `service_role` y la Edge Function técnica valida propietario y MFA.
- Matriz de roles A/B sin cruces de datos.
- Checkout concurrente y reintentos sin pedidos ni descuentos duplicados.
- Cancelación y reembolso probados con inventario/finanzas ficticios.
- Funciones Edge desplegadas desde el mismo commit probado.
- Auth Redirect URLs, correos y MFA probados en sitio de ensayo.
- Cero errores críticos abiertos.
- Revisión final de diferencias contra `main` y contra el proyecto Supabase objetivo.

Solo entonces preparar el PR de integración. La fusión/publicación y cualquier SQL en producción requieren autorización explícita aparte.

## 7. Archivos del paquete

- `00-preflight.sql`: inventario de dependencias preexistentes y estado previo, solo lectura; no debe exigir que existan tablas que las migraciones crearán.
- `verify-integration-package.sql`: comprobaciones posteriores, solo lectura.
- `verify-order-financial-access.sql`: verificador financiero de pedidos existente.
- `verify-order-financial-access.sql`: verifica grants de pedidos y líneas después del paso 13.
- `docs/security-role-test-matrix.md`: matriz detallada de permisos y pruebas.

## Bloqueos confirmados en la auditoría de pedidos — 14/11/2026

- La Edge Function activa `create-public-order` es versión 3 y no implementa la clave idempotente que ya envía `app.js`. Antes de producción deben aplicarse las migraciones de clientes y checkout idempotente, y desplegarse la Edge Function de esta rama. Hasta entonces, un reintento tras perder la respuesta puede generar pedidos duplicados.
- La función activa de transición de estado y las políticas activas de `orders`/`order_items` conservan un bypass de `platform_owner`. La migración `business-admin-boundaries.sql` contiene la sustitución por membresías activas; el verificador ahora comprueba que no reaparezca el bypass.
- El panel ahora captura y muestra `delivery_tracking` al pasar un pedido a `out_for_delivery`. Esta modificación requiere que la rama se publique junto con las migraciones de permisos; no cambia el sitio publicado.
- La función activa `track-public-order` es versión 1. La versión de la rama agrega `Cache-Control: no-store, private`.
- La base activa no contiene datos de negocio/productos/pedidos para una prueba de compra y entrega real. Las pruebas de concurrencia, aislamiento A/B, cancelación y restitución de inventario siguen pendientes en un entorno de ensayo.

**No desplegar parcialmente:** el código idempotente de la Edge Function depende de las RPC y tablas creadas por las migraciones del paquete. No desplegar esa función antes de aplicar y verificar sus dependencias en un entorno de pruebas.

### RPC que todavía no están instaladas

La consulta read-only confirmó que faltan las RPC de idempotencia, historial de clientes, finanzas del administrador, confirmación de pago recibido, solicitud/decisión de cancelaciones y registro de reembolsos. Los paneles ya llaman a estos procedimientos, pero las funciones no existen en el proyecto activo. Aplicar el orden de migraciones de este documento y ejecutar el verificador antes de considerar operativos esos botones o módulos.

En particular, no confundir las tablas existentes (`orders`, `order_items`, `order_cancellation_requests`) con el flujo completo: sin sus RPC y triggers correspondientes, la interfaz no puede completar esas operaciones de forma segura.


## Auditoría de Edge Functions y procesos automáticos (16 nov 2026)

Informe completo: [docs/edge-functions-and-automation-audit.md](../../docs/edge-functions-and-automation-audit.md).

Hallazgos principales:
- La función técnica activa v6 no exige MFA AAL2; la versión candidata de la rama sí, pero no está desplegada.
- La función pública de métodos de pago activa omite `id` en su consulta y luego intenta devolverlo; la versión de la rama corrige el SELECT.
- El checkout activo v3 no tiene idempotencia. Las RPC de la versión candidata aún no existen en la base activa.
- Las invitaciones y mutaciones activas pueden dejar pasos parciales; la rama usa RPC transaccionales para membresías, creación y suspensión, pero Auth y el envío de correo siguen fuera de la transacción.
- Las postulaciones requieren límite de tamaño para respuestas JSON, inspección real de CV y análisis antimalware.
- La limpieza de sesiones de CV existe solo en la rama y depende de una RPC SQL todavía no instalada.

No se hicieron cambios en Supabase ni despliegues. Mantener los cambios en la rama hasta disponer de staging y completar las pruebas descritas en el informe.


## Auditoría de recuperación, invitaciones y auditoría de actividad (16 nov 2026)

Informe: [docs/account-recovery-invitations-audit.md](../../docs/account-recovery-invitations-audit.md).

Hallazgos principales:
- Una cuenta existente sin correo confirmado puede recibir una membresía, pero el flujo no reenvía automáticamente la confirmación. Falta un proceso seguro de reenvío, expiración y revocación.
- La recuperación de contraseña exige el evento `PASSWORD_RECOVERY`; la rama ahora limpia los parámetros de la URL después de validar el enlace.
- La rama deja de duplicar el correo del usuario en los detalles del evento `panel.login`; `actor_id` ya identifica al actor.
- `audit_logs` no permite escrituras directas desde `anon` o `authenticated`, pero `service_role` sí tiene UPDATE/DELETE y no existe trigger de inmutabilidad. Se requiere definir retención y protección append-only antes de cerrar la auditoría.
- El comentario de `supabase/config.toml` ahora documenta el secreto independiente `JOB_APPLICATION_CLEANUP_SECRET`.

Los cambios de código están solo en `correcciones-funcionales`. No se modificó Auth, no se enviaron correos, no se ejecutó SQL y no se desplegó nada.


## Auditoría de administración de membresías y usuarios (16 nov 2026)

Informe: [docs/membership-administration-audit.md](../../docs/membership-administration-audit.md).

Hallazgos principales:
- La tabla activa tiene RLS, unicidad por negocio/usuario y no concede INSERT/UPDATE/DELETE directos a `authenticated`; sin embargo, su política SELECT todavía permite al propietario técnico leer todas las membresías.
- No hay protección activa del último administrador ni RPC activas para las operaciones transaccionales candidatas.
- La rama prepara creación, cambio de rol/cargo, suspensión y reactivación con auditoría transaccional y protección del último administrador.
- Se añadió `FOR SHARE` a la lectura del perfil de destino en la RPC candidata de reactivación, para serializarla con un bloqueo global concurrente.
- No existe acción de eliminación de membresía ni de usuario Auth en el panel/Edge Function revisados. Debe definirse por separado la suspensión reversible, la retirada histórica de una membresía y la eliminación global de cuenta.
- La tabla activa carece de `job_title`; el paquete candidato depende primero de `business-admin-boundaries.sql`.

El informe detalla pruebas de concurrencia, aislamiento y auditoría. No se ejecutó SQL ni se modificó Supabase; todo sigue en la rama.


## Auditoría de permisos de paneles y aislamiento entre negocios (16 nov 2026)

Informe: [docs/panel-permissions-and-tenant-isolation-audit.md](../../docs/panel-permissions-and-tenant-isolation-audit.md).

Hallazgos principales:
- La base activa mantiene un bypass `platform_owner` en varias políticas RLS que permite lectura global de pedidos, clientes, productos, costos, gastos, pagos, perfiles y membresías.
- Los privilegios UPDATE activos permiten cambiar `business_id` en productos, métodos de pago, gastos y costos; una cuenta administradora de más de un negocio podría intentar trasladar registros entre tiendas.
- Los empleados pueden consultar por Data API columnas de pedidos que la interfaz no muestra, como correo, token de seguimiento e importes; también precios de líneas.
- El DELETE de publicaciones puede eliminar postulaciones vinculadas por una FK `ON DELETE CASCADE`.
- La rama restringe esos permisos mediante políticas por membresía, grants de columnas, triggers y RPC. La migración 13 separa las columnas operativas de las financieras y conserva el historial propio del cliente mediante RPC.

Pruebas de dos negocios, empleados, administradores y clientes siguen pendientes en staging. No se ejecutó SQL ni se modificó el proyecto activo.


## Auditoría estática de funciones SQL y dependencias (16 nov 2026)

Informe: [docs/sql-function-security-static-audit.md](../../docs/sql-function-security-static-audit.md).

Correcciones incorporadas en la rama:
- La normalización de estados históricos y la función de transición quedan centralizadas en `business-admin-boundaries.sql`; el trigger se desactiva solo durante la conversión y se reactiva dentro de una transacción.
- `checkout-inventory-lock-order-draft.sql` ya no repite la normalización ni reemplaza por segunda vez el trigger de estados.
- `business-expense-audit-draft.sql` ahora apunta al nombre real `expense-receipts-storage-draft.sql`.

La revisión estática de las RPC confirmó el uso de `search_path` vacío en las funciones privilegiadas examinadas, validación de sesión/rol en las funciones que admiten usuarios autenticados y ejecución restringida a `service_role` para las operaciones técnicas. La Edge Function obtiene el actor desde `auth.getUser(token)` y exige AAL2 al propietario técnico. Todo sigue pendiente de compilación y pruebas integrales en staging; no se ejecutó SQL ni se desplegó nada.


## Auditoría de integridad de clientes, checkout e inventario (16 nov 2026)

Informe: [docs/customer-checkout-inventory-integrity-audit.md](../../docs/customer-checkout-inventory-integrity-audit.md).

Correcciones en esta rama:
- `customer-account-migration.sql` queda como fuente única de `customer_user_id`, su índice y `customer_favorites`; se retiraron las definiciones duplicadas del paso 12.
- La Edge Function `create-public-order` ya no usa `x-forwarded-for` como fallback de IP; solo acepta `cf-connecting-ip` del proxy de confianza y falla de forma cerrada si falta.
- Se documentó la verificación obligatoria de esa cabecera en staging.

La consulta de solo lectura al esquema activo confirmó que existe la restricción única `products(business_id, id)` requerida por la FK compuesta del registro de inventario. También confirmó que las tablas/columnas nuevas de clientes, inventario e idempotencia todavía no están instaladas. No se ejecutaron migraciones ni se modificó Supabase.


## Auditoría del flujo de pagos, cancelaciones, inventario y reembolsos (16 nov 2026)
Informe: [docs/order-payment-cancellation-refund-inventory-audit.md](../../docs/order-payment-cancellation-refund-inventory-audit.md).

Hallazgos principales:
- La confirmación de pago bloquea el pedido, valida el administrador activo y registra movimiento financiero, estado y auditoría en una transacción.
- La cancelación aprobada actualiza el pedido y restituye inventario de forma atómica; la restitución genera movimientos de inventario.
- El reembolso exige pedido cancelado, pago conciliado, cancelación aprobada y administrador activo. Solo registra un reembolso externo ya realizado; no transfiere dinero.
- Las migraciones incorporan índices únicos parciales para impedir pagos y reembolsos completados duplicados.
- El esquema activo contiene las columnas y relaciones base, pero todavía no tiene esos índices nuevos ni las RPC candidatas.

La revisión estática fue favorable y no requirió modificar las migraciones. Concurrencia, rollback, aislamiento A/B y movimientos de inventario siguen pendientes de pruebas en staging. No se ejecutó SQL ni se desplegó nada.


## Auditoría de llamadas del panel para operaciones de pedidos (16 nov 2026)
Informe: [docs/order-panel-callsite-integration-audit.md](../../docs/order-panel-callsite-integration-audit.md).

Las llamadas de la interfaz para confirmar pagos, solicitar/decidir cancelaciones, registrar reembolsos y consultar finanzas coinciden estáticamente con las firmas SQL candidatas. No obstante, la consulta de solo lectura del proyecto activo no encontró las cinco RPC financieras/de cancelación; por eso esos controles no pueden considerarse operativos todavía. El checkout público tiene validación e idempotencia en el código de la Edge Function, pero requiere pruebas reales de cabeceras, concurrencia y reintentos. No se ejecutó SQL ni se desplegó nada.


## Auditoría de escrituras directas y límites entre paneles (16 nov 2026)

El informe completo está en [docs/direct-write-and-panel-boundary-audit.md](../../docs/direct-write-and-panel-boundary-audit.md).

La revisión de solo lectura encontró:
- El panel técnico canaliza las operaciones privilegiadas mediante `technical-business-management`; falta probar cada rama de esa Edge Function en staging.
- La interfaz y el esquema activo no coinciden en los estados de pedidos: el frontend usa `received/on_the_way`, pero el constraint y trigger activos todavía usan `pending/out_for_delivery`.
- El proyecto activo no contiene las tablas `customer_favorites`, `business_ai_settings`, `inventory_movements` ni `access_block_requests`, aunque los callsites las consumen.
- Faltan varias RPC que invocan los paneles, entre ellas reportes financieros, métodos de pago, ajuste de inventario, comprobantes, pagos de pedidos y cancelaciones/reembolsos. Las RPC de gastos para registrar, pagar y anular sí aparecen.
- Las políticas activas conceden al propietario técnico escrituras generales sobre datos comerciales en algunas tablas; además, varias tablas permiten actualizar identificadores o columnas `business_id`.
- Los privilegios de UPDATE de `orders` están limitados a `status` y `delivery_tracking`, y las postulaciones quedan limitadas al administrador según RLS.

No se ejecutaron migraciones, RPC de negocio, cambios de datos ni despliegues. Las correcciones propuestas deben probarse primero en un entorno de ensayo independiente.


### Revisión del borrador de límites y migración histórica (16 nov 2026)

En la revisión adicional de `database/security/business-admin-boundaries.sql` se corrigieron dos detalles en la rama:
- La conversión de estados desactiva temporalmente los triggers de transición, auditoría y actualización de fecha; así no se crean eventos operativos falsos ni se sobrescribe `updated_at` durante el backfill.
- `private.prevent_business_scope_change()` ahora es `SECURITY INVOKER`; el trigger no necesita privilegios elevados ni un bypass RLS.

Los nombres de los tres triggers de pedidos se cotejaron con el catálogo del proyecto activo. La verificación fue estática y de metadatos; no se ejecutó el SQL ni se modificó la base.


### Compatibilidad de la RPC de gastos (16 nov 2026)

Se añadió al informe de límites entre paneles un hallazgo de firma:
- El panel llama `pay_business_expense` con `p_expense_id`, `p_payment_method` y `p_transaction_reference`.
- En el proyecto activo solo existe la versión de dos parámetros.
- El paso 17 (`business-expense-audit-draft.sql`) reemplaza la firma por la versión de tres parámetros con referencia opcional.

La confirmación de pagos de gastos no debe marcarse como funcional hasta aplicar y verificar el paso 17 en staging, incluyendo efectivo, transferencia/tarjeta y los casos negativos.


### Revisión complementaria de inventario, costos y checkout (16 nov 2026)

El informe de escrituras directas ahora incluye una revisión de inventario, costos, checkout y gastos:
- La RPC de ajuste de inventario y la tabla de movimientos siguen ausentes de la base activa.
- El proyecto activo permite UPDATE directo de `products.inventory`; el borrador de límites revoca ese permiso y reserva los ajustes posteriores para la RPC.
- La Edge Function de checkout invoca tres RPC de idempotencia que no aparecen en el catálogo activo. Solo existe la función antigua `create_public_order`, con contrato y estados distintos.
- El trigger propuesto para movimientos necesita que checkout y devoluciones indiquen el tipo de movimiento para no registrar ventas como ajustes genéricos.
- Se corrigió en el borrador financiero una comparación OLD/NEW que podía bloquear la confirmación de pagos de gastos.
- Guardar producto y costo sigue siendo un proceso de dos solicitudes; puede dejar un guardado parcial si falla la segunda.

No se ejecutó SQL ni se desplegó nada. La comprobación dinámica sigue pendiente de un entorno de staging aislado.


### Revisión complementaria de cancelaciones y devoluciones (16 nov 2026)

El informe también documenta los bloqueos detectados en cancelaciones, reembolsos y restitución de inventario:
- Las RPC `request_order_cancellation`, `decide_order_cancellation` y `complete_order_refund` no existen en la base activa.
- Las tablas de solicitudes, transacciones y detalles de reembolso solo conceden lectura a `authenticated`; no hay escritura directa habilitada.
- Las políticas activas permiten al propietario técnico lectura global de solicitudes y datos de reembolso; el borrador de límites ya restringe estas lecturas al administrador del negocio.
- `order_items.product_id` usa actualmente `ON DELETE SET NULL`, lo que puede romper la referencia necesaria para devolver inventario. El borrador de inventario propone `ON DELETE RESTRICT`.
- El tipo de movimiento `cancellation_return` existe solo en el borrador; no hay una operación activa que restituya stock de forma atómica y única.

No se hicieron cancelaciones, reembolsos, cambios de inventario ni migraciones. La corrección y las pruebas siguen pendientes de staging aislado.


### Seguimiento público e historial de clientes

El historial y los favoritos dependen de las migraciones 8, 12 y 13; no están activos en el proyecto inspeccionado. La función `track-public-order` está desplegada como versión 1 con `verify_jwt=false`, usa un token UUID como credencial de posesión y aún necesita rate limit, minimización de datos y validación del texto de seguimiento. La versión desplegada no coincide con la fuente de la rama. Antes de habilitar esta función al público, incluir en staging las pruebas 1–10 de `docs/customer-auth-session-audit.md` (apartado “Auditoría adicional: historial y seguimiento público”), actualizar la Edge Function desde la rama probada y verificar que no devuelva importes ni texto sensible. No desplegar en el proyecto activo sin autorización expresa.

El seguimiento público también requiere una acción explícita de actualización o un mecanismo de refresco controlado: la interfaz actual consulta solo al enviar el formulario y no se encontró suscripción Realtime ni polling para ese componente. Mantener la consulta protegida por el token privado y no exponer filas completas de pedidos mediante Realtime.


### Notificaciones de pedidos

No hay notificaciones automáticas de pedidos en el proyecto activo: los cambios se guardan directamente desde el panel y solo generan una fila de auditoría `order.status_changed`. No hay outbox, tabla de notificaciones, proveedor de correo/WhatsApp/SMS/push ni suscripción Realtime para pedidos. El enlace `wa.me` es contacto manual, no envío automático. La arquitectura y pruebas recomendadas están en `docs/order-panel-callsite-integration-audit.md`, apartado “Auditoría de notificaciones y comunicación de pedidos”. También se documentó una inconsistencia entre el checkout conectado y textos legales que aún lo describen como demostración local; revisar `docs/customer-data-rights-audit.md`. No implementar ni desplegar proveedores hasta contar con staging y autorización.

El checkout muestra una casilla obligatoria de privacidad, pero el valor no se transmite a la Edge Function ni a la RPC, y no se almacena evidencia en `orders`. La validación del navegador no es evidencia persistente. Revisar el apartado “Evidencia de autorización en el checkout” de `docs/order-panel-callsite-integration-audit.md` antes de habilitar pedidos al público.


## Auditoría de postulaciones y hojas de vida — 16 nov 2026

Informe detallado: `docs/customer-data-rights-audit.md`, apartado “Auditoría de postulaciones laborales, consentimiento y conservación”.

Verificación de solo lectura en Supabase activo:
- RLS está habilitado en postulaciones, sesiones temporales y limitadores.
- La lectura de postulaciones está limitada al administrador activo del negocio asociado; el helper comprueba membresía activa y perfil no bloqueado.
- El bucket `job-applications-private` es privado, con límite de 5 MB y MIME PDF/DOC/DOCX.
- El servidor exige `privacy_consent = true` tanto en Edge Function como en la RPC, y guarda el booleano en la postulación.
- No se encontró evidencia de consentimiento versionada (versión del aviso, fecha/hora específica y finalidades).
- La Edge Function activa está en versión 2 y no coincide completamente con el limitador por acción de la rama `correcciones-funcionales`.
- La limpieza candidata solo cubre sesiones vencidas, archivos huérfanos y filas antiguas del limitador. No elimina CV asociados a postulaciones completadas ni define retención de postulaciones.
- La RPC de limpieza no está instalada, la Edge Function de limpieza no está desplegada y no hay `pg_cron` instalado en el proyecto activo.
- No se ejecutaron pruebas dinámicas A/B ni análisis de archivos reales; no se consultaron datos personales de postulantes.

Antes de habilitar vacantes públicamente, alinear la Edge Function en staging, añadir evidencia versionada de autorización, limitar tamaño/estructura de respuestas, validar el contenido real de CV, probar el aislamiento de negocio y definir retención/eliminación de postulaciones y archivos. No desplegar ni ejecutar migraciones en el proyecto activo.


### Corrección de carga de hojas de vida — 16 nov 2026

En `correcciones-funcionales` se añadió la validación de consentimiento antes de emitir el token de carga, límites para respuestas personalizadas y una comprobación básica de firma binaria del CV antes de registrar la postulación. La función desplegada en Supabase sigue siendo v2: no se desplegó esta corrección. Falta análisis antimalware, evidencia de consentimiento versionada, política de retención y pruebas dinámicas en staging. Detalle en `docs/customer-data-rights-audit.md`.


### Panel de postulaciones: revisión de lectura y descarga — 16 nov 2026

La ruta operativa revisada es `panel-negocio.html` + `panel-live.js`; `panel-admin.html` sigue siendo un prototipo visual. El panel consulta postulaciones con filtro `business_id`, RLS exige membresía activa con rol `business_admin`, y la política del bucket privado restringe la descarga al administrador del negocio activo correspondiente. Los enlaces firmados duran 300 segundos. No se encontró lectura pública para el bucket ni SELECT público de postulaciones. Pendiente: pruebas dinámicas A/B, paginación y generar enlaces solo al pulsar Descargar, además de retención y consentimiento versionado. No se cambió código ni base de datos en esta revisión.


### Descargas de CV bajo demanda — 16 nov 2026

`panel-live.js` ahora genera el enlace firmado de 300 segundos solo cuando el administrador pulsa Descargar, en vez de crear enlaces para todos los CV al cargar la lista. Verificación estática del archivo guardado confirmada; falta prueba real en navegador con cuentas de negocio y archivos de prueba.


### Hallazgo crítico: cambio de estado de pedidos en los paneles — 16 nov 2026

La ruta del panel llama UPDATE directo sobre `orders`, pero el rol `authenticated` no tiene privilegio SQL UPDATE en la tabla activa. Hay política RLS de UPDATE, pero eso no otorga el privilegio; la acción de cambiar estado no puede completarse por la ruta actual. También existe desajuste de estados: checkout y DB usan `pending/out_for_delivery`, mientras la interfaz usa `received/on_the_way`. Productos y costos sí tienen RLS que restringe escritura a `business_admin`; empleados pueden leer pedidos, pero no modificar productos ni costos. Corrección pendiente: RPC transaccional y restringida para cambios operativos, y alineación de trigger/constraint con el flujo acordado. No se cambió código ni base activa. Ver detalle en `docs/order-panel-callsite-integration-audit.md`.


### Auditoría ampliada de paneles — 16 nov 2026

La comparación de llamadas del panel con las funciones SQL activas encontró que solo existen 3 de las 12 RPC invocadas. Faltan nueve, incluidas las de consulta financiera de pedidos, reporte de ganancias, inventario, métodos de pago, confirmación de pagos, cancelaciones y reembolsos. La RPC financiera ausente se llama al iniciar `loadBusinessAdmin()`, por lo que el panel administrativo puede fallar desde el arranque. También se invoca `get-platform-public-settings`, que no aparece entre las seis Edge Functions desplegadas.

Se detectó además exceso de permisos del propietario técnico: RLS le permite modificar filas completas de negocios, administrar métodos de pago, acceder a costos internos y consultar pedidos/datos de clientes de todos los negocios. Esto contradice la separación acordada. Deben sustituirse por acciones técnicas limitadas a cuentas, membresías y estado del negocio, sin acceso comercial transversal. Sin cambios en base ni despliegues. Detalle en `docs/order-panel-callsite-integration-audit.md`.


### Rectificación y nuevos resultados — 16 nov 2026

Se rectifica la conclusión anterior sobre UPDATE de pedidos: aunque el privilegio general de tabla es falso, existen permisos de UPDATE por columna para `status` y `delivery_tracking`; RLS también autoriza miembros activos. El bloqueo confirmado era el desajuste de estados (`received/on_the_way` en la interfaz frente a `pending/out_for_delivery` en DB). Se corrigieron `panel-live.js` y `app.js` en esta rama; verificación estática correcta, sin prueba de navegador ni pedido real.

Las nueve RPC ausentes en Supabase activo ya tienen borradores SQL en el repositorio, repartidos entre pedidos, cancelaciones, reembolsos, inventario, pagos y gastos. No están desplegadas/activas; se debe revisar y probar su orden de aplicación antes de ejecutar. `get-platform-public-settings` también existe como fuente y borrador, pero no está desplegada.

Asesores: protección de contraseñas filtradas deshabilitada; tres tablas RLS sin políticas, pero sin grants a anon/authenticated (internas); 16 FKs sin índices de cobertura y una tabla con múltiples políticas SELECT permisivas. No se modificó Supabase ni Auth. Ver detalle en `docs/order-panel-callsite-integration-audit.md`.


### Auditoría de favoritos, historial y consentimiento del checkout (19 nov 2026)

Informe: [docs/customer-favorites-history-consent-audit.md](../../docs/customer-favorites-history-consent-audit.md).

La revisión estática confirmó que la Edge Function vincula los pedidos autenticados al usuario validado por Auth y que los borradores de favoritos e historial aplican filtros por propietario. Se detectó un bloqueo crítico: el formulario exige la casilla de privacidad, pero el manejador del checkout no transmite su valor; la Edge Function y las RPC tampoco guardan evidencia versionada y fechada. El checkout no debe considerarse completo hasta validar el consentimiento en servidor y persistirlo en el pedido. No se ejecutó SQL ni se desplegó código.


La versión admitida actualmente para el consentimiento del checkout es `privacy-2026-11-19-v1`. Debe coincidir entre `index.html`, `app.js`, `supabase/functions/create-public-order/index.ts` y `checkout-idempotency-draft.sql`. El servidor y la RPC rechazan pedidos sin aceptación; PostgreSQL registra la fecha. La verificación posterior exige las tres columnas y la restricción de coherencia. Véase `docs/customer-favorites-history-consent-audit.md`.

La interfaz de cliente está en `cuenta.html` + `cuenta.js`: implementa registro, inicio/cierre de sesión, historial mediante `get_customer_order_history()` y favoritos mediante `customer_favorites`. Las pruebas funcionales de estas rutas deben ejecutarse con dos cuentas distintas y pedidos de dos negocios en staging. No confundir la ausencia de la llamada en `app.js` con ausencia de la interfaz: la pantalla de cuenta tiene su propio script.

## Aislamiento de clientes y favoritos

La migración `customer-account-migration.sql` requiere comprobar la exposición de `public.customer_favorites` en Data API: RLS y GRANT no exponen automáticamente tablas nuevas. En staging, habilitar solo la tabla necesaria y verificar que sus políticas de SELECT/INSERT/DELETE limitan las filas a `auth.uid()`. El verificador integral ahora inspecciona las definiciones de `get_customer_order_history()`, `private.customer_owns_order(uuid)`, la política de `order_items` y los predicados de favoritos. La auditoría estática está en `docs/customer-favorites-history-consent-audit.md`; las pruebas con clientes A/B y negocios A/B continúan pendientes.


El endpoint `track-public-order` solo debe publicar estado y datos mínimos de seguimiento; actualmente devuelve también `delivery_tracking`, un texto libre introducido desde el panel. Tratarlo como campo público, no introducir datos personales y definir validación de formato antes de cerrar la auditoría. Verificar además la generación impredecible del token de seguimiento en staging.

## Vacantes: evidencia de consentimiento y límites del paquete

El nuevo paso 18 agrega `privacy_consent_version` y `privacy_consent_at` a `job_applications`, conservando los registros históricos sin evidencia versionada. La versión actual es `job-application-2026-11-19-v1`. El paso 19 actualiza `submit_public_job_application` para validar la versión y guardar la marca de tiempo desde PostgreSQL. La Edge Function y el formulario de `app.js` envían la misma versión; la función rechaza valores ausentes o diferentes.

**Dependencias no resueltas:** el repositorio no contiene una migración completa que cree desde cero `job_applications`, `job_application_upload_sessions` y `job_application_rate_limits`, ni la definición SQL de `consume_job_application_rate_limit`. Los pasos 18 y 19 presuponen que esas tablas y la RPC base ya existen con el esquema y permisos esperados. Antes de usar un staging limpio, recuperar y revisar el DDL de origen de las tablas y de la RPC, o preparar migraciones fieles al esquema aprobado. No inventar columnas, constraints, reglas de retención ni el comportamiento del limitador. Además, confirmar que el proxy de staging entrega `cf-connecting-ip`; si no, la Edge Function rechazará las postulaciones de forma intencional en lugar de saltarse el rate limit.

Las respuestas de `create-job-application` llevan `Cache-Control: no-store, private, max-age=0`, `Pragma: no-cache` y `X-Content-Type-Options: nosniff`, para evitar almacenar tokens de carga en cachés compartidas o navegadores.

El verificador integral comprueba RLS, grants, políticas de administrador por negocio, permisos de columnas, privacidad del bucket y privilegios de las RPC. Las pruebas A/B y el análisis antimalware siguen pendientes.


El limitador de `create-job-application` usa solo `cf-connecting-ip`, encabezado establecido por el proxy de borde. La función rechaza la petición si no está disponible; no debe reintroducirse un fallback al primer valor de `X-Forwarded-For` sin demostrar que el proxy lo sanea. El verificador exige que `consume_job_application_rate_limit` sea ejecutable solo por `service_role`.


El paso 20 de vacantes revoca UPDATE a nivel de tabla para `PUBLIC`, `anon` y `authenticated`, concede a `authenticated` únicamente UPDATE de `status` y `admin_notes`, y genera `reviewed_by` desde `auth.uid()` y `reviewed_at` desde PostgreSQL mediante un único trigger. El paso base `business-admin-boundaries.sql` concede solo las dos columnas operativas y no instala un trigger de auditoría duplicado. La migración 20 elimina además el trigger legado si existe. El panel no envía esos metadatos desde el navegador. Aplicar solo después de verificar que la tabla base contiene las columnas esperadas y que la policy RLS `job_applications_business_admin_update` limita la fila al administrador del negocio activo.


**Nota de limpieza:** el endpoint actual procesa sesiones vencidas y sus archivos vinculados; no hace un barrido completo del bucket para localizar objetos sin fila de sesión. Esos posibles huérfanos requieren conciliación separada, no borrado automático indiscriminado.


### Vigencia de tokens de carga de CV — 19 nov 2026

`create-job-application` ya no asume una vigencia fija de 30 minutos para la sesión SQL. Primero solicita el token firmado a Storage, lee su claim JWT `exp` y fija `expires_at` cinco minutos después. Rechaza tokens sin vencimiento válido, ya vencidos o con una vigencia superior a 24 horas. Esto mantiene la sesión de base de datos vigente durante toda la vida del token y deja un margen breve para completar la solicitud; la limpieza de sesiones vencidas no debe ejecutarse antes de ese vencimiento SQL. La función no expone el token si falla la inserción de la sesión. Pendiente: prueba de integración en staging que confirme el vencimiento efectivo del token y que una carga posterior a su expiración sea rechazada.


### Verificación reforzada de inventario — 19 nov 2026

El verificador integral ahora comprueba que `authenticated` y `anon` no puedan escribir directamente en `inventory_movements` ni modificar `products.inventory`; que `adjust_business_inventory` sea `SECURITY DEFINER` con `search_path` vacío; y que la política de lectura del historial limite el acceso a administradores de negocios activos. Ejecutar estas comprobaciones únicamente en staging antes de aprobar las migraciones de inventario.


### Comprobaciones de concurrencia de inventario — 19 nov 2026

El verificador integral también inspecciona las definiciones de `create_public_order` y `decide_order_cancellation`. Comprueba el orden determinista de bloqueos, el descuento de inventario en checkout y la restitución completa durante una cancelación aprobada. Ejecutar en staging y complementar con pruebas concurrentes de carritos y cancelaciones antes de producción.


### Conciliación financiera en COP — 19 nov 2026

El reporte de ganancias filtra pagos y reembolsos completados por `currency='COP'`. El verificador también inspecciona `complete_order_refund` para confirmar que bloquee el pedido, exija pedido cancelado y pago pagado, concilie un único pago completado por el total, exija moneda COP y una solicitud de cancelación aprobada. Ejecutar el verificador en staging después de aplicar el paquete SQL en el orden documentado.


### Conservación de gastos pagados — 19 nov 2026

El flujo de anulación de gastos ahora solo admite registros pendientes. Los gastos pagados no se pueden anular porque el informe de ganancias los excluye cuando pasan a `voided`, lo que alteraría resultados históricos sin una reversión financiera. La condición se aplica tanto en `void_business_expense` como en `private.guard_business_expense_update`, y queda cubierta por el verificador de integración. No se incorpora todavía una RPC para revertir pagos ya efectuados.


### Costos históricos incompletos en reportes

El RPC `get_business_admin_profit_report` ahora devuelve `NULL` en las estimaciones de ganancia bruta y neta si falta el costo histórico de una o más líneas de pedido. Se mantienen `missing_cost_lines` y `complete_cost_data` para identificar la causa. Los componentes de interfaz deben mostrar “Costos incompletos: no se puede calcular la ganancia” cuando esos campos sean nulos, en vez de convertirlos a cero.


**Protección del costo histórico:** el paso 2 también instala `order_item_costs_immutable` y revoca UPDATE, DELETE y TRUNCATE a `service_role` sobre los snapshots de costo. El checkout crea el snapshot mediante INSERT; ningún flujo normal debe reescribirlo o borrarlo.

**Pedidos históricos:** el paso 9 instala `order_items_history_guard`. Las líneas nuevas deben conservar un producto del mismo negocio que el pedido; sus snapshots no pueden modificarse ni eliminarse. La FK `order_items_product_id_fkey` usa `ON DELETE RESTRICT`, por lo que los productos vendidos deben desactivarse en lugar de borrarse. Las líneas antiguas cuyo `product_id` ya sea NULL se conservan para consulta; el paso 14 impide aprobar automáticamente su cancelación porque no es posible reponer inventario con certeza. Deben revisarse manualmente antes de cualquier resolución.

**Contraste de solo lectura con Supabase activo (proyecto independiente):** `public.order_items` existe y actualmente tiene 0 filas; por tanto, la consulta no encontró referencias nulas ni líneas cruzadas entre negocios. Sin embargo, la FK activa `order_items_product_id_fkey` todavía usa `ON DELETE SET NULL`, no `ON DELETE RESTRICT`. La corrección está solo en el borrador de la rama y no se ha aplicado. No se ejecutaron escrituras.


## Aislamiento de operaciones de pedidos

Las RPC `mark_order_payment_received`, `complete_order_refund` y `decide_order_cancellation` deben autorizar al usuario contra el negocio propietario antes de adquirir bloqueos de filas. Después del bloqueo deben comprobar nuevamente que el negocio siga activo y que el usuario conserve el rol de administrador. El verificador integral comprueba el orden de estas validaciones.

En staging, ejecutar pruebas con dos negocios y sesiones distintas: un administrador del negocio A debe ser rechazado al usar IDs del negocio B sin bloquear el pedido ni la solicitud; el administrador de B debe poder completar la operación normalmente. Repetir con solicitudes concurrentes y cambios de membresía/suspensión.
