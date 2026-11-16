# Auditoría de dependencias y orden de migraciones

**Proyecto:** MiEje Market Independiente  
**Rama revisada:** `correcciones-funcionales`  
**Fecha de revisión:** 16 de noviembre de 2026  
**Alcance:** 19 borradores SQL de implementación, 3 scripts SQL de verificación/preflight, README del paquete, historial de migraciones activas, tablas, funciones y triggers del proyecto Supabase independiente.  
**Estado:** auditoría de solo lectura. Ninguna migración fue ejecutada y ninguna Edge Function fue desplegada.

## 1. Resultado general

Los archivos SQL están preparados como borradores independientes, no como una secuencia de migraciones numeradas lista para ejecutar. No deben ejecutarse por orden alfabético ni todos en una sola operación.

En la base activa se encontraron 12 migraciones registradas. La más reciente es `20261112202907_secure_public_job_application_submission`. Los archivos revisados en `database/` todavía no aparecen como migraciones aplicadas en el historial de Supabase.

La base ya contiene las tablas principales de negocios, membresías, productos, pedidos, pagos, costos, gastos, cancelaciones y postulaciones. En cambio, siguen ausentes varias tablas y funciones que los borradores agregan: favoritos de clientes, movimientos de inventario, idempotencia del checkout, ajustes de IA, finanzas de plataforma, nómina y solicitudes de bloqueo.

**Conclusión:** antes de cualquier implementación se debe convertir el conjunto en migraciones versionadas, resolver los puntos de esta auditoría y probarlo en un entorno aislado. La rama actual no equivale a una implementación activa.

## 2. Orden recomendado por dependencias

El repositorio ya contiene `database/integration/README.md` con una secuencia preliminar. Esa secuencia estaba incompleta: omitía inventario, métodos de pago atómicos, gastos, RPC de membresías y limpieza de postulaciones. Se corrigió en la rama para incluir los 18 módulos de primera pasada. El endurecimiento MFA queda como etapa separada.

| Orden | Archivo | Requiere / depende de | Motivo |
|---:|---|---|---|
| 1 | `database/platform/platform-public-settings-draft.sql` | `profiles` y `audit_logs` | Crea la configuración global; su lectura pública la realiza la Edge Function `get-platform-public-settings`, que devuelve solo campos permitidos. |
| 2 | `database/security/business-admin-boundaries.sql` | Esquema base de negocios, membresías, productos, pedidos, costos, gastos, pagos, páginas y postulaciones; helpers de negocio | Establece los límites RLS, grants, columnas y estados canónicos que usan otros módulos. |
| 3 | `database/security/administrative-membership-rpcs-draft.sql` | Paso 2, perfiles, negocios, membresías y auditoría | Depende de `business_memberships.job_title` creada en el paso 2 y crea siete RPC transaccionales invocadas por la Edge Function técnica. |
| 4 | `database/platform/platform-finance-payroll-draft.sql` | Negocios, perfiles y `audit_logs` | Crea el libro financiero de plataforma, nómina y RPCs reservadas a `service_role`. |
| 5 | `database/ai/ai-settings-draft.sql` | Helpers de membresía, perfiles y `audit_logs` | Crea configuración IA por negocio y configuración global privada. |
| 6 | `database/security/access-block-requests-draft.sql` | Helpers, membresías, negocios y protección de último administrador del paso 2 | Crea solicitudes de bloqueo y RPC de resolución técnica. |
| 7 | `database/security/storage-policy-fix.sql` | Buckets existentes y helpers del paso 2 | Repara las políticas de Storage de activos y documentos privados. |
| 8 | `database/customers/customer-account-migration.sql` | `orders`, `auth.users`, `products` | Añade `orders.customer_user_id` y favoritos; debe preceder al checkout idempotente y al historial. |
| 9 | `database/inventory/inventory-movements-draft.sql` | `products`, `order_items`, negocios y helpers | Crea el historial de movimientos, trigger y RPC de ajuste; cambia la FK de producto a `ON DELETE RESTRICT`. |
| 10 | `database/security/business-payment-methods-atomic-draft.sql` | Paso 2 y `business_payment_methods` | Revoca escrituras directas y obliga a guardar métodos mediante la RPC transaccional. |
| 11 | `database/inventory/checkout-inventory-lock-order-draft.sql` | Pasos 2 y 9; costos de producto/pedido y auditoría | Reemplaza el checkout base con bloqueo determinista de inventario y etiqueta movimientos de venta. |
| 12 | `database/orders/checkout-idempotency-draft.sql` | Pasos 8, 10 y 11; tabla de métodos de pago; `extensions.digest` | Añade claves idempotentes, reservas de límite por IP y checkout de clientes. |
| 13 | `database/orders/order-financial-access-draft.sql` | Pasos 8 y 12; tablas financieras existentes | Usa `customer_user_id` y `payment_method_name`; restringe columnas financieras y crea RPCs de historial/finanzas. |
| 14 | `database/orders/cancellation-flow-draft.sql` | Paso 2, estados canónicos, solicitudes y paso 9 | Aprueba/rechaza cancelaciones y devuelve inventario con movimientos registrados. |
| 15 | `database/orders/refund-flow-draft.sql` | Pasos 13 y 14; `financial_transactions`, `refund_details` | Registra un reembolso total que el negocio ya ejecutó externamente; no transfiere dinero. |
| 16 | `database/finance/expense-receipts-storage-draft.sql` | Storage y `business_expenses` | Crea el bucket privado requerido por la RPC de comprobantes. |
| 17 | `database/finance/business-expense-audit-draft.sql` | Pasos 2 y 16; gastos, auditoría y helpers | Revoca escrituras directas y las sustituye por RPC auditadas. |
| 18 | `database/maintenance/job-application-cleanup-draft.sql` | Tablas activas de postulaciones y sesiones de carga | Añade listado de sesiones vencidas y ajusta el registro de postulaciones; coordinar con la Edge Function de limpieza. |

**Etapa separada:** `database/security/owner-mfa-rls.sql` debe aplicarse solo después de publicar y probar en staging la interfaz MFA y la Edge Function técnica con AAL2. Aplicarla antes puede bloquear el acceso del propietario.

Este orden debe transformarse después en migraciones versionadas, cada una con nombre/timestamp y prueba propia. Los archivos actuales bajo `database/` son borradores, no un historial de migraciones listo para ejecutar.

## 3. Dependencias que deben corregirse o consolidarse

### 3.1 Migración de clientes duplicada

`customer-account-migration.sql` y `checkout-idempotency-draft.sql` agregan `orders.customer_user_id`, crean `customer_favorites`, índices y políticas de favoritos.

El segundo archivo usa `IF NOT EXISTS` para parte de estos objetos y vuelve a crear políticas y permisos. Por eso el orden previsto es primero la migración de clientes y luego la de idempotencia. Aun así, conviene eliminar la duplicación y dejar una sola fuente de verdad para columnas, tabla, políticas y grants.

### 3.2 Normalización del estado del pedido duplicada

Tanto `business-admin-boundaries.sql` como `checkout-inventory-lock-order-draft.sql` convierten los estados antiguos `pending` y `out_for_delivery`, cambian el valor por defecto, reemplazan `private.enforce_order_status_transition()` y actualizan la restricción `orders_status_check`.

La base activa sí tiene el trigger `orders_enforce_status_transition`, y se verificó que llama a `private.enforce_order_status_transition()`. Por tanto, el esquema de función coincide. Sin embargo, la normalización está repetida en dos archivos: debe quedar en una sola migración coordinada para evitar mantenimiento duplicado y diferencias futuras entre las dos definiciones.

El archivo de checkout también deshabilita temporalmente el trigger `orders_enforce_status_transition` mientras convierte estados. Ese nombre sí existe en la base activa. La operación debe mantenerse transaccional y probarse con pedidos históricos antes de ejecutarla.

### 3.3 Nombre incorrecto de un archivo de dependencia

El encabezado de `business-expense-audit-draft.sql` indica que depende de `business-expense-receipts-draft.sql`, pero el archivo real se llama `expense-receipts-storage-draft.sql`.

Debe corregirse la referencia para que el paquete de despliegue no apunte a un archivo inexistente.

### 3.4 Exposición de tablas nuevas en Data API

El changelog oficial de Supabase indica que desde el 30 de octubre de 2026 las tablas nuevas de `public` ya no se exponen automáticamente a Data API y GraphQL. Los `GRANT` y las políticas RLS no sustituyen la configuración de exposición.

Antes de habilitar las llamadas del navegador o de las Edge Functions, verificar en Data API cuáles tablas y funciones nuevas deben exponerse. Como mínimo revisar:
- `customer_favorites` (cliente).
- `inventory_movements` (lectura del administrador).
- `business_ai_settings` (administrador).
- `access_block_requests` (solicitud desde panel administrador y resolución técnica).
- `platform_public_settings`, `platform_ai_settings`, `platform_financial_records` y `payroll_records` (solo flujos de servidor/Edge autorizados).

No se deben abrir permisos públicos para resolver un error de exposición. La exposición de API, los grants SQL y RLS son tres controles distintos.

Referencia: https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically

### 3.5 Lectura pública de la configuración global

El borrador deja `platform_public_settings` sin permisos directos para `anon` y `authenticated`, lo cual evita escrituras públicas. La rama incluye `supabase/functions/get-platform-public-settings/index.ts`: usa credenciales de servidor y devuelve solo nombre, descripción, logo, imagen principal y WhatsApp. Sin embargo, esa función no figura en el inventario de Edge Functions activas del proyecto consultado. La lectura está preparada en código, pero todavía debe desplegarse y probarse en staging; además, verificar que la tabla esté disponible para el Data API usado por el cliente de servicio.

### 3.6 Integridad de datos antes de crear índices y cambiar claves

Antes de ejecutar los pasos de inventario, pagos, cancelaciones y reembolsos, agregar consultas de prevalidación para:
- Líneas de pedido cuyo producto ya no exista, antes de cambiar la FK a `ON DELETE RESTRICT`.
- Pagos completados duplicados por pedido, antes de crear el índice único de pago.
- Reembolsos completados duplicados por pedido, antes del índice único de reembolso.
- Solicitudes de cancelación pendientes o aprobadas duplicadas, antes de los índices únicos parciales.
- Estados de pedido distintos de los valores históricos que la migración contempla.
- Gastos con estados o campos de pago que no cumplan las nuevas validaciones.

La ausencia actual de algunos objetos nuevos no demuestra por sí sola que todas las operaciones puedan ejecutarse sin conflictos de datos.

### 3.7 Limpieza de postulaciones: SQL y Edge deben coordinarse

`job-application-cleanup-draft.sql` no solo añade una función para listar sesiones vencidas: también reemplaza `submit_public_job_application` y elimina la fila de sesión temporal después de insertar la postulación.

La Edge Function de limpieza debe desplegarse solo cuando esta RPC y su contrato estén probados. La limpieza de objetos Storage debe comprobar ruta, bucket, vencimiento y vínculo con la postulación. No borrar documentos asociados a solicitudes válidas.

### 3.8 Preflight y documentación de integración corregidos

La primera versión de `database/integration/00-preflight.sql` trataba `platform_financial_records`, `payroll_records` y `access_block_requests` como dependencias preexistentes, aunque los propios borradores las crean. También comprobaba columnas de esas tablas nuevas y una RPC que aún no existía. Eso producía falsos avisos antes de migrar. Se corrigió el archivo para comprobar solo objetos base y dejar la verificación de objetos nuevos a `verify-integration-package.sql`.

Se detectó además que `business-admin-boundaries.sql` ya creaba `business_memberships.job_title`, aunque `administrative-membership-rpcs-draft.sql` volvía a declararla. Se retiró la segunda declaración y se aclaró la dependencia.

El orden de `database/integration/README.md` también estaba incompleto: omitía módulos de inventario, métodos de pago atómicos, gastos, RPC administrativas de membresías y limpieza de postulaciones. Se actualizó para incluirlos y separar MFA como etapa condicionada.

### 3.9 Cobertura del verificador posterior ampliada

La versión inicial de `verify-integration-package.sql` no comprobaba `inventory_movements`, sus triggers, `save_business_payment_methods` ni las siete RPC de `administrative-membership-rpcs-draft.sql`. Se añadieron aserciones de existencia, RLS, triggers y permisos, incluyendo grants por columna para métodos de pago y ejecución exclusiva de las RPC técnicas por `service_role`.

El verificador ampliado sigue pendiente de ejecución en staging: la revisión estática confirma que las comprobaciones apuntan a las firmas presentes en los borradores, pero no demuestra que todas las migraciones compilen ni que los permisos funcionen en runtime. `verify-order-financial-access.sql` continúa cubriendo por separado un subconjunto de grants financieros.

## 4. Permisos previstos por tipo de usuario

| Actor | Acceso previsto tras el paquete |
|---|---|
| Visitante / `anon` | Catálogo público de negocios y productos activos, páginas públicas aprobadas, seguimiento público mediante Edge y envío de pedidos/postulaciones mediante Edge. Sin acceso a tablas internas de idempotencia, finanzas, membresías o postulaciones privadas. |
| Cliente autenticado | Lo anterior, más favoritos propios y su historial mediante RPC. No puede consultar pedidos, favoritos ni datos financieros de otros clientes. |
| Administrador de negocio | Solo su negocio activo: configuración comercial, productos, métodos de pago, páginas/vacantes, pedidos operativos, inventario y finanzas mediante RPC específicas. No puede acceder a otro negocio. |
| Empleado | Solo operaciones permitidas en su negocio: consultar pedidos y líneas sin importes, avanzar estados permitidos y registrar solicitudes de cancelación. No administra métodos de pago, finanzas, personal ni postulaciones privadas. |
| Técnico superior | Administración de negocios, membresías, bloqueos, auditoría y configuración global mediante Edge Function con service role y validación AAL2. No debe recibir por el Data API los datos financieros/comerciales privados de cada tienda. |

### Notas de permisos

- Los RPC de plataforma usan `SECURITY INVOKER` y privilegios de tabla concedidos a `service_role`; por tanto, la Edge Function debe validar identidad, rol y MFA antes de invocarlos. El identificador del actor debe provenir del usuario verificado por el servidor, nunca de un dato libre enviado por el navegador.
- Los RPC de negocio que usan `SECURITY DEFINER` deben conservar `search_path = ''`, validar `auth.uid()` y rol/negocio activo, y revocar `EXECUTE` a `PUBLIC` y `anon`. No se debe conceder `service_role` al navegador.
- La migración financiera restringe columnas de `orders` y `order_items`. Por eso el panel debe consumir las RPC correctas y no depender de consultas directas a importes.
- El técnico no debe recibir permisos amplios sobre tablas comerciales de cada negocio solo para que el panel técnico pueda cargar. Las operaciones técnicas deben permanecer en la Edge Function autorizada.

## 5. Estado comprobado en Supabase

La consulta de solo lectura confirmó:
- Existen las tablas base: `profiles`, `businesses`, `business_memberships`, `products`, `orders`, `order_items`, `business_payment_methods`, `audit_logs`, `business_expenses`, `financial_transactions`, `order_cancellation_requests`, `refund_details`, `product_costs`, `order_item_costs`, `business_content_pages`, `job_applications` y `job_application_upload_sessions`.
- No existen todavía: `customer_favorites`, `inventory_movements`, `private.checkout_idempotency`, `private.checkout_rate_limit_reservations`, `business_ai_settings`, `platform_ai_settings`, `platform_public_settings`, `platform_financial_records`, `payroll_records` ni `access_block_requests`.
- La columna `business_memberships.job_title` tampoco existe en la base activa; la crea `business-admin-boundaries.sql` en el paso 2. El borrador de RPC administrativas antes repetía un `ADD COLUMN IF NOT EXISTS`; se retiró esa duplicación para mantener una sola definición.
- No existen todavía las RPC nuevas de inventario, finanzas de pedidos, historial de clientes, cancelaciones, reembolsos, métodos de pago atómicos, configuración global y asignación/administración transaccional de membresías.
- Sí existen los helpers `private.business_is_active(uuid)`, `private.has_business_role(uuid,text[])`, `private.is_platform_owner()` y el checkout base `public.create_public_order(...)`.
- El trigger de pedidos está activo y apunta a `private.enforce_order_status_transition()`.
- La extensión `pgcrypto` está instalada en `extensions`; el borrador de idempotencia usa `extensions.digest`.

## 6. Plan de validación antes de cualquier despliegue

1. Separar los 19 borradores de implementación en migraciones versionadas, con nombres y orden definitivos. No editar el historial de migraciones ya aplicadas.
2. Consolidar la normalización de estados y retirar duplicación entre los dos archivos que la modifican.
3. Corregir el nombre de dependencia del bucket de comprobantes.
4. Añadir consultas de prevalidación para índices únicos, claves foráneas y estados históricos.
5. Revisar grants por tabla y columna, RLS, políticas de Storage, funciones, triggers, `SECURITY DEFINER/INVOKER`, `search_path` y exposición de Data API.
6. Aplicar el paquete en un entorno de ensayo autorizado y vacío o con datos de prueba controlados; ejecutar cada migración en el orden validado.
7. Probar aislamiento con dos negocios, administrador, empleado, cliente, visitante y técnico; verificar también concurrencia de checkout, última unidad de inventario, cancelación, reembolso y fallo de auditoría.
8. Desplegar las Edge Functions compatibles solo después de que todas sus RPC y tablas existan y pasen pruebas.
9. Verificar cada panel y la web pública con los permisos reales, no solo con el usuario técnico.
10. Preparar un informe de resultados y rollback por migración antes de solicitar autorización para producción.

## 7. Restricciones de esta auditoría

- No se ejecutó SQL de escritura ni se aplicó ninguna migración.
- No se desplegaron ni reemplazaron Edge Functions.
- No se modificó `main`, no se fusionó ningún PR y no se publicó GitHub Pages.
- La base independiente sigue siendo el único proyecto Supabase objetivo para esta nueva implementación.
- Las verificaciones fueron de esquema, historial, definiciones y dependencias estáticas. No sustituyen pruebas funcionales reales en staging.

**Dictamen:** el paquete tiene una base técnica aprovechable, pero todavía no está listo para ejecutarse como lote. Los bloqueos principales son la duplicación de cambios de estado, la dependencia de Data API para tablas nuevas, la referencia incorrecta del archivo de Storage, la necesidad de prevalidar restricciones únicas/FK y la falta de pruebas integrales en staging.
