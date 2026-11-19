# Auditoría de consultas directas, RLS y permisos por columna

**Proyecto:** MiEje Market Independiente  
**Rama:** `correcciones-funcionales`  
**Fecha:** 16 de noviembre de 2026  
**Alcance:** consultas directas del sitio, panel administrador, panel empleado y cuenta de cliente; RLS, privilegios de tabla/columna y existencia de tablas en Supabase.  
**Método:** inspección de código + consultas SQL de solo lectura + Security Advisor. No se ejecutaron cambios en Supabase.

## 1. Resultado general

La separación de roles está mejor definida en los borradores de la rama que en el esquema activo. La rama limita la gestión comercial al administrador del negocio, separa los datos financieros mediante RPC y restringe consultas a filas de negocios activos.

No obstante, **la base activa todavía no tiene aplicadas esas restricciones nuevas**. Hasta ejecutar y probar el paquete en staging, las políticas y permisos que actualmente están desplegados siguen siendo los efectivos.

## 2. Hallazgos prioritarios en la base activa

### Alto: columnas de pedidos visibles para empleados

La política RLS activa permite a empleados consultar pedidos de su negocio. Los grants actuales también les permiten seleccionar columnas como `customer_email`, `subtotal`, `delivery_fee`, `total`, `payment_method` y `payment_status`. RLS limita las filas, pero no oculta columnas dentro de las filas autorizadas.

El panel empleado solo necesita número de pedido, nombre, teléfono, dirección, instrucciones de entrega, estado, seguimiento, fecha, nombres de productos y cantidades. No necesita correo electrónico ni importes.

**Preparación en la rama:** `order-financial-access-draft.sql` retira SELECT general y grants de columnas sensibles, deja solo los campos operativos para miembros del negocio y entrega los datos financieros a administradores mediante `get_business_admin_order_financials`, que comprueba que el usuario sea administrador activo del negocio. También restringe `order_items` a nombre y cantidad, sin precios de línea.

Se retiró además `payment_method_name` del grant directo de lectura de pedidos: la interfaz administrativa obtiene el método desde la RPC financiera y el panel empleado no lo consulta.

### Alto: gestión comercial y financiera del técnico

En la base activa, las políticas de algunas tablas permiten al propietario técnico leer o modificar datos comerciales/operativos de todos los negocios. La rama prepara una separación más estricta:
- ficha del negocio: UPDATE solo para administrador de ese negocio;
- métodos de pago: lectura y configuración del administrador del negocio, escritura por RPC;
- costos de productos y gastos: lectura restringida al administrador activo;
- pedidos y líneas: acceso operativo solo para miembros del negocio activo;
- postulaciones: lectura/actualización solo para administrador de negocio activo;
- perfiles: el Data API limita lectura a los propios datos y a miembros del negocio del administrador; el técnico consulta datos puntuales por Edge Function.

Esto coincide con la separación definida para los tres paneles: el técnico administra negocios y accesos mediante Edge Functions, no configura ni consulta indiscriminadamente la información comercial privada de cada tienda.

### Medio: postulaciones de negocios suspendidos

La política activa `job_applications_business_admin_read` comprueba el rol de administrador, pero no exige que el negocio siga activo. La rama reemplaza la política para comprobar ambas condiciones. El UPDATE también requiere negocio activo y solo concede las columnas de revisión utilizadas por el panel.

### Tablas de la rama que aún no existen en el proyecto activo

La consulta al catálogo confirmó que estas tablas todavía no existen en `public`:
- `customer_favorites`
- `inventory_movements`
- `business_ai_settings`
- `access_block_requests`

Por tanto, las funciones del sitio y panel que consultan esas tablas no podrán funcionar en el proyecto activo hasta aplicar sus migraciones. No se debe resolver con permisos genéricos ni creando tablas manualmente fuera del paquete versionado.

## 3. Revisión de consultas por panel

### Panel de administrador

| Consulta | Columnas usadas por la interfaz | Protección preparada |
|---|---|---|
| `businesses` | nombre, categoría, descripción, ciudad, teléfono, WhatsApp, logo, horarios, tarifa y mínimo | UPDATE solo de columnas comerciales; RLS exige administrador del negocio activo |
| `products` | nombre, categoría, descripción, precio, inventario, imagen y estado | INSERT/UPDATE limitado; no se permite cambiar propietario o ID; inventario se ajusta mediante RPC |
| `product_costs` | producto y costo | SELECT/INSERT/UPDATE limitado a administrador activo; UPDATE solo costo y fecha |
| `orders` | campos operativos del pedido | SELECT de campos operativos; datos financieros por RPC |
| `business_expenses` | gastos y comprobantes | SELECT de administrador; cambios mediante RPC auditadas |
| `business_payment_methods` | código, nombre visible, instrucciones, estado y orden | lectura de administrador; escritura mediante RPC transaccional |
| `business_content_pages` | contenido, publicación y moderación | administrador del negocio activo; público solo contenido aprobado y publicado |
| `job_applications` | datos del postulante, respuestas, CV y estado | lectura y revisión por administrador del negocio activo |
| `business_ai_settings` | habilitación, nombre e instrucciones | acceso del administrador activo; clave del negocio inmutable |
| `inventory_movements` | producto, tipo, cantidades y motivo | lectura de administrador; movimientos por triggers/RPC |
| `order_cancellation_requests` | solicitud, motivo y decisión | bandeja solo para administrador activo |
| `profiles` + `business_memberships` | nombre y rol de miembros del negocio | administrador activo puede consultar miembros de su propio negocio |

Las llamadas revisadas del panel coinciden con los campos que conceden los borradores de permisos. El guardado de costos y de configuración de IA ya fue corregido para no intentar actualizar las claves inmutables `product_id`, `business_id` o `business_id` como parte de un UPSERT.

### Panel de empleados

La carga de pedidos usa únicamente campos operativos y líneas de producto. El empleado puede avanzar el estado y registrar la referencia de entrega mediante las columnas autorizadas. No usa la RPC financiera ni tiene una pantalla de costos, gastos, métodos de pago, postulaciones o solicitudes de cancelación.

La política de pedidos de la rama permite a empleados y administradores activos consultar y actualizar el flujo operativo. Las solicitudes de cancelación se crean por RPC controlada; la bandeja y la decisión quedan reservadas al administrador.

### Cuenta y sitio público

- `cuenta.js` consulta y elimina favoritos por usuario; `customer-account-migration.sql` crea la tabla, activa RLS y concede SELECT/DELETE propios e INSERT solo para `user_id, product_id`.
- `app.js` consulta catálogo y contenido publicado. Los borradores separan columnas públicas de las internas y limitan el contenido público a negocios activos y publicaciones aprobadas.
- La cuenta obtiene el historial mediante `get_customer_order_history()`; no necesita acceso directo a columnas financieras de pedidos ni a las líneas completas.
- Las postulaciones públicas pasan por Edge Function; el visitante no recibe SELECT de las postulaciones privadas.

## 4. Permisos por columna y operaciones de escritura

Se revisaron los siguientes puntos de la rama:
- Productos: el UPDATE no permite cambiar `id`, `business_id` ni `inventory`; el inventario se modifica con `adjust_business_inventory`.
- Costos: solo se actualizan `cost_price` y `updated_at`; la relación producto/negocio queda inmutable.
- Métodos de pago: el borrador atómico revoca escrituras directas y usa `save_business_payment_methods`.
- Gastos: el borrador revoca INSERT/UPDATE directos generales y conserva operaciones controladas de registro, pago y anulación.
- Pedidos: las columnas financieras se retiran del acceso directo; el estado y la referencia de entrega son los únicos campos actualizables por el panel.
- Líneas de pedido: no se permiten INSERT/UPDATE/DELETE desde los paneles.
- Perfiles: el usuario puede cambiar nombre visible, avatar y teléfono; no puede cambiar `platform_role`, `is_blocked` ni campos de control.
- Membresías: el Data API no puede crear ni modificar asignaciones; esas operaciones pasan por la Edge Function técnica.

## 5. Tablas nuevas y Data API

Supabase anunció que, desde el 30 de octubre de 2026, las tablas nuevas de `public` ya no se exponen automáticamente al Data API. Cada tabla nueva necesita grants explícitos además de RLS. Esto es relevante para las migraciones pendientes.

Se verificó que los borradores revisados conceden permisos explícitos:
- `customer_favorites`: SELECT/DELETE e INSERT por columnas a `authenticated`, con políticas propias.
- `inventory_movements`: SELECT a `authenticated`, RLS para administrador activo; sin escritura directa.
- `business_ai_settings`: SELECT/INSERT/UPDATE por columnas a `authenticated`, con políticas de administrador activo.
- `access_block_requests`: INSERT por columnas a `authenticated`; SELECT/UPDATE para el servicio técnico.

Referencia oficial: [Supabase — tablas nuevas no expuestas automáticamente](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically).

## 6. Security Advisor

La revisión de seguridad del proyecto devolvió:
- Tres avisos INFO `rls_enabled_no_policy` para `private.checkout_rate_limits`, `public.job_application_rate_limits` y `public.job_application_upload_sessions`. En el diseño actual son tablas internas; no deben recibir políticas genéricas ni acceso directo solo para silenciar el aviso.
- Un aviso WARN: protección contra contraseñas filtradas desactivada en Auth. Debe habilitarse desde la configuración de Auth antes de la puesta en marcha. No se cambió esta configuración.

## 7. Corrección adicional aplicada en la rama

En `database/orders/order-financial-access-draft.sql` se retiró `payment_method_name` del grant SELECT de pedidos. El panel empleado no lo consulta y el panel administrador obtiene el método de pago desde la RPC financiera. Esto reduce la información visible por Data API sin afectar la interfaz prevista.

## 8. Pruebas pendientes

No se pudieron hacer pruebas autenticadas reales porque no hay un entorno staging disponible. Antes de desplegar:
1. Crear en staging dos negocios de prueba, con administrador y empleado independientes.
2. Confirmar que administrador A no puede leer ni modificar datos de negocio B.
3. Confirmar que empleado A solo ve campos operativos de pedidos A y no puede consultar correo, totales, método ni estado del pago por REST.
4. Confirmar que el administrador A obtiene importes por RPC y no puede usar RPC de negocio B.
5. Confirmar que el propietario técnico no puede modificar ficha comercial ni leer operaciones privadas por Data API; las acciones técnicas deben pasar por Edge Function con MFA AAL2.
6. Confirmar que un negocio suspendido no puede leer ni modificar postulaciones, contenido, costos, gastos ni pedidos.
7. Probar favoritos, historial de cliente, movimientos de inventario, IA de negocio y solicitudes de bloqueo tras aplicar sus migraciones.
8. Probar los permisos de Storage de logos, imágenes y hojas de vida con usuarios de cada rol.

## 9. Estado y límites

- Inspección de tablas, políticas RLS, grants de tabla y grants por columna: completada.
- Comparación de consultas directas de paneles y sitio: completada para los archivos revisados.
- Corrección del grant de `payment_method_name`: preparada en la rama.
- Migraciones, cambios de permisos activos, configuración Auth y despliegues: no ejecutados.
- Pruebas con usuarios reales de cada rol: pendientes de staging.

**Dictamen:** los borradores de la rama cubren las principales brechas encontradas, pero el proyecto activo todavía conserva los permisos anteriores. No publicar ni desplegar hasta aplicar el paquete en un entorno de ensayo, comprobar las pruebas de aislamiento y revisar los Security Advisors de nuevo.
