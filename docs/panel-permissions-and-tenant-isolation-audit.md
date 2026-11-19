# Auditoría de permisos de paneles y aislamiento entre negocios

**Fecha:** 16 de noviembre de 2026  
**Proyecto Supabase:** MiEje Market Independiente (`cqixlrwbqatbhzmpygiz`)  
**Rama revisada:** `correcciones-funcionales`

## Alcance y límites

Se revisaron en modo de solo lectura las políticas RLS, los privilegios de tabla y columna, las funciones auxiliares de autorización y las consultas que ejecutan los paneles y el sitio público.

También se contrastó la base activa con los borradores de la rama:
- `database/security/business-admin-boundaries.sql`
- `database/orders/order-financial-access-draft.sql`
- `database/security/business-payment-methods-atomic-draft.sql`
- `database/inventory/inventory-movements-draft.sql`

No se ejecutaron migraciones ni pruebas de escritura en la base activa. Las comprobaciones de aislamiento con dos usuarios y dos negocios requieren un entorno de ensayo con cuentas de prueba.

## Resultado general

La base activa tiene RLS habilitado en las tablas revisadas y las funciones auxiliares `private.has_business_role` y `private.business_is_active` aplican controles de membresía activa, perfil no bloqueado y negocio activo. Sin embargo, varias políticas activas conservan un bypass global para `platform_owner`, y algunos permisos de columna permiten cambios que no corresponden al panel.

La rama contiene correcciones para la mayoría de estos problemas, pero no están instaladas en Supabase.

## Hallazgos activos

### TEN-01 — El propietario técnico tiene acceso directo global a información de los negocios
**Severidad: alta. Estado: corregido en borradores de la rama; pendiente de activar.**

Las políticas activas incluyen `private.is_platform_owner()` como alternativa de acceso en tablas que contienen información comercial y personal. La consulta de catálogo encontró ese bypass en:
- `businesses`, `business_memberships`, `profiles`.
- `products`, `business_content_pages`, `business_payment_methods`.
- `orders`, `order_items`, `order_cancellation_requests`.
- `business_expenses`, `product_costs`, `order_item_costs`.
- `financial_transactions`, `refund_details`.

Esto permite que la cuenta técnica consulte por Data API datos de clientes, pedidos, costos, gastos y referencias financieras de cualquier tienda. La función técnica debe administrar negocios y accesos mediante Edge Function, no obtener acceso general a los datos privados de cada negocio.

**Corrección de la rama:** `business-admin-boundaries.sql` elimina el bypass técnico en políticas comerciales, operativas y financieras; limita perfiles y membresías a los datos necesarios; conserva la gestión técnica mediante Edge Function. El acceso global a auditoría queda separado.

### TEN-02 — Un administrador con acceso a dos negocios podría trasladar registros entre ellos
**Severidad: alta. Estado: mitigado en el borrador de la rama.**

En la base activa, los privilegios UPDATE incluyen `business_id` en `products`, `business_payment_methods`, `business_expenses` y `product_costs`; en `product_costs` también se puede cambiar `product_id`. Las políticas RLS comprueban que el usuario tenga rol administrativo en el negocio de destino, pero no hacen inmutable la pertenencia original.

Por tanto, si una misma cuenta administra dos negocios, una solicitud directa podría intentar mover un registro de un negocio al otro.

**Corrección de la rama:** restringe las columnas UPDATE, elimina `business_id` y las referencias de producto de los campos modificables y agrega `private.prevent_business_scope_change()` para rechazar cambios de pertenencia y validar que cada costo corresponda a un producto del mismo negocio. Debe probarse con una cuenta administradora de dos negocios.

### TEN-03 — El personal puede consultar más datos de un pedido de los que muestra la interfaz
**Severidad: alta por minimización de datos. Estado: corregido en migración candidata 13.**

En la base activa, `authenticated` tiene SELECT sobre todas las columnas de `orders` y `order_items`. La interfaz del empleado muestra nombre, teléfono, dirección, instrucciones de entrega, estado y productos, pero el permiso directo también deja disponibles campos como:
- Correo del cliente.
- Token público de seguimiento.
- Totales, subtotal, domicilio y estado de pago.
- Precio unitario y total de cada línea.

Que la interfaz no muestre un campo no impide que una persona autenticada lo solicite directamente al Data API.

**Corrección de la rama:** `order-financial-access-draft.sql` retira SELECT general y concede solo las columnas operativas necesarias. Los importes se entregan por `get_business_admin_order_financials`, que valida que el solicitante sea administrador activo del negocio. El historial del cliente se sirve mediante una RPC que comprueba la propiedad del pedido. Los precios por línea no quedan disponibles para empleados.

La migración 13 debe aplicarse después del checkout idempotente y antes de considerar terminados los paneles financieros.

### TEN-04 — El panel permite eliminar publicaciones que tienen postulaciones vinculadas
**Severidad: alta por riesgo de pérdida de historial. Estado: corregido en el borrador de la rama.**

La política activa `business_content_pages_admin_delete` permite DELETE al administrador del negocio. La FK compuesta `job_applications_content_page_business_fk` usa `ON DELETE CASCADE`; borrar una publicación puede borrar también las postulaciones asociadas.

**Corrección de la rama:** revoca DELETE de `business_content_pages`. El panel debe despublicar con UPDATE de `is_published`, conservando vacante, postulaciones y archivos.

### TEN-05 — La administración de gastos permite UPDATE de columnas internas
**Severidad: alta. Estado: restringido en el borrador de la rama.**

La base activa concede UPDATE de todas las columnas de `business_expenses`, incluidas pertenencia al negocio, creador, importe, fecha y campos de anulación. Aunque RLS exige rol de administrador, no restringe suficientemente qué campos puede alterar una operación directa.

**Corrección de la rama:** limita INSERT a los campos del gasto nuevo; restringe UPDATE a los campos de transición de pago/anulación y añade un trigger que valida que los demás campos no cambien. El flujo del panel usa RPC para registrar gastos y comprobantes.

### TEN-06 — El panel de empleados puede operar pedidos; la separación depende de RLS y del trigger
**Severidad: media. Estado: diseño de la rama; requiere prueba.**

El código del panel de empleados consulta pedidos del negocio asignado y actualiza `status` y `delivery_tracking`. La política activa permite esa operación a empleados y administradores, pero también contiene el bypass técnico.

**Corrección de la rama:** limita la política a membresías activas del negocio y añade `private.enforce_order_status_transition()` para validar el flujo de estados y el negocio activo. Los empleados pueden operar pedidos, pero no consultar la bandeja de cancelaciones ni decidir solicitudes, que queda reservada al administrador.

### TEN-07 — La lectura de postulaciones y perfiles debe permanecer limitada al negocio
**Severidad: media. Estado: corregido parcialmente en la rama.**

La política activa de lectura de postulaciones no exige que el negocio esté activo. La rama la sustituye por una política de administrador del negocio activo. También elimina el acceso global del propietario técnico a perfiles y limita los campos de perfil disponibles por Data API.

La Edge Function técnica consulta perfiles y correos solo cuando realiza la gestión autorizada de membresías.

## Comprobaciones de compatibilidad con la interfaz

Se contrastaron las consultas de `app.js` y `panel-live.js` con los grants candidatos:

- El sitio público consulta un conjunto concreto de columnas comerciales de `businesses` y productos activos. Esas columnas aparecen en los grants públicos del borrador.
- Los métodos de pago públicos se consultan mediante `get-public-storefront`, no mediante lectura pública directa de la tabla privada.
- El administrador consulta su ficha comercial y modifica solo campos comerciales permitidos.
- La edición de productos actualiza datos comerciales directamente, mientras que el inventario usa `adjust_business_inventory`.
- El panel de empleados y el de administrador consultan las mismas columnas operativas del pedido; el detalle financiero del administrador se obtiene por RPC.
- La interfaz despublica contenido en lugar de borrarlo.
- La revisión de postulaciones actualiza estado y notas; el trigger candidato genera `reviewed_by` y `reviewed_at` desde la sesión, evitando confiar en esos valores enviados por el navegador.

La compatibilidad completa no está certificada: varias RPC llamadas por los paneles no existen todavía en la base activa.

## Modelo de permisos esperado

| Área | Propietario técnico | Administrador | Empleado | Cliente/visitante |
|---|---|---|---|---|
| Crear y suspender negocios/cuentas | Sí, Edge Function + MFA | No | No | No |
| Configurar ficha, productos y pagos | No por Data API; soporte técnico controlado | Solo su negocio | No | Lectura pública permitida |
| Consultar finanzas del negocio | No por Data API | Solo su negocio | No | Solo su propio historial |
| Consultar y preparar pedidos | No por Data API | Su negocio | Su negocio | Solo seguimiento/historial propio |
| Revisar postulaciones | Moderación técnica limitada | Solo su negocio | No | Enviar solicitud |
| Auditoría global | Sí, por función técnica | No global | No global | No |

## Pruebas obligatorias en staging

1. Un administrador de A no puede leer ni modificar datos privados de B.
2. Una cuenta administradora de A y B no puede cambiar `business_id` de productos, pagos, gastos ni costos.
3. Un empleado de A no puede leer pedidos, clientes, postulaciones ni finanzas de B.
4. Un empleado no puede consultar `customer_email`, `public_tracking_token`, importes ni precios de línea directamente.
5. Un empleado puede cambiar estados solo en el orden permitido y solo para pedidos de su negocio.
6. Un empleado no puede confirmar pagos, decidir cancelaciones ni consultar reportes financieros.
7. El administrador puede consultar finanzas únicamente mediante RPC del negocio propio.
8. El propietario técnico con AAL2 puede gestionar cuentas y moderación, pero no consultar directamente pedidos, costos, gastos ni datos bancarios por Data API.
9. Despublicar una vacante conserva todas sus postulaciones y archivos.
10. Un administrador no puede cambiar el estado de moderación de su propio contenido ni alterar quién lo revisó.
11. Las columnas públicas de `businesses` y `products` siguen funcionando para visitantes anónimos.
12. Los métodos de pago públicos siguen funcionando mediante la Edge Function.
13. Las funciones de historial solo devuelven pedidos del cliente autenticado.
14. Una cuenta bloqueada globalmente y una membresía suspendida pierden acceso en las operaciones protegidas, aunque conserve un JWT anterior.
15. La modificación de datos y su auditoría deben confirmarse o revertirse juntas cuando se exige atomicidad.

## Orden de implementación

1. Preparar staging independiente y cuentas de prueba para al menos dos negocios, un administrador por negocio, un empleado y un cliente.
2. Aplicar y probar `business-admin-boundaries.sql` junto con las migraciones de las que depende. Consolidar antes la duplicación detectada en normalización de estados y trigger de pedidos entre los pasos 2 y 11.
3. Aplicar las migraciones de inventario, checkout y métodos de pago según `database/integration/README.md`.
4. Aplicar `order-financial-access-draft.sql` (paso 13) y ejecutar `verify-order-financial-access.sql`.
5. Aplicar el flujo de cancelaciones, reembolsos y gastos.
6. Ejecutar todas las pruebas de aislamiento y revisar los Advisors de Supabase.
7. Solo después de resultados satisfactorios, preparar el despliegue; no publicar directamente desde esta auditoría.

## Compatibilidad Supabase

Supabase hizo efectivo el 30 de octubre de 2026 el cambio por el que las tablas nuevas de `public` no quedan expuestas automáticamente a Data API. Las migraciones futuras deben definir explícitamente GRANT y RLS; son controles distintos. <https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically>

## Conclusión

La base activa todavía no cumple por completo la separación esperada entre los tres paneles. El mayor riesgo es el acceso directo global del propietario técnico y los permisos de columnas que permiten consultar o mover más datos de los necesarios. La rama contiene controles para corregirlo, incluyendo grants mínimos, RLS por membresía activa, RPC financieras y conservación de postulaciones.

El paquete no debe aplicarse parcialmente ni desplegarse en producción. Se requiere staging, consolidar las dependencias duplicadas y superar las pruebas de aislamiento antes de considerar segura la integración.
