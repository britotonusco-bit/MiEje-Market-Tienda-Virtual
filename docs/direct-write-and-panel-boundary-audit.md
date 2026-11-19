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


## 8. Revisión adicional del borrador de límites y migración de estados

Al revisar el propio borrador `database/security/business-admin-boundaries.sql` contra los triggers existentes en el proyecto activo, se encontró un detalle de integridad histórica:

- La normalización de estados desactivaba `orders_enforce_status_transition`, pero dejaba activos `orders_audit_status` y `orders_set_updated_at`.
- En consecuencia, la conversión histórica de `pending` a `received` y de `out_for_delivery` a `on_the_way` podía generar eventos de auditoría que parecieran cambios realizados por un usuario y reescribir `updated_at` con la fecha de la migración.

**Corrección preparada en la rama:** el bloque de normalización desactiva temporalmente los tres triggers identificados en el esquema activo, realiza el cambio de valores y los vuelve a activar dentro de la misma transacción. Esto evita registrar el backfill como actividad operativa y conserva las marcas históricas de actualización.

También se cambió `private.prevent_business_scope_change()` de `SECURITY DEFINER` a `SECURITY INVOKER`. La función es un trigger de defensa de integridad, no necesita privilegios elevados: los administradores ya pueden consultar productos de su propio negocio y el rol de servicio conserva sus permisos. Reducir privilegios evita introducir un bypass RLS innecesario.

**Verificación realizada:** se volvió a consultar el catálogo de triggers del proyecto independiente y se confirmó que existen exactamente los nombres usados por el bloque de migración: `orders_enforce_status_transition`, `orders_audit_status` y `orders_set_updated_at`. Se verificó además en GitHub que el borrador contiene las tres desactivaciones/reactivaciones y que el trigger de pertenencia está declarado como `SECURITY INVOKER`.

**Límite de la verificación:** esto es comprobación estática y de metadatos. No se ejecutó la migración ni se probó una conversión sobre filas reales; esas pruebas siguen pendientes en staging.


## 9. Hallazgo adicional: firma desactualizada en confirmación de gastos

**Severidad: alta para la función de registrar pagos de gastos.**

La interfaz de administrador llama a `pay_business_expense` con tres parámetros nombrados:
- `p_expense_id`
- `p_payment_method`
- `p_transaction_reference`

La función existente en el proyecto Supabase activo solo tiene la firma de dos parámetros:
`pay_business_expense(p_expense_id uuid, p_payment_method text)`.

El borrador `database/finance/business-expense-audit-draft.sql` reemplaza la firma anterior por una versión de tres parámetros, con referencia de transacción opcional. Por tanto, el callsite de la rama coincide con el borrador futuro, pero no con la función actualmente desplegada.

**Impacto:** mientras el borrador no esté aplicado en un entorno de ensayo, la confirmación de pago de un gasto desde el panel no puede considerarse compatible con el proyecto activo; Supabase no encontrará una función que acepte ese conjunto de argumentos nombrados.

**Corrección prevista:** mantener la nueva firma de tres parámetros y verificarla después de aplicar el paso 17 en staging. Probar pagos en efectivo sin referencia y pagos por transferencia/tarjeta con referencia, además de rechazo de referencias faltantes, pagos duplicados y usuario sin rol de administrador.

La revisión también confirmó que el trigger activo `business_expenses_guard_update` ya está enlazado a `private.guard_business_expense_update()`, función que el borrador reemplaza. El borrador no necesita crear un segundo trigger, pero la prueba de staging debe comprobar que el trigger sigue instalado después de la migración.

No se ejecutó la RPC ni se modificó la base activa.


## 10. Auditoría complementaria: inventario, costos y checkout (16 nov 2026)

### H-08 — La RPC de ajuste de inventario todavía no existe en la base activa

**Severidad: alta.**

El panel de administrador llama a `adjust_business_inventory` al modificar las existencias de un producto existente. La consulta de catálogo del proyecto activo no encontró esa función ni la tabla `inventory_movements`. Por tanto, el ajuste desde el panel no puede considerarse operativo contra la base actual.

El borrador `database/inventory/inventory-movements-draft.sql` sí define la RPC y utiliza `SELECT ... FOR UPDATE`, además de comparar `p_expected_inventory` con la cantidad actual. Ese control evita que un formulario desactualizado sobrescriba un cambio concurrente. El borrador también exige que el actor sea administrador del negocio activo y que el producto pertenezca al negocio indicado.

**Verificación estática:** la clave compuesta `products(business_id,id)` requerida por la FK del historial existe en la base activa. El panel no incluye `inventory` en el UPDATE general del producto; cuando edita un producto existente, intenta cambiar existencias por la RPC separada.

### H-09 — La base activa permite UPDATE directo de existencias

**Severidad: alta para la integridad del inventario.**

En el proyecto activo, `authenticated` conserva privilegio UPDATE sobre `products.inventory`. El panel evita usarlo y llama a la RPC de ajuste, pero un cliente autenticado puede intentar una actualización directa a través de Data API, sujeta a RLS. Esto permite eludir la validación de cantidad esperada y el motivo obligatorio.

**Corrección preparada:** `database/security/business-admin-boundaries.sql` revoca el UPDATE general de productos y vuelve a conceder únicamente columnas comerciales editables, excluyendo `inventory`, `id` y `business_id`. La creación inicial de productos conserva el valor inicial de inventario. Los cambios posteriores deben pasar por la RPC.

**Pendiente:** validar en staging que checkout y devoluciones puedan seguir descontando o restituyendo inventario mediante funciones de servidor, aunque el rol `authenticated` no tenga UPDATE directo sobre esa columna.

### H-10 — El checkout desplegado no coincide con el contrato de la Edge Function

**Severidad: crítica.**

La Edge Function `create-public-order` invoca estas RPC:
- `get_public_order_idempotent`;
- `reserve_checkout_rate_limit`;
- `create_public_order_idempotent`.

La consulta de catálogo del proyecto activo no encontró ninguna de las tres. Solo encontró la función antigua `public.create_public_order(...)`. La función antigua sí bloquea filas de producto con `FOR UPDATE`, valida inventario y crea pedidos, pero no implementa las RPC de idempotencia que la Edge Function actual necesita.

La función antigua también crea el pedido con estado `pending`, mientras el flujo actual del proyecto usa `received`. Esto se suma al desfase de estados ya descrito en H-01.

**Impacto:** no debe considerarse que el checkout esté integrado solo porque exista una función antigua con nombre parecido. La Edge Function actual no tiene las dependencias RPC que invoca en el proyecto activo.

**Corrección prevista:** desplegar el conjunto completo de funciones de checkout como una unidad en staging, validar firma y permisos, y probar clave idempotente repetida, misma clave con contenido distinto, límite de solicitudes, inventario insuficiente, dos compras concurrentes y pedido creado una sola vez. No ejecutar el checkout real durante esta auditoría.

### H-11 — Los movimientos de inventario necesitan contexto de origen

**Severidad: media-alta para la trazabilidad.**

El trigger del borrador `inventory-movements-draft.sql` registra los cambios de existencias. Si el proceso que descuenta inventario no establece `app.inventory_movement_type` y `app.inventory_movement_reason`, el trigger clasifica el cambio como `adjustment` y usa el motivo genérico. La función antigua `create_public_order` inspeccionada no establece esos valores antes de actualizar `products.inventory`.

**Corrección prevista:** la RPC de checkout debe marcar el contexto como `sale` y la RPC de devolución/cancelación aprobada como `cancellation_return`, con un motivo identificable. El contexto debe establecerse localmente a la transacción y limpiarse o reemplazarse antes de otra operación de inventario en la misma transacción. En staging se debe verificar que cada pedido y devolución genere el tipo correcto y que un reintento no duplique movimientos.

El borrador omite deliberadamente un movimiento inicial cuando el producto se crea con inventario cero, porque la tabla exige `quantity_delta <> 0`. Eso es coherente si se documenta como ausencia de cambio; la prueba de “un movimiento por cada INSERT” debe limitarse a productos cuyo inventario inicial sea mayor que cero.

### H-12 — Guard de confirmación de gastos corregido en el borrador

**Severidad: alta para la confirmación de pagos de gastos.**

La función `private.guard_business_expense_update()` comparaba el JSON de OLD y NEW con listas distintas de campos excluidos: en NEW excluía `transaction_reference`, pero en OLD no. Como resultado, el cambio de estado de pago podía ser rechazado por el trigger incluso cuando la RPC enviaba datos válidos.

**Corrección preparada:** en `database/finance/business-expense-audit-draft.sql` se igualaron las listas de campos excluidos en ambos lados de la comparación. La referencia de transacción queda fuera de la comparación estructural tanto en OLD como en NEW; la RPC sigue siendo responsable de validarla y registrarla.

**Verificación realizada:** se comprobó estáticamente que ambas listas contienen ahora `payment_status`, `payment_method`, `transaction_reference`, `paid_at` y `updated_at`. No se ejecutó el trigger ni la RPC en la base activa.

### H-13 — Guardado de producto y costo no es una sola operación

**Severidad: media.**

El formulario guarda primero el producto y después inserta o actualiza `product_costs` mediante una segunda solicitud. Si falla el segundo paso, el producto ya puede haber quedado guardado, aunque la interfaz muestre un error general de guardado. En la creación, esto puede dejar un producto sin costo registrado; en la edición, puede dejar el costo anterior.

**Corrección prevista:** mostrar explícitamente el resultado parcial y permitir reintentar el guardado del costo sin duplicar el producto. Como mejora de integridad, diseñar una RPC transaccional para guardar producto y costo juntos; la carga de imagen debe seguir tratándose como operación separada con compensación si falla la escritura de base de datos.

### Costos y conservación histórica

La función antigua `create_public_order` guarda el costo unitario de cada línea en `order_item_costs` al crear el pedido. Esa tabla tiene FK compuestas que relacionan el costo histórico con el negocio, pedido y línea correspondiente. Por tanto, la estructura existente está diseñada para conservar el costo histórico aunque el administrador cambie después el costo actual del producto.

La tabla `product_costs` activa permite actualmente UPDATE de `product_id` y `business_id`, además del importe. La migración de límites revoca esos campos y deja UPDATE únicamente sobre `cost_price` y `updated_at`; también elimina el bypass del propietario técnico en las políticas de costos.

### Alcance y límites de esta ronda

- Se consultaron únicamente catálogos, definiciones y privilegios de la base independiente.
- Se revisaron los callsites de `panel-live.js`, la Edge Function de checkout y los borradores SQL de inventario, costos y gastos.
- Se corrigió un borrador SQL; no se aplicó a Supabase.
- No se hicieron compras, ajustes de inventario, cambios de costos, pagos, reembolsos ni cancelaciones.
- No se ejecutaron migraciones, no se desplegaron Edge Functions y no se modificó `main` ni GitHub Pages.
- Las pruebas de concurrencia, autorización por rol y regresión siguen pendientes de staging aislado.


## 11. Auditoría de cancelaciones, devoluciones y restitución de inventario (16 nov 2026)

### H-14 — Las solicitudes de cancelación no tienen RPC de escritura en la base activa

**Severidad: crítica para el flujo de cancelaciones.**

El panel invoca `request_order_cancellation(p_business_id, p_order_id, p_customer_reason)` y `decide_order_cancellation(p_request_id, p_decision, p_admin_response)`. Ninguna de estas funciones aparece en el catálogo de funciones públicas o privadas del proyecto activo.

La tabla `order_cancellation_requests` existe y contiene estados `pending/approved/rejected`, motivo, respuesta, actor y marcas de tiempo. Sin embargo, los privilegios de tabla de `authenticated` solo incluyen `SELECT`; no hay `INSERT` ni `UPDATE`. El panel no puede crear ni resolver solicitudes mediante la Data API, y sus RPC tampoco están disponibles.

**Impacto:** solicitar, aprobar o rechazar una cancelación no puede considerarse operativo contra la base activa. El mensaje de éxito de la interfaz solo se mostraría si la RPC se ejecuta correctamente; hoy la llamada debe fallar por función inexistente.

**Corrección prevista:** crear RPC transaccionales con control de rol y negocio activo. La solicitud debe bloquear el pedido, comprobar que no esté entregado/cancelado y que no exista otra solicitud pendiente. La decisión debe bloquear solicitud y pedido, exigir estado `pending`, registrar actor/fecha/respuesta y cambiar el pedido solo una vez. El rechazo no debe modificar el pedido ni las existencias.

### H-15 — El registro de reembolsos tampoco está operativo

**Severidad: crítica para el control financiero.**

El panel invoca `complete_order_refund(p_order_id, p_refund_method, p_provider, p_reference, p_notes)`, pero esa RPC no existe en el proyecto activo. Las tablas `financial_transactions` y `refund_details` solo conceden `SELECT` a `authenticated`; no hay privilegios de escritura directa para ese rol.

La estructura de datos sí contiene relaciones y restricciones útiles:
- `financial_transactions` exige importe positivo y limita los tipos a `payment_received`, `refund` y `adjustment`.
- `refund_details` referencia una transacción financiera y el pedido del mismo negocio.
- La referencia a la transacción es única en `refund_details`.

Estas restricciones no sustituyen la lógica de negocio que debe impedir reembolsos duplicados. La estructura actual no tiene una restricción única por pedido que garantice por sí sola un único reembolso completo.

**Impacto:** el panel no puede registrar el reembolso por medio de la RPC ausente ni insertar directamente en las tablas. No se debe presentar el pedido como reembolsado hasta que la transacción y el detalle del reembolso se guarden atómicamente.

**Corrección prevista:** la RPC debe bloquear el pedido, comprobar que el pago esté confirmado y que no exista ya un reembolso completado para ese pedido, validar referencia y medio, insertar la transacción y el detalle, y actualizar `orders.payment_status` a `refunded` dentro de la misma transacción. Repetir la llamada debe devolver el resultado anterior o rechazarla sin crear otra transacción.

### H-16 — El propietario técnico conserva lectura global de cancelaciones y devoluciones

**Severidad: alta; incumple la separación entre paneles.**

Las políticas activas `cancellation_members_select`, `financial_admin_select` y `refund_admin_select` incluyen `private.is_platform_owner()` como vía de lectura global. Esto permite que el propietario técnico consulte solicitudes de cancelación, transacciones financieras y detalles de reembolso mediante Data API.

El borrador `database/security/business-admin-boundaries.sql` sustituye esas políticas para limitar la lectura al administrador del negocio activo. Esa corrección aún no está aplicada al proyecto activo.

**Corrección prevista:** retirar el bypass de propietario técnico de estas tablas. Si la plataforma necesita una revisión técnica excepcional, debe realizarse mediante una operación de servidor específica, con alcance mínimo y registro de auditoría, no mediante lectura general desde Data API.

### H-17 — La relación de productos vendidos permite perder la referencia al producto

**Severidad: alta para la trazabilidad de inventario y devoluciones.**

En la base activa, `order_items.product_id` tiene una FK con `ON DELETE SET NULL`. Si un producto se elimina físicamente, la línea histórica del pedido permanece, pero pierde el identificador del producto. Esto complica la restitución de existencias ante una cancelación aprobada y debilita la trazabilidad del movimiento.

El borrador `database/inventory/inventory-movements-draft.sql` cambia esa FK a `ON DELETE RESTRICT`. Además, propone que los productos se desactiven en lugar de eliminarse físicamente, y que los movimientos históricos conserven una FK compuesta a producto y negocio.

**Corrección prevista:** aplicar el cambio solo después de revisar datos existentes y dependencias en staging. La desactivación debe ser el camino normal; la eliminación física debe rechazarse cuando existan líneas de pedido o movimientos históricos.

### H-18 — La restitución automática de inventario aún no está implementada en el proyecto activo

**Severidad: crítica para evitar pérdidas o duplicaciones de stock.**

No se encontraron RPC de cancelación ni reembolso en los esquemas `public` o `private`, y no hay triggers activos en `order_cancellation_requests`, `financial_transactions` o `refund_details` que restituyan existencias. El panel muestra un mensaje que afirma que el inventario fue restituido después de aprobar una cancelación, pero la llamada a `decide_order_cancellation` no puede ejecutarse porque la función no existe.

El borrador de movimientos de inventario define el tipo `cancellation_return`, pero el trigger solo registra el contexto que le entregue la operación que actualiza `products.inventory`. No implementa por sí solo la restitución ni impide que una misma solicitud se procese dos veces.

**Corrección prevista:** en una única RPC transaccional de aprobación:
1. Bloquear solicitud, pedido y líneas relacionadas.
2. Exigir que la solicitud siga pendiente y el pedido sea cancelable.
3. Marcar la solicitud aprobada y el pedido cancelado.
4. Restituir una sola vez la cantidad de cada línea a su producto original.
5. Establecer el contexto de movimiento `cancellation_return` con motivo y referencia al pedido/solicitud.
6. Registrar auditoría y finalizar la transacción.

La RPC debe abortar por completo si falta un producto, una línea no coincide con el negocio o el stock no puede actualizarse. El reembolso de dinero debe ser un proceso separado, ya que una cancelación no demuestra que el dinero haya sido devuelto.

### Pruebas de regresión obligatorias en staging

- Solicitud desde empleado y administrador del negocio A; rechazo de cliente, técnico y administrador B.
- Una sola solicitud pendiente por pedido; reintento de la misma operación.
- Aprobar una solicitud pendiente; verificar un único cambio a `cancelled` y una sola restitución por línea.
- Repetir la aprobación y comprobar que no aumente de nuevo el inventario.
- Rechazar una solicitud y comprobar que pedido e inventario permanezcan intactos.
- Intentar cancelar un pedido entregado, ya cancelado o con solicitud resuelta.
- Pedido con varias líneas, varias unidades y dos productos del mismo negocio.
- Producto desactivado después de la venta: la restitución debe seguir siendo posible.
- Reembolso de pedido pagado, reintento duplicado y dos solicitudes concurrentes.
- Confirmar que el reembolso no cambie inventario por segunda vez.
- Confirmar que el técnico no pueda leer detalles financieros de todos los negocios mediante Data API.

### Alcance y límites

La revisión se hizo sobre catálogos, constraints, privilegios, políticas, triggers y callsites de la rama. No se insertaron solicitudes, no se aprobaron cancelaciones, no se registraron reembolsos ni se modificó inventario. Las RPC y pruebas descritas son trabajo pendiente; no se ha declarado ninguna operación funcional hasta probarla en staging aislado.
