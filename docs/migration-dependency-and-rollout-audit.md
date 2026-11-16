# Auditoría de dependencias y orden de migraciones

**Proyecto:** MiEje Market Independiente  
**Rama revisada:** `correcciones-funcionales`  
**Fecha de revisión:** 16 de noviembre de 2026  
**Alcance:** 17 archivos SQL de preparación, historial de migraciones activas, tablas, funciones y triggers del proyecto Supabase independiente.  
**Estado:** auditoría de solo lectura. Ninguna migración fue ejecutada y ninguna Edge Function fue desplegada.

## 1. Resultado general

Los archivos SQL están preparados como borradores independientes, no como una secuencia de migraciones numeradas lista para ejecutar. No deben ejecutarse por orden alfabético ni todos en una sola operación.

En la base activa se encontraron 12 migraciones registradas. La más reciente es `20261112202907_secure_public_job_application_submission`. Los archivos revisados en `database/` todavía no aparecen como migraciones aplicadas en el historial de Supabase.

La base ya contiene las tablas principales de negocios, membresías, productos, pedidos, pagos, costos, gastos, cancelaciones y postulaciones. En cambio, siguen ausentes varias tablas y funciones que los borradores agregan: favoritos de clientes, movimientos de inventario, idempotencia del checkout, ajustes de IA, finanzas de plataforma, nómina y solicitudes de bloqueo.

**Conclusión:** antes de cualquier implementación se debe convertir el conjunto en migraciones versionadas, resolver los puntos de esta auditoría y probarlo en un entorno aislado. La rama actual no equivale a una implementación activa.

## 2. Orden recomendado por dependencias

Este orden es una propuesta de empaquetado. No significa que se deban ejecutar hoy. Algunas tareas deben consolidarse para evitar repetir cambios sobre pedidos y permisos.

| Orden | Archivo | Requiere / depende de | Motivo |
|---:|---|---|---|
| 1 | `database/security/business-admin-boundaries.sql` | Esquema base: negocios, membresías, productos, pedidos, costos, gastos, pagos, páginas y postulaciones; helpers `private.business_is_active` y `private.has_business_role` | Establece los límites entre técnico, administrador y empleado, permisos de lectura/escritura y reglas del flujo de pedidos. Debe revisarse primero porque cambia políticas y privilegios usados por otros módulos. |
| 2 | `database/security/storage-policy-fix.sql` | Buckets existentes, tablas de negocio y helpers privados | Corrige políticas de Storage para recursos de cada negocio y documentos de postulaciones. Se puede preparar junto al paso 1, pero validar después de los límites de negocio. |
| 3 | `database/customers/customer-account-migration.sql` | `public.orders`, `auth.users`, `public.products` | Añade `orders.customer_user_id` y crea favoritos. Debe preceder al checkout idempotente y al historial financiero del cliente. |
| 4 | `database/inventory/inventory-movements-draft.sql` | `products`, `order_items`, negocios, helpers y membresías | Crea el historial de inventario, triggers y RPC de ajuste. Cambia la FK de producto en líneas de pedido a `ON DELETE RESTRICT`; exige comprobar referencias antes de aplicarlo. |
| 5 | `database/inventory/checkout-inventory-lock-order-draft.sql` | Paso 1 y paso 4; `product_costs`, `order_item_costs`, `audit_logs` | Reemplaza el checkout para bloquear productos en orden estable y etiquetar movimientos de venta. Debe ir después del trigger de movimientos, porque configura los datos que ese trigger registra. |
| 6 | `database/security/business-payment-methods-atomic-draft.sql` | Paso 1 y `business_payment_methods` | Revoca escrituras directas y obliga al panel administrador a guardar métodos mediante `save_business_payment_methods`. Debe estar listo antes de habilitar el checkout final y el panel comercial. |
| 7 | `database/orders/checkout-idempotency-draft.sql` | Paso 3, tabla `business_payment_methods`, `create_public_order` del paso 5 y extensión `pgcrypto` | Añade método de pago histórico, idempotencia, reserva de límite por IP y funciones de checkout para clientes. El proyecto ya tiene `pgcrypto` instalado en el esquema `extensions`, que satisface el uso de `extensions.digest`. |
| 8 | `database/orders/order-financial-access-draft.sql` | Pasos 3 y 7; tablas `financial_transactions`, `business_expenses`, `order_item_costs`, `order_cancellation_requests` | Usa `customer_user_id` y `payment_method_name`; restringe columnas sensibles de pedidos y líneas, y crea RPC financieras e historial de cliente. Su propio encabezado exige ejecutarlo después del checkout idempotente. |
| 9 | `database/orders/cancellation-flow-draft.sql` | Paso 1, estados canónicos de pedidos, tabla `order_cancellation_requests` y paso 4 para registrar devoluciones de inventario | Registra solicitudes y decisiones de cancelación; la aprobación cambia el pedido y devuelve existencias en una transacción. |
| 10 | `database/orders/refund-flow-draft.sql` | Paso 9 y paso 8; `financial_transactions`, `refund_details` | El reembolso requiere una cancelación aprobada y un pago registrado. Solo registra un reembolso externo; no transfiere dinero ni conecta una pasarela. |
| 11 | `database/finance/expense-receipts-storage-draft.sql` | Storage y `business_expenses` | Crea el bucket privado de comprobantes. Debe ejecutarse antes de asociar rutas de comprobantes desde una RPC. |
| 12 | `database/finance/business-expense-audit-draft.sql` | Paso 1, paso 11, tabla `business_expenses`, `audit_logs` y helpers privados | Revoca escrituras directas de gastos y las sustituye por RPC auditadas. Requiere que el bucket exista antes de habilitar `attach_business_expense_receipt`. |
| 13 | `database/ai/ai-settings-draft.sql` | Tabla de negocios, helpers de membresía, perfiles y `audit_logs` | Crea configuración IA por negocio y configuración global. La parte de negocio usa RLS y la global queda reservada al servicio técnico. |
| 14 | `database/security/access-block-requests-draft.sql` | Negocios, perfiles, membresías, helpers y trigger de último administrador del paso 1 | Crea solicitudes de bloqueo que el técnico resuelve. La resolución depende de la protección contra retirar al último administrador activo. |
| 15 | `database/platform/platform-public-settings-draft.sql` | `profiles` y `audit_logs` | Configuración pública global, administrada por Edge Function técnica. Es independiente de los módulos de tienda, pero requiere definir también cómo la web pública leerá esos valores. |
| 16 | `database/platform/platform-finance-payroll-draft.sql` | Negocios, perfiles y `audit_logs` | Crea libro financiero y nómina de plataforma, accesibles mediante la Edge Function técnica. |
| 17 | `database/maintenance/job-application-cleanup-draft.sql` | `job_applications`, `job_application_upload_sessions`, páginas comerciales y Storage privado | Añade consulta de sesiones vencidas y reemplaza la RPC de postulación para retirar la sesión temporal al registrar la solicitud. Debe coordinarse con la Edge Function de limpieza y probarse con archivos reales de ensayo. |

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

`platform-public-settings-draft.sql` deja la tabla sin permisos directos para `anon` y `authenticated`, y solo crea la función de actualización técnica. Eso es adecuado para evitar escrituras públicas, pero el paquete no incluye una función de lectura pública segura.

Antes de implementarlo, identificar cómo la portada obtendrá nombre, descripción, logo, imagen principal y WhatsApp. La solución debe ser una lectura pública limitada (por ejemplo, Edge Function o RPC de solo lectura con campos permitidos), sin conceder acceso general a la tabla privada de configuración.

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
- No existen todavía las RPC nuevas de inventario, finanzas de pedidos, historial de clientes, cancelaciones, reembolsos, métodos de pago atómicos y configuración pública global.
- Sí existen los helpers `private.business_is_active(uuid)`, `private.has_business_role(uuid,text[])`, `private.is_platform_owner()` y el checkout base `public.create_public_order(...)`.
- El trigger de pedidos está activo y apunta a `private.enforce_order_status_transition()`.
- La extensión `pgcrypto` está instalada en `extensions`; el borrador de idempotencia usa `extensions.digest`.

## 6. Plan de validación antes de cualquier despliegue

1. Separar los borradores en migraciones versionadas, con nombres y orden definitivos. No editar el historial de migraciones ya aplicadas.
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
