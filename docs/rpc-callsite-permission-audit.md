# Auditoría de llamadas RPC y permisos de paneles

**Proyecto:** MiEje Market Independiente  
**Rama:** `correcciones-funcionales`  
**Fecha:** 16 de noviembre de 2026  
**Alcance:** llamadas desde paneles, cuenta de cliente y Edge Functions; contraste con las firmas SQL de la rama y catálogo real de funciones Supabase.  
**Estado:** revisión estática y SQL de solo lectura. No se ejecutaron migraciones ni despliegues.

## 1. Dictamen

Las firmas y nombres de parámetros revisados coinciden, en general, entre el código de la rama y los borradores SQL. No se encontró un desajuste de argumentos en las llamadas enumeradas abajo.

El bloqueo principal es que las nuevas funciones todavía no existen en la base activa. Las RPC de panel, cuenta de cliente, checkout idempotente y administración técnica dependen de migraciones pendientes. Por tanto, el código de la rama no debe desplegarse sobre el esquema activo como si ya estuviera integrado.

Se corrigió además un comentario incorrecto sobre el límite de checkout: la reserva IP se registra mediante una RPC independiente; la creación del pedido exige esa reserva y guarda el pedido + resultado idempotente en su propia transacción.

## 2. Panel de administrador y personal

| Llamada | Firma SQL preparada | Permiso previsto | Revisión |
|---|---|---|---|
| `get_business_admin_order_financials` | `(uuid, boolean, integer)` | `authenticated`; administrador activo del negocio | Coincide. Solo la carga administrativa la usa. |
| `get_business_admin_profit_report` | `(uuid, date, date)` | `authenticated`; administrador activo | Coincide. |
| `register_business_expense` | `(uuid,text,text,numeric,date,text,text,text,text,text,text)` | `authenticated`; administrador del negocio | Coincide con los 11 parámetros del formulario. |
| `pay_business_expense` | `(uuid,text,text)` | `authenticated`; administrador activo | Coincide. El borrador elimina explícitamente la firma anterior de dos parámetros. |
| `void_business_expense` | `(uuid,text)` | `authenticated`; administrador activo | Coincide. |
| `attach_business_expense_receipt` | `(uuid,text)` | `authenticated`; administrador activo | Coincide. |
| `adjust_business_inventory` | `(uuid,uuid,integer,integer,text)` | `authenticated`; administrador activo | Coincide. El inventario no se cambia con el UPDATE genérico de producto. |
| `save_business_payment_methods` | `(uuid,jsonb)` | `authenticated`; administrador activo | Coincide. La migración cierra la escritura directa y deja la RPC. |
| `mark_order_payment_received` | `(uuid,text,text,text)` | `authenticated`; administrador activo | Coincide. |
| `complete_order_refund` | `(uuid,text,text,text,text)` | `authenticated`; administrador activo | Coincide. Registra un reembolso externo ya realizado; no transfiere dinero. |
| `request_order_cancellation` | `(uuid,uuid,text)` | `authenticated`; administrador o empleado del negocio | Coincide. El empleado solo solicita, no aprueba. |
| `decide_order_cancellation` | `(uuid,text,text)` | `authenticated`; administrador activo | Coincide. |

La carga del panel de empleado (`loadEmployeeOrders`) no ejecuta `get_business_admin_order_financials`; consulta solo los campos operativos de pedidos y líneas. El panel administrativo combina esos campos con la RPC financiera. La separación es correcta.

## 3. Edge Function técnica

La Edge Function `technical-business-management` invoca 13 RPC con un cliente de servidor:

| RPC | Firma SQL preparada | Permiso |
|---|---|---|
| `create_platform_financial_record_transactional` | `(uuid,text,text,numeric,text,timestamptz,text,uuid)` | Solo `service_role` |
| `create_platform_payroll_record_transactional` | `(uuid,text,text,numeric,text,date,uuid)` | Solo `service_role` |
| `resolve_platform_payroll_record` | `(uuid,text,text,uuid)` | Solo `service_role` |
| `update_platform_ai_settings_transactional` | `(boolean,text,text,uuid)` | Solo `service_role` |
| `update_platform_public_settings_transactional` | `(text,text,text,text,text,uuid)` | Solo `service_role` |
| `create_technical_business_transactional` | `(text,text,text,uuid)` | Solo `service_role` |
| `create_business_membership_assignment` | `(uuid,uuid,text,text,text,uuid,boolean)` | Solo `service_role` |
| `update_business_membership_assignment` | `(uuid,text,text,uuid)` | Solo `service_role` |
| `set_technical_business_status` | `(uuid,text,text,text,uuid)` | Solo `service_role` |
| `suspend_business_membership` | `(uuid,text,uuid)` | Solo `service_role` |
| `reactivate_business_membership` | `(uuid,text,uuid)` | Solo `service_role` |
| `moderate_business_content_transactionally` | `(uuid,text,text,uuid)` | Solo `service_role` |
| `resolve_access_block_request` | `(uuid,text,text,uuid)` | Solo `service_role` |

Los nombres de parámetros enviados coinciden con las declaraciones SQL. El actor técnico se obtiene del usuario autenticado y validado por la Edge Function, no de un campo arbitrario del navegador. La columna `job_title` la crea `business-admin-boundaries.sql`; el archivo de RPC técnicas depende de ella y ya no repite su definición. La Edge Function comprueba rol de propietario y AAL2.

**Bloqueo:** ninguna de estas 13 RPC existía en el catálogo activo consultado. Desplegar esta Edge Function antes de aplicar sus migraciones produciría errores de función inexistente.

## 4. Checkout y postulaciones

### Checkout idempotente

La Edge Function `create-public-order` invoca:

| RPC | Firma SQL preparada | Permiso |
|---|---|---|
| `get_public_order_idempotent` | `(uuid,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)` | Solo `service_role` |
| `reserve_checkout_rate_limit` | `(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)` | Solo `service_role` |
| `create_public_order_idempotent` | `(uuid,text,uuid,uuid,uuid,text,text,text,text,text,text,jsonb)` | Solo `service_role` |

El objeto `requestArgs` coincide con las firmas; la Edge añade `p_ip` en las dos llamadas que lo requieren.

Secuencia: primero se consulta si la clave ya produjo un pedido; si no, se registra la reserva IP en una transacción independiente; luego se crea el pedido y se guarda la respuesta idempotente en una transacción propia. Si falla inventario, se revierte el pedido y la clave idempotente, pero la reserva IP permanece para que el intento fallido cuente en el límite. Un reintento con la misma clave y contenido reutiliza la reserva.

Se corrigieron comentarios en `create-public-order/index.ts` y `checkout-idempotency-draft.sql` que describían incorrectamente el límite como parte de la misma transacción del pedido.

### Postulaciones

La Edge Function `create-job-application` invoca:
- `consume_job_application_rate_limit(text)`: ya existe en la base activa y está reservada a `service_role`.
- `submit_public_job_application(uuid,uuid,uuid,text,text,text,jsonb,boolean,text)`: existe en la base activa y está reservada a `service_role`; el borrador de limpieza conserva la firma.

No se encontró discrepancia de argumentos. Siguen pendientes los hallazgos de privacidad ya documentados: falta guardar fecha/versión del consentimiento y no existe análisis antimalware del archivo.

## 5. Cuenta del cliente y otras Edge Functions

- `cuenta.js` invoca `get_customer_order_history()`. La firma coincide con `order-financial-access-draft.sql`, pero la RPC no existe aún en la base activa.
- `resolve-my-access`, `get-public-storefront`, `get-platform-public-settings` y `track-public-order` no invocan RPC SQL en los archivos revisados; usan consultas de servidor o construyen la respuesta.
- La portada invoca `get-public-storefront`, `create-job-application`, `create-public-order`, `track-public-order` y `get-platform-public-settings`. En el proyecto Supabase consultado, `get-platform-public-settings` todavía no figura como función activa, aunque su código sí está en la rama; el soporte técnico que depende de esa función fallará hasta desplegarla en staging y verificarla.

## 6. Permisos de las consultas directas del panel

| Tabla | Uso del panel | Acceso esperado en las migraciones |
|---|---|---|
| `businesses` | Leer ficha y actualizar datos comerciales | Lectura pública limitada; UPDATE solo columnas comerciales del administrador de ese negocio |
| `products` | Catálogo, alta y edición | Lectura por catálogo/miembros; INSERT de administrador; UPDATE limitado; inventario por RPC; sin DELETE físico |
| `product_costs` | Consultar y guardar costos | Solo administrador activo de ese negocio |
| `business_payment_methods` | Consultar métodos | Lectura bajo RLS; escritura por RPC |
| `business_expenses` | Listar gastos | Lectura del administrador; cambios por RPC |
| `business_content_pages` | Vacantes y contenido | Público solo publicado/aprobado; administrador gestiona el propio negocio |
| `business_ai_settings` | Leer y guardar asistente de tienda | Solo administrador activo; `updated_by = auth.uid()` |
| `access_block_requests` | Solicitar bloqueo | INSERT de administrador; resolución técnica por Edge |
| `inventory_movements` | Historial de existencias | Lectura de administrador; escritura por triggers/RPC |
| `orders`, `order_items` | Pedidos operativos | Miembros del negocio activo con columnas limitadas; importes por RPC de administrador |
| `order_cancellation_requests` | Revisar solicitudes | Lectura de administrador; cambios por RPC |
| `audit_logs` | Consultar auditoría | Filas del negocio correspondiente; acceso técnico mediante servidor |

La interfaz usa `business_ai_settings.upsert`; el borrador concede SELECT/INSERT/UPDATE a `authenticated` con RLS que valida el administrador activo y `updated_by = auth.uid()`. El formulario debe seguir enviando el usuario autenticado como `updated_by`.

**Data API:** las tablas nuevas de `public` no se exponen automáticamente. Antes de probar estas consultas hay que habilitar la exposición necesaria y revisar grants + RLS. No se debe abrir acceso general para resolver errores de tabla no expuesta.

## 7. Catálogo activo de Supabase

La consulta de solo lectura encontró estas RPC públicas relevantes. La lista de Edge Functions activas contiene seis funciones: `technical-business-management` v6, `create-public-order` v3, `track-public-order` v1, `resolve-my-access` v2, `get-public-storefront` v2 y `create-job-application` v2. La rama incluye además `get-platform-public-settings` y `cleanup-job-application-data`, que no aparecen activas en el proyecto consultado:
- `consume_checkout_rate_limit(text)`
- `consume_job_application_rate_limit(text)`
- `create_public_order(...)`
- `pay_business_expense(uuid,text)`
- `register_business_expense(...)`
- `submit_public_job_application(...)`
- `void_business_expense(uuid,text)`

También existen helpers privados de membresía y transición de estados. No existen todavía las RPC nuevas de finanzas del panel, inventario, métodos de pago atómicos, historial de cliente, cancelaciones, reembolsos, checkout idempotente ni las 13 RPC técnicas.

Por tanto, las llamadas de la rama y el esquema activo están en etapas distintas. Es una dependencia de implementación pendiente, no un fallo general de parámetros.

## 8. Acciones pendientes antes de staging

1. Aplicar el paquete SQL en un entorno de ensayo autorizado y respetar el orden del informe de dependencias.
2. Ejecutar `verify-integration-package.sql` y `verify-order-financial-access.sql`.
3. Confirmar en el catálogo que las funciones tienen las firmas esperadas y que sus grants coinciden con los roles.
4. Probar cada acción de los tres paneles con usuarios de prueba de dos negocios.
5. Confirmar que empleados no pueden ejecutar RPC financieras ni consultar tablas financieras por REST.
6. Confirmar que las operaciones técnicas rechazan usuarios no propietarios o sin AAL2.
7. Probar reintentos y fallos de checkout, inventario, cancelación y reembolso.
8. Desplegar Edge Functions solo después de que sus tablas y RPC existan y pasen pruebas.

## 9. Límites

- Se consultó el catálogo real de funciones con SQL de solo lectura.
- Se revisaron paneles, Edge Functions y migraciones de la rama.
- No se ejecutaron pruebas autenticadas de cada rol porque no hay staging disponible.
- No se ejecutaron migraciones, no se cambiaron grants en la base activa, no se desplegaron Edge Functions y no se publicó GitHub Pages.

**Dictamen:** las firmas revisadas están alineadas en la rama. El siguiente bloqueo es aplicar y verificar las migraciones en staging y probar el comportamiento real de cada rol. La base activa no debe recibir el código de la rama hasta completar esas pruebas.
