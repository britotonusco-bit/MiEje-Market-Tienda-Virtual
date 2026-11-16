# Auditoría de escrituras directas y límites entre paneles

**Fecha:** 16 de noviembre de 2026  
**Rama revisada:** `correcciones-funcionales`  
**Proyecto Supabase inspeccionado:** `cqixlrwbqatbhzmpygiz` (MiEje Market Independiente)  
**Alcance:** llamadas de escritura y lectura de `panel-live.js` y `app.js`, políticas RLS, privilegios de columnas, funciones RPC y estado de tablas en el proyecto activo.  
**Tipo de revisión:** inspección estática de código y metadatos SQL de solo lectura. No se ejecutaron operaciones de negocio ni pruebas con usuarios reales.

> **Estado: auditoría abierta. No aprobado para integración ni producción.** Los hallazgos describen el estado observado en el proyecto independiente y los archivos de la rama. Los borradores SQL mencionados no están aplicados por el hecho de existir en GitHub.

## 1. Resumen ejecutivo

Se confirmó que el panel técnico concentra sus operaciones privilegiadas en la Edge Function `technical-business-management`, en vez de escribir directamente en las tablas desde el navegador. Es una separación adecuada como patrón, aunque las acciones reales deben seguir validándose en servidor con propietario técnico y MFA AAL2.

El panel de administrador y el panel de empleados realizan algunas escrituras directas a través de Supabase Data API. RLS y los privilegios por columna son la barrera real, no los filtros `.eq('business_id', businessId)` ni las restricciones visuales.

Hay cuatro grupos de bloqueos:

1. **Desfase crítico de estados de pedido:** la interfaz usa `received` y `on_the_way`, pero el constraint y el trigger activos de la base siguen usando `pending` y `out_for_delivery`. Los cambios normales de estado no comparten el mismo contrato.
2. **Funciones y tablas que el código consume y que no existen en el proyecto activo:** favoritos, configuración de IA por negocio, movimientos de inventario, solicitudes de bloqueo y varias RPC. Algunas funciones de gastos sí existen.
3. **Permisos activos más amplios que la separación de paneles deseada:** el propietario técnico aparece autorizado por RLS para actualizar negocios, métodos de pago, costos de productos y estados de pedidos. Esto permite operaciones técnicas sobre datos comerciales que deberían corresponder al administrador del negocio o a procesos específicos.
4. **Claves de pertenencia modificables:** los privilegios por columna de productos, costos y gastos incluyen columnas de identidad/negocio. Las políticas limitan el negocio de destino, pero no garantizan que la pertenencia de una fila sea inmutable.

## 2. Inventario de llamadas por superficie

### Panel técnico superior

Las acciones de creación de negocios, invitaciones, asignaciones, suspensión/reactivación, bloqueo de miembros, moderación, finanzas de plataforma, nómina y configuración global pasan por `callTechnicalFunction()`, que invoca `technical-business-management`.

**Resultado estático:** no se detectó en los callsites revisados una escritura directa del panel técnico a las tablas comerciales para realizar esas operaciones. Esto es positivo y coincide con el modelo de tres paneles.

**Pendiente de verificación:** inspeccionar y probar cada rama de la Edge Function en un entorno de ensayo, incluyendo propietario técnico, AAL2, perfiles bloqueados, membresías, validación de negocio y registro de auditoría. La interfaz no demuestra por sí sola que todas las ramas del servidor estén protegidas.

### Panel de administrador del negocio

Se detectaron estas operaciones directas:

- Lectura de productos, gastos, movimientos de inventario, costos, pedidos, publicaciones, postulaciones, miembros y auditoría.
- Escritura directa de productos, datos generales del negocio, publicaciones, postulaciones, configuración de IA y solicitudes de bloqueo.
- RPC para ajustes de inventario, métodos de pago, gastos, reportes financieros, pagos, cancelaciones y reembolsos.
- Operaciones de Storage para imágenes, comprobantes y hojas de vida.

Las llamadas incluyen filtros por `business_id` en varios casos. Esos filtros ayudan a evitar errores de interfaz, pero no sustituyen las políticas RLS ni las comprobaciones de pertenencia en el servidor.

### Panel de empleados

El panel reutiliza las lecturas operativas de pedidos y la actualización de estado de pedidos. No se encontró un flujo de escritura directa de empleados para catálogo, configuración del negocio, costos, postulaciones o gastos.

La política activa de `orders` permite a miembros con rol `business_admin` o `employee` actualizar el pedido de su negocio activo; los privilegios de columna limitan esa actualización a `status` y `delivery_tracking`. Esta limitación por columna es una protección importante.

### Sitio público

- Lee negocios y productos publicados.
- Lee favoritos del usuario autenticado y crea/elimina favoritos directamente en `customer_favorites`.
- Envía pedidos mediante `create-public-order`, no mediante INSERT directo a `orders`.
- Consulta seguimiento mediante `track-public-order`.
- Envía postulaciones mediante `create-job-application`, con carga temporal firmada para el archivo.
- Lee configuración pública mediante Edge Function.

El checkout usa una función de servidor y una clave de idempotencia; la revisión de su lógica ya está documentada en la auditoría de checkout. Este informe se centra en los límites de las escrituras directas y en las dependencias que faltan.

## 3. Hallazgos confirmados en el proyecto activo

### H-01 — Contrato de estados de pedido desalineado

**Severidad: crítica.**

La interfaz define el flujo:

`received → confirmed → preparing → ready → on_the_way → delivered`

La base activa tiene el constraint `orders_status_check` con:

`pending, confirmed, preparing, ready, out_for_delivery, delivered, cancelled`

Además, la función activa `private.enforce_order_status_transition()` permite las transiciones antiguas `pending → confirmed` y `ready → out_for_delivery`. No reconoce `received` ni `on_the_way`.

El trigger está instalado y se ejecuta antes de actualizar `orders`. Por tanto, la validación de la interfaz no puede corregir el desfase: la base rechazará los estados que no estén en su constraint o que no coincidan con su transición.

**Corrección propuesta:** aplicar en staging, después de validar dependencias y datos ficticios, la normalización y el trigger canónico del archivo `database/security/business-admin-boundaries.sql`. La migración debe convertir los valores históricos de forma transaccional, actualizar el constraint y alinear la función con el flujo actual. Después probar cada transición permitida, cada salto inválido, cancelación aprobada y negocio suspendido.

**No se modificó la base activa.**

### H-02 — Dependencias de tablas ausentes

**Severidad: alta.**

La consulta de catálogo del esquema `public` no encontró estas tablas que el código intenta utilizar:

- `customer_favorites`: el sitio público consulta, inserta y elimina favoritos.
- `business_ai_settings`: el panel de administrador consulta y guarda configuración de IA por negocio.
- `inventory_movements`: el panel de administrador consulta el historial de movimientos.
- `access_block_requests`: el panel de administrador crea solicitudes de bloqueo para revisión técnica.

Los archivos de la rama contienen borradores para varias de estas dependencias:

- `database/customers/customer-account-migration.sql`
- `database/ai/ai-settings-draft.sql`
- `database/inventory/inventory-movements-draft.sql`
- `database/security/access-block-requests-draft.sql`

**Impacto:** los componentes correspondientes no pueden considerarse funcionales en el proyecto activo. Los errores de consulta o escritura deben mostrarse en la interfaz, pero eso no reemplaza la tabla faltante.

**Corrección propuesta:** incorporar las migraciones al paquete de staging, comprobar orden de dependencias, grants, RLS y exposición de Data API, y probar con dos negocios y usuarios ficticios. No ejecutar estos borradores en el proyecto activo.

### H-03 — RPC consumidas por la interfaz que no existen en el proyecto activo

**Severidad: alta.**

La consulta de funciones públicas encontró estas RPC presentes:

- `pay_business_expense(p_expense_id uuid, p_payment_method text)`
- `register_business_expense(...)`
- `void_business_expense(p_expense_id uuid, p_void_reason text)`

No encontró las siguientes RPC que los callsites revisados invocan:

- `get_business_admin_order_financials`
- `get_business_admin_profit_report`
- `save_business_payment_methods`
- `adjust_business_inventory`
- `attach_business_expense_receipt`
- `mark_order_payment_received`
- `complete_order_refund`
- `request_order_cancellation`
- `decide_order_cancellation`

La ausencia se refiere al esquema `public` del proyecto inspeccionado. No equivale a decir que no existan archivos SQL de borrador en la rama.

**Impacto:** las secciones de finanzas de pedidos, reportes, configuración de pagos, ajuste controlado de inventario, comprobantes, pagos y cancelaciones/devoluciones no están listas para operar contra el proyecto activo.

**Corrección propuesta:** conciliar cada firma y permiso con el código de llamada y el paquete de integración. Aplicar y verificar en staging, no desplegar de forma aislada ni asumir que la existencia de una función significa que su permiso EXECUTE es correcto.

### H-04 — El propietario técnico conserva permisos RLS sobre datos comerciales

**Severidad: alta; incumple la separación funcional definida para los paneles.**

Las políticas activas incluyen `private.is_platform_owner()` como vía de autorización para:

- actualizar filas de `businesses`;
- insertar, consultar y actualizar `business_payment_methods`;
- consultar, insertar y actualizar `product_costs`;
- consultar y actualizar pedidos;
- consultar gastos y otros datos de negocio en algunas políticas.

En `orders`, la función activa `private.enforce_order_status_transition()` también autoriza explícitamente al propietario técnico. Los privilegios por columna limitan el UPDATE de pedidos a `status` y `delivery_tracking`, pero el técnico aún puede cambiar el estado si llama directamente a la Data API.

**Impacto:** aunque el panel técnico no exponga esos botones, un propietario técnico autenticado puede realizar operaciones comerciales directas que deberían corresponder al administrador del negocio o a un flujo operativo específico. Esto contradice el modelo acordado: el técnico gestiona plataforma, negocios y accesos; el administrador gestiona su tienda.

**Corrección propuesta:** retirar la vía general del propietario técnico de las políticas y triggers comerciales. Mantener el acceso técnico mediante Edge Functions específicas y auditadas solo para las acciones de plataforma necesarias. Conservar acceso de lectura de moderación cuando sea requerido, sin habilitar escrituras comerciales generales.

### H-05 — Columnas de pertenencia modificables en tablas de negocio

**Severidad: alta para integridad multi-tenant.**

Los privilegios de columna activos de `authenticated` incluyen UPDATE de:

- `products.business_id` y `products.id`;
- `product_costs.business_id` y `product_costs.product_id`;
- todas las columnas de `business_expenses`, incluida `business_id` e `id`;
- `business_payment_methods.business_id` e `id`.

Las políticas RLS de varias tablas comprueban que el usuario tenga rol en el negocio indicado por la fila. Sin embargo, los privilegios no vuelven inmutables las claves de pertenencia. Si una cuenta administra más de un negocio, debe evitarse que pueda trasladar una fila entre negocios mediante una actualización directa.

**Corrección propuesta:** revocar UPDATE de identificadores y columnas de pertenencia en Data API. Para cambios que requieran mover una entidad, diseñar una operación de servidor explícita, con validación y auditoría. Revisar también constraints compuestos y triggers de inmutabilidad.

### H-06 — Datos generales del negocio: escritura técnica demasiado amplia

**Severidad: alta para separación de responsabilidades.**

La política activa `businesses_admin_update` autoriza al propietario técnico o al administrador del negocio. Los privilegios de UPDATE por columna incluyen nombre, categoría, descripción, logo, horarios, ciudad, teléfonos, tarifa de domicilio y pedido mínimo.

El panel de administrador necesita esos campos. El panel técnico no debe disponer de una vía general de escritura para ellos.

**Corrección propuesta:** la política de actualización debe quedar limitada al administrador del negocio activo. El técnico debe cambiar estado, suspensión y mensajes de plataforma mediante operaciones de servidor específicas, sin poder editar la ficha comercial de la tienda desde Data API.

### H-07 — Gastos y contenido permiten modificar columnas sensibles en bloque

**Severidad: media-alta.**

Los privilegios de UPDATE de `business_expenses` abarcan importes, negocio, autor, fecha, estado de pago, referencia, comprobante y campos de anulación. La interfaz utiliza RPC para registrar/pagar/anular, pero la Data API conserva privilegios directos amplios.

En `business_content_pages`, el administrador puede actualizar contenido y publicación, mientras la moderación técnica se realiza por Edge Function. La política de actualización limita la fila al administrador del negocio activo, pero el conjunto de columnas debe mantenerse separado de los campos de moderación.

**Corrección propuesta:** revocar escrituras directas en columnas financieras de control y mantenerlas detrás de RPC transaccionales. En publicaciones, permitir al administrador modificar únicamente campos editoriales y de despublicación; reservar estado de moderación, autoría de moderación y notas técnicas a la función técnica.

## 4. Controles que sí están presentes

- El panel técnico utiliza la Edge Function para operaciones privilegiadas; no se detectó escritura directa desde esos callsites.
- La actualización de `orders` desde los paneles solo concede UPDATE de `status` y `delivery_tracking` a nivel de columna.
- La política de pedidos exige una membresía de administrador/empleado en el negocio y negocio activo, aunque la vía adicional de propietario técnico debe retirarse.
- Las postulaciones solo pueden ser leídas y actualizadas por el administrador del negocio según las políticas activas.
- Las políticas de productos limitan las filas al negocio asociado a una membresía administrativa activa; no conceden escrituras a empleados.
- El checkout y el envío de postulaciones se realizan mediante Edge Functions, no mediante inserciones públicas directas desde el navegador.
- Las operaciones de gastos para registrar, pagar y anular cuentan con RPC en el proyecto activo; falta confirmar su comportamiento con pruebas de autorización y concurrencia.

## 5. Plan de corrección priorizado

1. **Bloqueo previo:** alinear estados de pedido entre UI, constraint, trigger, RPC de cancelación y funciones de checkout.
2. Crear en staging las tablas que faltan y validar Data API, RLS y Storage.
3. Implementar las RPC faltantes y verificar firma, grants, atomicidad, idempotencia y auditoría.
4. Retirar al propietario técnico de las escrituras comerciales generales; conservar operaciones técnicas en Edge Functions con AAL2.
5. Revocar UPDATE de claves primarias y columnas `business_id`/relaciones en tablas multi-tenant.
6. Reducir permisos de gastos y publicaciones a las columnas necesarias.
7. Ejecutar matriz de dos negocios: admin A, empleado A, admin B, cliente y técnico. Probar acceso cruzado y escrituras manipuladas fuera de la interfaz.
8. Repetir pruebas de regresión del sitio público y los tres paneles.

## 6. Pruebas aún pendientes

No se realizaron pruebas dinámicas con sesiones de cada rol, solicitudes HTTP manipuladas, dos operaciones concurrentes ni cargas reales. Tampoco se ejecutaron las migraciones borrador, RPC ausentes o despliegues Edge.

Para cerrar la auditoría se requiere staging aislado con datos ficticios y evidencia de:
- transición válida e inválida de cada estado;
- administrador A sin acceso a filas de B, incluso cambiando parámetros manualmente;
- empleado sin acceso a catálogo, finanzas, postulaciones o configuración;
- propietario técnico sin escritura comercial directa;
- imposibilidad de cambiar `business_id`, IDs y relaciones mediante UPDATE;
- RPC faltantes instaladas y permisos comprobados;
- favoritos, configuración IA, movimientos y solicitudes de bloqueo funcionando;
- ausencia de errores de consola y respuestas inesperadas en los tres paneles y el sitio público.

## 7. Seguridad y cambios realizados

Esta revisión utilizó únicamente lecturas de GitHub y consultas SQL de metadatos/definiciones en el proyecto Supabase independiente.

- No se insertaron, actualizaron ni eliminaron datos.
- No se ejecutaron migraciones ni RPC de negocio.
- No se desplegaron Edge Functions.
- No se modificó `main`, GitHub Pages ni el proyecto Supabase antiguo.
- Los hallazgos no constituyen autorización para aplicar cambios en producción.
