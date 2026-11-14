# Auditoría de permisos del servidor — MiEje Market

**Fecha:** 14 de noviembre de 2026  
**Rama revisada:** `correcciones-funcionales`  
**Proyecto Supabase inspeccionado:** MiEje Market Independiente (`cqixlrwbqatbhzmpygiz`)  
**Alcance:** perfiles bloqueados, membresías suspendidas, negocios suspendidos, pedidos, productos, inventario y datos financieros.

## Resultado ejecutivo

La autorización de las operaciones sensibles está respaldada por RLS, privilegios de columnas, funciones SQL y validaciones en Edge Functions. La función `private.has_business_role` exige que la membresía pertenezca al usuario autenticado, esté activa, tenga uno de los roles permitidos y que el perfil no esté bloqueado. `private.business_is_active` comprueba que el negocio esté activo.

Sin embargo, **la base de datos inspeccionada todavía concede al propietario técnico acceso directo a datos comerciales y operativos de los negocios**. Esto contradice la separación funcional acordada: el panel técnico administra negocios, usuarios y accesos, pero no debe consultar ni modificar directamente los datos comerciales de cada tienda.

La corrección correspondiente ya está preparada en `database/security/business-admin-boundaries.sql`, pero el estado observado en Supabase demuestra que todavía no está aplicada. Por tanto, la separación no puede considerarse terminada en producción.

## Controles verificados

### 1. Perfil bloqueado y membresía suspendida

- `private.has_business_role(p_business_id, p_roles)` verifica `auth.uid()`, `business_memberships.status = 'active'`, rol permitido y `profiles.is_blocked = false`.
- `private.is_platform_owner()` también exige que el perfil propietario no esté bloqueado.
- `resolve-my-access` rechaza perfiles ausentes o bloqueados y solo devuelve membresías activas de negocios activos.
- `technical-business-management` valida el token con `auth.getUser`, consulta el perfil en servidor y rechaza perfiles bloqueados. Las acciones técnicas exigen el rol `platform_owner`; el propietario también debe tener AAL2.
- La suspensión de una membresía es específica del negocio. No debe cerrar globalmente la sesión ni revocar otras membresías válidas.

**Resultado:** los helpers y las funciones de acceso aplican la distinción entre bloqueo global y suspensión por negocio.

### 2. Pedidos

- RLS limita la lectura de pedidos a miembros activos del negocio y al propietario técnico.
- El permiso SQL de actualización de `orders` para `authenticated` se limita a las columnas `status` y `delivery_tracking`; no concede actualización directa de importes, datos del cliente ni estado de pago.
- El trigger `private.enforce_order_status_transition()` exige usuario autenticado, rol activo del negocio o propietario técnico, y valida la transición de estado. Para cancelar exige una solicitud aprobada por el mismo usuario.
- La función pública de checkout valida el negocio activo, el método de pago perteneciente a ese negocio, el perfil del cliente autenticado y el inventario. La creación se realiza en funciones SQL idempotentes y transaccionales.

**Observación:** el trigger actual todavía permite al propietario técnico modificar estados de pedidos. El borrador de límites de administrador sustituye ese comportamiento y reserva la operación a administradores y empleados activos del negocio.

### 3. Productos e inventario

- RLS exige rol `business_admin` para insertar, modificar o eliminar productos.
- Los empleados tienen lectura operativa, pero no reciben permisos de escritura sobre productos.
- Los productos públicos requieren estar activos y pertenecer a un negocio activo.
- El checkout bloquea las filas de producto y descuenta inventario dentro de la transacción de creación del pedido.

**Observación:** la política actual de lectura autenticada permite al propietario técnico consultar productos de todos los negocios. El borrador elimina ese acceso directo. El propietario técnico conserva la gestión técnica mediante funciones autorizadas.

### 4. Finanzas y costos

- Las funciones `register_business_expense`, `pay_business_expense` y `void_business_expense` validan sesión, negocio activo y rol administrador del negocio.
- La política de actualización de gastos está acompañada por el trigger `private.guard_business_expense_update()`, que impide editar libremente los registros y limita las operaciones admitidas.
- El acceso de escritura a gastos no se concede a empleados.
- Los privilegios de columnas de `profiles` solo permiten al usuario actualizar `avatar_url`, `display_name` y `phone`; no puede cambiar su propio rol ni su estado de bloqueo.

**Hallazgo pendiente de corregir:** las políticas actuales todavía incluyen al propietario técnico en la lectura de `business_expenses`, `financial_transactions`, `refund_details`, `product_costs` y `order_item_costs`. También tiene lectura sobre métodos de pago y solicitudes de cancelación. El borrador de límites elimina estos accesos globales directos.

### 5. Negocios y configuración comercial

- Los permisos de columna actuales de `businesses` no incluyen `status` para actualización autenticada, por lo que el administrador comercial no puede suspender o cerrar directamente el negocio mediante esa columna.
- No obstante, la política actual `businesses_admin_update` todavía incluye al propietario técnico y permite que este modifique directamente campos comerciales del negocio.
- Las políticas actuales de `business_payment_methods` también incluyen al propietario técnico.

**Hallazgo pendiente:** aplicar la política del borrador para que solo el administrador activo del negocio modifique su ficha comercial y sus métodos de pago. La gestión técnica del estado del negocio debe permanecer en la Edge Function técnica.

## Corrección preparada y pendiente

Archivo existente en la rama: `database/security/business-admin-boundaries.sql`.

El borrador contiene, entre otras medidas:

1. Retirar el bypass del propietario técnico en las políticas de negocios, productos, pedidos, costos, gastos, pagos, contenido y reembolsos.
2. Limitar la configuración comercial y los métodos de pago al administrador activo de cada negocio.
3. Limitar pedidos y sus líneas a miembros activos del negocio.
4. Retirar el bypass técnico del trigger de transición de estado de pedidos.
5. Mantener la gestión técnica mediante Edge Functions que validan identidad, rol y MFA.

**No se ejecutó el SQL ni se modificó el proyecto Supabase.** Antes de aplicar el borrador hay que revisar la migración completa, comprobar grants y dependencias, ejecutar pruebas con cuentas de propietario, administrador, empleado y cliente, y verificar que las funciones técnicas sigan pudiendo administrar negocios y accesos sin acceso directo al contenido comercial.

## Pruebas pendientes antes de declarar la seguridad terminada

- Perfil bloqueado: no puede leer ni modificar datos privados de ningún negocio.
- Membresía suspendida en A: pierde acceso a A, pero conserva una membresía activa en B.
- Negocio suspendido: sus miembros no pueden leer ni modificar pedidos, productos, inventario ni finanzas operativas.
- Empleado: puede consultar y gestionar solo las operaciones permitidas; no puede modificar catálogo, costos, pagos o configuración financiera.
- Administrador A: no puede consultar ni modificar datos de B.
- Propietario técnico: puede administrar negocios, usuarios, membresías, auditoría y moderación desde la función técnica, pero no consultar pedidos, catálogo, costos, pagos o finanzas privadas mediante el Data API.
- Cliente: no puede consultar pedidos ni datos de otros clientes.
- Checkout público: sigue creando pedidos solo para negocios activos, recalcula importes en servidor y descuenta inventario una sola vez.
- Transiciones de pedidos y cancelaciones: solo se realizan con el rol correcto y la solicitud aprobada correspondiente.

## Estado

- Auditoría de código y políticas actuales: **realizada**.
- Hallazgo principal: **bypass de lectura y configuración comercial del propietario técnico todavía presente en la base de datos observada**.
- Borrador de corrección: **ya existe en la rama**.
- Migración aplicada en Supabase: **no**.
- Pruebas de extremo a extremo con usuarios de cada rol: **pendientes**.
- Despliegue de Edge Functions o publicación: **no realizado**.


## Segunda revisión estática de la migración

Se compararon las políticas actuales de Supabase con los nombres que elimina y recrea `database/security/business-admin-boundaries.sql`.

### Correspondencia de políticas

Los nombres de políticas de la base de datos actual coinciden con los `DROP POLICY` del borrador en las áreas revisadas: negocios, perfiles, membresías, pedidos, líneas de pedido, productos (lectura), métodos de pago, gastos, transacciones financieras, reembolsos, costos, contenido comercial, solicitudes de cancelación y postulaciones.

Las políticas actuales de escritura de productos (`products_admin_insert`, `products_admin_update`, `products_admin_delete`) ya exigen el rol `business_admin` y negocio activo. No se encontró en ellas un bypass de propietario técnico. El borrador mantiene esa restricción y retira el bypass que sí existe en la política de lectura autenticada.

Las políticas actuales de inserción/actualización de páginas comerciales y actualización de postulaciones ya exigen administrador activo; el borrador conserva ese límite y corrige la lectura.

### Privilegios de columnas

El borrador reduce privilegios directos de columnas en las tablas `businesses`, `products`, `business_payment_methods`, `product_costs`, `business_expenses` y `profiles`.

- Productos: el administrador solo recibe UPDATE de campos comerciales y de inventario; no recibe permiso para cambiar `id` ni `business_id`.
- Métodos de pago: no recibe UPDATE de identidad ni pertenencia al negocio; solo de los campos de configuración.
- Costos: solo puede actualizar el precio de costo y la marca de actualización; no puede trasladar el costo a otro producto o negocio.
- Negocios: solo puede actualizar la ficha comercial; el estado de plataforma y los identificadores quedan fuera del grant.
- Perfiles: el usuario puede modificar únicamente nombre visible, avatar y teléfono; no puede cambiar rol ni bloqueo.
- Gastos: el INSERT se limita a campos de captura y la política exige que el nuevo gasto esté pendiente, sin datos de pago ni anulación. El UPDATE se limita a columnas de transición que valida el trigger.

### Validación de los helpers y triggers actuales

- `private.has_business_role` valida usuario, membresía activa, rol permitido y perfil no bloqueado.
- `private.business_is_active` exige estado `active` del negocio.
- `private.guard_business_expense_update` no permite edición libre de gastos; acepta solo el cambio de pendiente a pagado o la anulación, y compara el resto de columnas para detectar alteraciones.
- El borrador reemplaza `private.enforce_order_status_transition` para retirar el bypass del propietario técnico y exigir membresía activa en el negocio.

### Riesgos que todavía requieren atención antes de ejecutar

1. **No se ha validado la sintaxis ejecutando la migración en una base de ensayo.** El proyecto no tiene un entorno de staging disponible. No se debe afirmar que el archivo está listo para producción solo por la revisión estática.
2. **No se han probado los paneles con usuarios de los cuatro tipos** (propietario técnico, administrador, empleado y cliente). En particular, deben comprobarse las consultas de la interfaz que actualmente podrían depender de leer columnas de perfil como `platform_role` o `is_blocked` directamente. El borrador limita esas columnas y el código de cliente debe obtener el acceso autorizado desde `resolve-my-access`.
3. **Debe revisarse el flujo de membresías en la Edge Function técnica** tras revocar INSERT/UPDATE/DELETE directos de `business_memberships`. La función técnica usa `service_role`, por lo que debe seguir pudiendo crear, cambiar y suspender membresías. Esto necesita una prueba real de invitación y asignación.
4. **Debe revisarse la interfaz de empleados** porque el borrador reserva los costos, gastos, pagos y bandeja de cancelaciones al administrador. Las funciones de solicitud de cancelación siguen siendo una vía controlada para empleados; hay que comprobar que la interfaz no intente consultar la bandeja de decisiones.
5. **La tabla `businesses` solo expone por Data API las columnas concedidas en el GRANT.** Las páginas públicas y paneles deben probarse para confirmar que no solicitan columnas internas que ahora quedarán ocultas.
6. **El propietario técnico conserva el acceso de servicio a través de Edge Functions.** Hay que verificar que los endpoints técnicos no devuelvan información operativa privada como parte de sus respuestas generales; esta migración solo limita el Data API directo, no los endpoints con `service_role`.

### Conclusión de esta segunda revisión

No se encontró una política de escritura de productos que permita al propietario técnico modificar el catálogo directamente. Sí se confirmó que las políticas actuales de lectura y varias tablas operativas le permiten consultar datos globales. El borrador aborda esas rutas y restringe los privilegios por columna.

**La migración sigue clasificada como borrador pendiente de ensayo.** La revisión estática reduce la incertidumbre, pero no reemplaza las pruebas de SQL, RLS, Edge Functions y flujos completos. No se aplicó ningún cambio en Supabase.


## Corrección adicional detectada en el flujo MFA del panel técnico

Durante la comprobación de compatibilidad del panel se detectó que, si el panel técnico no alcanzaba AAL2, el cliente llamaba a `auth.signOut()` sin especificar alcance. Se cambió a `auth.signOut({ scope: 'local' })` para cerrar solo la sesión actual y no revocar otras sesiones válidas del mismo usuario en otros dispositivos.

- Archivo: `panel-live.js`
- Cambio guardado en la rama: `correcciones-funcionales`
- Commit: `ecc7eaaab5d31a44f3fbdf57792a01552bf0aa1a`
- Verificación: lectura posterior del archivo confirma el cierre local en la comprobación AAL2.
- No se cambió la función de cierre de sesión voluntario del usuario.

Esta corrección evita que la falta de AAL2 en una sesión del panel técnico cierre accidentalmente otras sesiones del usuario.


## Hallazgo funcional adicional: bloqueo global de una cuenta

La función técnica contiene acciones `block_member` y `unblock_member`, pero ambas modifican el estado de una **membresía concreta** en `business_memberships`. No se encontró una acción técnica para establecer o retirar `profiles.is_blocked` a nivel global.

Esto significa que el control global ya se aplica cuando `profiles.is_blocked = true`, pero la función técnica revisada no ofrece actualmente una operación para activar ese bloqueo global desde el panel. No debe confundirse la suspensión de una membresía con el bloqueo de toda la cuenta.

**Pendiente de decisión funcional:** definir si el panel técnico necesita una acción separada de bloqueo global de cuenta, con motivo obligatorio, confirmación de impacto, auditoría y revocación de sesiones apropiada. No se añadió esa acción en esta revisión para no ampliar privilegios ni alterar cuentas sin especificación aprobada.


## Tercera revisión: consultas de auditoría de los paneles

Se revisaron las consultas de `panel-live.js` frente a la migración de límites de administrador.

### Hallazgo y corrección preparada

El panel técnico ya usaba la Edge Function para listar negocios, miembros, finanzas, moderación y solicitudes de bloqueo. Sin embargo, todavía consultaba `audit_logs` directamente mediante el Data API para obtener el contador y para cargar la tabla global de auditoría. También resolvía los nombres de los actores consultando `profiles` directamente. Esa última consulta deja de ser global cuando se aplica la política de perfiles restringida.

Se ajustó el código de la rama para que:

1. El contador de auditoría del panel técnico use `list_audit_logs` en la Edge Function.
2. La tabla global de auditoría del panel técnico use la misma acción privilegiada y no dependa de SELECT directo sobre `audit_logs` ni `profiles`.
3. La Edge Function agregue `actor_name` a cada evento consultando perfiles desde el contexto `service_role` y devuelva `audit_count` con el conteo exacto.
4. Los paneles de negocio mantengan consultas de auditoría filtradas al negocio propio y la resolución de nombres permitida por la política de perfiles del administrador.

### Compatibilidad restante observada

- `loadSelectedBusiness()` no consulta pedidos, productos ni clientes desde el panel técnico; muestra expresamente que la información comercial solo se administra desde el panel de cada negocio.
- La administración técnica de miembros continúa usando `list_business_members` en la Edge Function, compatible con retirar escrituras directas de membresías al rol `authenticated`.
- El panel administrador consulta las columnas comerciales de `businesses` que el borrador concede y actualiza únicamente el subconjunto autorizado.
- El panel administrador consulta y modifica métodos de pago mediante las políticas y columnas previstas en el borrador.
- El panel empleado consulta pedidos y actualiza únicamente `status` y `delivery_tracking`; no se encontraron consultas a costos, gastos, pagos ni a la bandeja de decisiones de cancelación en su ruta de inicio.
- El administrador consulta costos, gastos, solicitudes de cancelación y postulaciones, áreas que el borrador limita al administrador activo del negocio.

### Estado de validación

Los cambios se guardaron únicamente en la rama `correcciones-funcionales`. La Edge Function no se desplegó y la migración no se ejecutó. Se requiere validación de sintaxis TypeScript/JavaScript y prueba integrada en un entorno de ensayo antes de considerar el flujo operativo.


## Cuarta revisión: RPC de pedidos, cancelaciones, pagos, reembolsos y gastos

Se contrastaron las llamadas de `panel-live.js` con las funciones SQL preparadas para la base de datos.

### Resultado de autorización por operación

- `get_business_admin_order_financials`: el RPC exige `business_admin` activo del negocio solicitado. El panel administrador lo utiliza para totales y pedidos con datos financieros. El panel empleado no lo invoca.
- `get_business_admin_profit_report`: exige `business_admin` activo y devuelve el informe financiero del negocio. Solo se llama desde la ruta de administración.
- `mark_order_payment_received`: exige `business_admin` del negocio del pedido, comprueba que el pedido siga pendiente de pago y registra el movimiento de ingreso. La interfaz solo muestra la acción de confirmar pago al administrador.
- `request_order_cancellation`: admite `business_admin` y `employee` activos del negocio; exige motivo, bloquea el pedido y evita solicitudes pendientes duplicadas. La interfaz permite al empleado registrar la solicitud, pero no decidirla.
- `decide_order_cancellation`: exige `business_admin` activo del negocio asociado; valida que la solicitud siga pendiente y que el pedido no haya terminado. La bandeja y los botones de decisión solo se cargan en el panel administrador.
- `complete_order_refund`: exige `business_admin` activo, pedido cancelado y pago conciliado por el importe exacto; exige referencia del reembolso y evita registrar dos reembolsos completados.
- `register_business_expense`, `pay_business_expense`, `void_business_expense` y `attach_business_expense_receipt`: exigen `business_admin` activo del negocio y rechazan expresamente al propietario técnico. Las acciones de gastos solo se cargan en el panel administrador.

### Protección de pedidos y datos financieros

- El borrador retira la lectura general de `orders` y concede a los paneles únicamente columnas operativas. Importes, método y estado de pago se entregan al administrador mediante RPC validado.
- Empleados y administradores leen nombres y cantidades de `order_items`, no precios unitarios ni totales de línea.
- La actualización directa de pedidos queda limitada a `status`, `delivery_tracking` y `updated_at`; el trigger valida negocio activo, rol y transición permitida.
- La transición a `cancelled` requiere una solicitud aprobada por el mismo usuario que ejecuta el cambio. La aprobación y el cambio de estado se realizan en la función de decisión.
- Las solicitudes de cancelación solo son legibles por administradores; empleados únicamente pueden crearlas mediante la función controlada.

### Diferencia de vocabulario del flujo de pedidos pendiente de decisión

El código actual y los borradores coinciden entre sí en estos estados: `pending → confirmed → preparing → ready → out_for_delivery → delivered`, además de `cancelled`. Esto no coincide literalmente con la nomenclatura funcional solicitada anteriormente (`received` y `on_the_way`). No se cambió el flujo en esta revisión porque implica actualizar conjuntamente creación del pedido, restricciones de base de datos, trigger, etiquetas, filtros, seguimiento e historial. Debe normalizarse en una corrección dedicada antes de pruebas finales para evitar estados incompatibles.

### Estado

Esta revisión no encontró una llamada de la interfaz que permita al empleado confirmar pagos, registrar reembolsos, consultar reportes financieros o administrar gastos. Las restricciones críticas están en funciones SQL y triggers, no dependen solo de ocultar botones. El resultado es una revisión estática de los borradores: no demuestra que las funciones estén instaladas ni que el comportamiento se haya probado en Supabase.


## Quinta revisión: aislamiento entre negocios, relaciones y Edge Functions

Se contrastaron las funciones SQL instaladas en Supabase, las políticas RLS y los privilegios actuales con las versiones preparadas en `correcciones-funcionales`.

### 1. Relaciones entre negocios y registros operativos

Las relaciones compuestas instaladas ofrecen una protección importante frente a identificadores cruzados:

- `order_cancellation_requests(business_id, order_id)` referencia conjuntamente el negocio y el pedido.
- `financial_transactions(business_id, order_id)` exige que el movimiento pertenezca al mismo negocio que el pedido.
- La relación financiera de una cancelación también comprueba negocio, pedido y solicitud.
- `refund_details` relaciona negocio, pedido y transacción financiera en conjunto.
- `product_costs(business_id, product_id)` exige que el producto pertenezca al negocio indicado.
- `order_item_costs` comprueba la relación con el pedido y la línea correspondiente.

Estas restricciones reducen el riesgo de asociar accidentalmente un pago, reembolso, costo o cancelación con un pedido de otra tienda.

**Punto a conservar en las siguientes migraciones:** `order_items` tiene actualmente claves foráneas simples hacia `orders(id)` y `products(id)`, no una clave compuesta que obligue a que el producto y el pedido sean del mismo negocio. El checkout instalado sí comprueba `products.business_id = p_business_id` antes de insertar cada línea, y los roles `anon` y `authenticated` no tienen INSERT directo en `order_items`; por tanto, no se identificó una ruta directa para que un cliente fuerce esa mezcla. Aun así, conviene reforzar la integridad relacional con una FK compuesta o trigger de consistencia en una migración futura, especialmente porque `service_role` sí tiene privilegios de escritura.

### 2. Funciones SECURITY DEFINER y permisos de ejecución

La consulta de funciones instaladas encontró que las funciones públicas privilegiadas revisadas tienen `search_path` vacío y no conceden ejecución a `anon` ni a `authenticated`. Las funciones de checkout, postulación y límites de solicitudes quedan ejecutables por `service_role`; las funciones privadas de soporte no se exponen directamente al cliente.

La función instalada `create_public_order` valida que el negocio esté activo y que cada producto seleccionado pertenezca al `p_business_id` recibido, esté activo y tenga inventario suficiente. Bloquea la fila del producto con `FOR UPDATE`, recalcula los precios en servidor y descuenta inventario dentro de la misma transacción. No confía en los precios enviados por el navegador.

La función `submit_public_job_application` comprueba que la página de vacante pertenezca al negocio indicado, esté publicada, aprobada y sea de tipo `job_form`. Cuando hay hoja de vida, exige una sesión de carga que coincida en identificador, negocio, página y ruta del archivo, y que no haya vencido ni sido consumida.

**Resultado:** no se encontró una concesión de ejecución directa de estas funciones privilegiadas a usuarios públicos o autenticados. La validación de pertenencia negocio-producto en el checkout y negocio-vacante en la postulación se realiza en servidor.

### 3. Edge Functions que usan service_role

Se revisaron las funciones instaladas de checkout, seguimiento público, directorio de pagos, postulaciones, acceso y administración técnica.

- `create-public-order`: la versión instalada valida que el método de pago pertenezca al mismo `business_id`, esté habilitado y que la función SQL valide los productos para ese negocio. Sin embargo, la versión desplegada todavía llama a `create_public_order` directamente, no asocia el pedido a una cuenta de cliente y no utiliza la clave idempotente. La versión más reciente del repositorio ya incorpora validación del JWT del cliente, rechazo de perfiles bloqueados, vinculación de `customer_user_id`, consulta/reserva idempotente y límites de solicitudes. **La corrección existe en la rama, pero no está desplegada ni puede considerarse activa en Supabase.**
- `get-public-storefront`: la versión desplegada selecciona los identificadores de los negocios activos y devuelve los métodos de pago habilitados. La versión instalada consultaba las columnas sin incluir `id`, aunque después intentaba devolver `method.id`; esto hace que el identificador llegue indefinido al navegador y puede impedir que el checkout envíe un método de pago válido. La versión de la rama ya incluye `id` en el SELECT y lo devuelve. **Es una discrepancia funcional confirmada entre el despliegue y el código corregido.**
- `track-public-order`: consulta por un token privado de seguimiento y devuelve únicamente número, estado, fechas, seguimiento de entrega, total y nombre del negocio; no devuelve dirección, teléfono, correo ni líneas del pedido. La versión de la rama agrega `Cache-Control: no-store, private`, pero la instalada no lo incluye. Conviene desplegar la corrección antes de usar seguimiento con pedidos reales y añadir limitación de consultas por token/IP como endurecimiento adicional.
- `create-job-application`: verifica negocio activo y página publicada/aprobada del mismo negocio antes de crear la sesión de carga o enviar la postulación. La ruta de la hoja de vida se genera en servidor con prefijo de negocio y aplicación; la RPC vuelve a comprobar la relación con la sesión de carga. La función usa límites por IP.
- `technical-business-management`: exige JWT válido, perfil no bloqueado y rol de propietario técnico antes de las acciones administrativas. La lista de miembros se filtra por el `business_id` solicitado; la consulta global de negocios y auditoría es deliberada y corresponde a las funciones del panel técnico, no a una consulta del catálogo o los pedidos privados.

### 4. Políticas y privilegios instalados frente al borrador

La lectura actual de Supabase confirma que todavía existen bypass del propietario técnico en RLS para pedidos, líneas, productos, métodos de pago, costos, gastos, transacciones financieras, reembolsos y solicitudes de cancelación. También conserva acceso de actualización de la ficha comercial. Los roles de usuario no tienen INSERT directo sobre pedidos ni líneas; la creación se realiza mediante las funciones de servidor.

El archivo `database/security/business-admin-boundaries.sql` elimina esos bypass y limita las consultas operativas a miembros activos del negocio correspondiente. Los privilegios actuales de escritura de `products`, `business_payment_methods` y `product_costs` todavía son amplios a nivel de tabla para `authenticated`; el borrador los sustituye por permisos de columna que impiden cambiar identificadores o trasladar registros a otro negocio.

### 5. Hallazgos y acciones pendientes

1. **Prioridad funcional alta — métodos de pago:** la Edge Function instalada no devuelve `id` en su consulta, aunque el frontend lo necesita para el valor del selector. La rama ya contiene la corrección; falta desplegarla y probar un checkout completo.
2. **Prioridad de integridad — checkout:** la función instalada no usa idempotencia ni vincula los pedidos de clientes autenticados con su cuenta. La rama contiene la implementación y la migración correspondiente, pero ambas siguen pendientes de ensayo y despliegue.
3. **Privacidad — seguimiento:** la función instalada debe incorporar respuesta `no-store`; se recomienda limitar intentos de consulta. El token privado funciona como credencial de acceso al resumen del pedido y no debe publicarse en registros o enlaces compartidos.
4. **Integridad relacional — líneas de pedido:** estudiar una clave foránea compuesta que garantice que cada producto de una línea corresponde al mismo negocio del pedido. Actualmente el checkout valida esta relación en el servidor y no hay INSERT directo para clientes.
5. **Prueba IDOR pendiente:** no se pudo ejecutar una prueba real con dos negocios y usuarios de roles distintos porque no hay datos de negocios, pedidos y cuentas de prueba suficientes. La revisión de código y restricciones no equivale a una prueba de explotación ni a una prueba E2E.

### Conclusión de la quinta revisión

No se identificó en las rutas de checkout y postulación revisadas una validación que acepte un producto o una vacante perteneciente a otro negocio. Las claves foráneas compuestas de pagos, cancelaciones, reembolsos y costos aportan integridad adicional. No obstante, el aislamiento completo **todavía no está aplicado en la base de datos**: las políticas instaladas conservan accesos globales del propietario técnico y la versión desplegada de algunas Edge Functions está atrasada respecto de la rama.

No se ejecutó SQL, no se desplegó ninguna Edge Function y no se modificó producción durante esta revisión. Los cambios del repositorio continúan limitados a la rama `correcciones-funcionales`.


## Sexta revisión: Storage, hojas de vida y comprobantes privados

Se inspeccionaron los buckets, las políticas instaladas de `storage.objects`, el código de carga y descarga del panel y las migraciones de Storage preparadas en la rama.

### 1. Buckets existentes en Supabase

La consulta de solo lectura encontró estos buckets:

- `business-assets`: público, límite 5 MB, admite PNG, JPEG y WEBP. Su lectura pública es coherente con logos e imágenes de productos que deben aparecer en el catálogo.
- `job-applications-private`: privado, límite 5 MB, admite PDF, DOC y DOCX. Es correcto que las hojas de vida no sean públicas.
- `business-expense-receipts`: todavía no existe en la base observada. El borrador `database/finance/expense-receipts-storage-draft.sql` lo crea como bucket privado, con límite de 5 MB y tipos PDF/JPEG/PNG/WEBP.

La consulta de objetos no devolvió registros para los buckets inspeccionados. Por eso no fue posible comprobar archivos reales, rutas históricas ni descargas con usuarios.

### 2. Hallazgo en las políticas de business-assets

Las cuatro políticas instaladas para insertar, leer, actualizar y eliminar objetos de `business-assets` contienen una referencia incorrecta: dentro de la subconsulta comparan el UUID de negocio con `storage.foldername(b.name)`, donde `b` es la tabla `businesses`. La ruta del archivo debe obtenerse de `storage.objects.name`, no del nombre comercial del negocio.

Esto puede impedir que el administrador gestione sus logos e imágenes desde el panel. El bucket es público, así que la visualización pública de archivos ya almacenados no depende de esa política SELECT; el problema principal afecta la gestión autenticada de los objetos.

El borrador `database/security/storage-policy-fix.sql` reemplaza la referencia incorrecta por la ruta real del objeto y valida que:
- el primer segmento sea un UUID de negocio;
- el segundo segmento sea `logo` o `products`;
- el negocio esté activo;
- el usuario sea administrador activo de ese negocio.

La ruta esperada es `<business_uuid>/logo/<archivo>` o `<business_uuid>/products/<archivo>`. Debe comprobarse que el frontend usa exactamente esa estructura antes de ejecutar la migración.

### 3. Hojas de vida: bucket privado y autorización

La función `create-job-application` genera el nombre de archivo en servidor, bajo la ruta `<business_uuid>/<application_uuid>/<random_uuid>.(pdf|doc|docx)`. Crea una sesión de carga de corta duración y entrega un token de carga firmado. Al enviar la postulación, vuelve a comprobar que la sesión corresponda al negocio, vacante, ruta y aplicación, que no esté vencida ni consumida, y que el objeto exista y no supere 5 MB.

El panel administrador filtra las postulaciones por su `business_id` y solicita enlaces firmados de descarga de 5 minutos para las hojas de vida. No genera enlaces públicos permanentes.

**Hallazgo en la política instalada:** `job_application_documents_business_admin_read` solo comprueba el bucket, el primer segmento de negocio y el rol administrador. No valida que el segundo segmento sea un UUID de aplicación ni que el nombre final sea un UUID con extensión permitida. El bucket sigue siendo privado y la comprobación de negocio impide que el administrador de otra tienda obtenga acceso por cambiar el identificador de negocio, pero la política permite a un administrador de ese mismo negocio leer objetos huérfanos o rutas que no corresponden a una postulación registrada.

El borrador de `storage-policy-fix.sql` endurece la estructura de la ruta y valida el nombre del archivo. Antes de producción conviene reforzarlo también con una comprobación contra `job_applications`: que el UUID de aplicación del segundo segmento exista, pertenezca al primer UUID de negocio y que `resume_path` coincida exactamente con `storage.objects.name`. Así se evita que una ruta bien formada pero ajena a una postulación registrada sea descargable.

### 4. Comprobantes privados de gastos

El panel ya implementa la carga en `business-expense-receipts` con ruta `<business_uuid>/<expense_uuid>/<random_uuid>.<extension>`. La carga se hace después de crear el gasto; la función `attach_business_expense_receipt` del borrador comprueba:
- que el usuario sea administrador activo del negocio propietario del gasto;
- que el gasto esté activo y todavía no tenga comprobante;
- que la ruta comience con el UUID exacto del negocio y del gasto;
- que el objeto exista en el bucket privado;
- que el comprobante se asocie una sola vez.

El panel genera enlaces firmados temporales de 5 minutos para ver comprobantes. El borrador no crea políticas de UPDATE o DELETE, conservando la evidencia original. La política de lectura también comprueba que el gasto y el negocio de la ruta coincidan y que el administrador pertenezca a ese negocio.

**Estado:** el diseño de acceso está bien delimitado en el borrador, pero el bucket y las políticas todavía no existen en la base observada. La función SQL y la UI no se han probado con un archivo real.

### 5. Límites de validación de archivos

La función de postulaciones valida extensión declarada, MIME declarado y tamaño, y el bucket limita tamaño y MIME permitido. El comprobante también valida MIME y tamaño en el navegador y en las restricciones del bucket.

Estas comprobaciones no equivalen a inspeccionar el contenido binario. No se encontró un antivirus ni una validación real de tipo de archivo por firma binaria. Antes de abrir cargas a público conviene añadir inspección de contenido, protección frente a archivos maliciosos y una política de retención/borrado para postulaciones que ya no deban conservarse.

### 6. Resultado y acciones pendientes

1. Corregir las cuatro políticas de `business-assets` con el borrador y confirmar que el frontend usa las rutas esperadas.
2. Reforzar la política de lectura de hojas de vida para exigir una postulación registrada cuya ruta coincida exactamente con el objeto.
3. Crear el bucket privado de comprobantes y aplicar sus políticas junto con las funciones de auditoría de gastos, después de revisar el paquete completo.
4. Incorporar validación binaria y controles antimalware para hojas de vida y comprobantes.
5. Probar con dos negocios: el administrador A debe poder subir/descargar archivos de A y recibir denegación al intentar usar rutas de B; empleados y clientes no deben poder obtener enlaces firmados.
6. Probar que la lectura pública de logos/productos sigue funcionando y que el administrador puede reemplazar y eliminar solo archivos de su negocio.

### Conclusión de la sexta revisión

Se confirmó un error real en las políticas instaladas de gestión de imágenes: usan el nombre del negocio en lugar del nombre del objeto para comprobar la ruta. También se detectó que la política instalada de lectura de hojas de vida valida el negocio y el rol, pero no vincula la ruta con una postulación concreta. El bucket privado reduce la exposición, aunque la política debe endurecerse.

El diseño de comprobantes privados está preparado en los borradores, pero no está instalado. No se encontraron objetos en Storage durante la consulta, así que no hubo datos reales para realizar pruebas de lectura o descarga.

No se ejecutó SQL, no se modificaron buckets, no se desplegaron funciones y no se cambiaron políticas en Supabase. Esta revisión fue de solo lectura en el proyecto y de análisis estático de los archivos de la rama.


### Ajuste posterior a la sexta revisión

Se reforzó el borrador `database/security/storage-policy-fix.sql` para que la política de lectura de `job-applications-private` no se limite a validar el UUID del negocio y el rol. Ahora también exige que el segundo segmento de la ruta corresponda al ID de una postulación existente, que esa postulación pertenezca al mismo negocio y que `job_applications.resume_path` coincida exactamente con el nombre del objeto.

La comprobación se verificó leyendo nuevamente el archivo de la rama. También se comprobó que esta condición quedó dentro de la política del bucket privado y no se añadió accidentalmente a las políticas de `business-assets`.

- SHA del borrador actualizado: `49b002e7621da70594adc64960b32b24f813e45e`.
- Rama: `correcciones-funcionales`.
- No se ejecutó la migración ni se cambió la política instalada en Supabase.


## Séptima revisión: Storage, hojas de vida y comprobantes privados

**Fecha:** 14 de noviembre de 2026  
**Alcance:** buckets, políticas instaladas de `storage.objects`, rutas de archivos, Edge Function `create-job-application` y RPC de postulaciones.

### Estado observado directamente en Supabase

Los buckets existentes son:

- `business-assets`: público, límite de 5 MB, permite PNG, JPEG y WebP.
- `job-applications-private`: privado, límite de 5 MB, permite PDF, DOC y DOCX.
- No se encontraron objetos almacenados en ninguno de los buckets consultados en esta revisión.

El bucket `business-expense-receipts` todavía no existe. Su creación está contemplada en `database/finance/expense-receipts-storage-draft.sql`, que permanece pendiente.

### Hallazgos críticos y correcciones pendientes

1. **Las políticas instaladas de `business-assets` contienen una referencia de ruta incorrecta.** En las expresiones actuales se usa `storage.foldername(b.name)` dentro de la subconsulta de negocios, cuando la ruta debe derivarse del nombre del objeto (`storage.objects.name`). Esto puede impedir que el administrador gestione correctamente sus imágenes y no constituye una comprobación fiable de pertenencia. El archivo `database/security/storage-policy-fix.sql` corrige esa referencia y valida el UUID del negocio, la carpeta permitida (`logo` o `products`) y la membresía activa del administrador.

2. **La política instalada de lectura de hojas de vida es demasiado amplia dentro de la carpeta del negocio.** Actualmente comprueba la carpeta del negocio y el rol de administrador, pero no relaciona el objeto con una fila concreta de `job_applications` ni verifica que `resume_path` coincida exactamente con el objeto. El borrador añade esas comprobaciones, valida la carpeta de aplicación y el nombre UUID del archivo, y exige que la postulación pertenezca al mismo negocio. Debe aplicarse antes de habilitar la descarga de CVs en producción.

3. **La ruta de carga de CV está vinculada a una sesión temporal.** `create-job-application` genera en servidor el identificador de postulación, la ruta del objeto y una URL firmada de carga de un solo uso. Antes de registrar la postulación, comprueba que la sesión coincida con el negocio, la vacante, la ruta y la fecha de vencimiento; también comprueba que el archivo se haya cargado y que su tamaño no supere 5 MB. La RPC `submit_public_job_application` repite la validación de vacante y consume la sesión dentro de una transacción.

4. **Falta validación del contenido real del archivo.** La función valida extensión, MIME declarado y tamaño, pero no inspecciona la firma binaria del archivo ni ejecuta análisis antimalware. El MIME enviado por el navegador no demuestra el formato real. Antes de abrir las postulaciones al público se necesita una validación adicional del contenido y un proceso de revisión segura de documentos.

5. **Las funciones `SECURITY DEFINER` de postulaciones no son ejecutables por `anon` ni por `authenticated`.** Se verificaron los privilegios efectivos de `submit_public_job_application` y `consume_job_application_rate_limit`: ambos permiten ejecución a `service_role`, no a los roles públicos o de usuario. La Edge Function actúa como intermediaria y valida la vacante y la sesión antes de llamar a la RPC.

6. **Los comprobantes de gastos aún no tienen almacenamiento desplegado.** El borrador configura un bucket privado y políticas de lectura/carga asociadas a un gasto y a su negocio. No crea permisos de modificación o eliminación, lo cual conserva los comprobantes como evidencia. La descarga debe realizarse mediante enlaces firmados de corta duración, después de validar el acceso del administrador.

### Consideración sobre el bucket público

`business-assets` es público por configuración. Por tanto, las políticas RLS no convierten en privadas las imágenes de ese bucket: cualquier persona que conozca la URL pública puede leer el objeto. Este comportamiento es apropiado únicamente para logos e imágenes de productos que deban mostrarse en la tienda. No deben almacenarse allí hojas de vida, comprobantes, documentos de clientes ni archivos internos.

### Acciones necesarias antes de producción

- Aplicar y probar `database/security/storage-policy-fix.sql` en un entorno de pruebas.
- Probar que un administrador A pueda gestionar archivos de A y no leer, reemplazar o borrar archivos de B.
- Probar que un empleado y un cliente no puedan descargar hojas de vida.
- Probar que una postulación solo permita acceder al archivo exacto registrado en `resume_path`.
- Incorporar validación de firma de archivo y análisis antimalware para CVs.
- Crear y probar el bucket privado de comprobantes mediante su migración correspondiente.
- Verificar que las Edge Functions que generan enlaces firmados validen primero la pertenencia del archivo al negocio y la membresía activa.

### Resultado

- Buckets y políticas instaladas: **inspeccionados en lectura**.
- Archivos actuales: **no se encontraron objetos**.
- Error de referencia en políticas de `business-assets`: **confirmado**.
- Lectura de CV sin vínculo exacto con la postulación: **confirmada como brecha de alcance**.
- Borradores de corrección: **ya existen en la rama**.
- SQL aplicado o bucket nuevo creado: **no**.
- Pruebas de carga y descarga con cuentas de distintos negocios: **pendientes**.
- Validación antimalware y de firma binaria: **pendiente**.


## Octava revisión: Edge Functions, enlaces firmados y acceso a documentos

**Fecha:** 14 de noviembre de 2026  
**Alcance:** flujo de descarga de hojas de vida, acceso a comprobantes, autorización de paneles, RLS de postulaciones y RPC de asociación de comprobantes.

### 1. Hojas de vida: el acceso se genera desde el panel administrador

La interfaz `panel-live.js` carga postulaciones únicamente cuando `panel === 'business_admin'`. Antes de cargar el panel valida la membresía devuelta por `resolve-my-access`, exige rol `business_admin` y fija el `businessId` a partir de esa membresía. El panel de empleados no ejecuta `loadJobApplications()`.

La consulta de postulaciones filtra por `business_id`, y la política RLS instalada `job_applications_business_admin_read` exige `private.has_business_role(business_id, ['business_admin'])`. La política de actualización también exige administrador del negocio y negocio activo. Por tanto, el filtro del navegador no es la única barrera: la autorización efectiva se realiza en la base de datos.

Para cada postulación, el panel solicita un enlace firmado de cinco minutos mediante Storage. El enlace no lo genera una Edge Function propia; lo genera Supabase Storage a partir de la sesión autenticada. La autorización depende de la política SELECT de `storage.objects`. En la política instalada, esa lectura comprueba el negocio y el rol administrador, pero no relaciona el objeto con la postulación exacta. El borrador `database/security/storage-policy-fix.sql` corrige esa brecha exigiendo coincidencia entre el segundo segmento de la ruta, `job_applications.id`, `business_id` y `resume_path`.

**Conclusión:** el panel restringe correctamente la consulta de postulaciones al administrador y el negocio asignado; la descarga de CV seguirá necesitando la corrección de Storage antes de considerarse aislada por documento.

### 2. Comprobantes de gastos: validación por RLS y ruta

La interfaz obtiene el comprobante asociado consultando `business_expenses` por `id` y `business_id`, y genera un enlace firmado de cinco minutos. Para cargarlo, construye una ruta con el negocio, el gasto y un UUID aleatorio, usa `upsert: false` y después llama a `attach_business_expense_receipt`.

La migración borrador `database/finance/expense-receipts-storage-draft.sql` crea el bucket privado y permite lectura/carga solo si el objeto está asociado a un gasto cuyo `id` y `business_id` coinciden con los dos segmentos de la ruta. La carga requiere administrador activo y gasto activo; la lectura conserva acceso administrativo a gastos activos o anulados para auditoría. No crea políticas UPDATE ni DELETE.

El borrador `database/finance/business-expense-audit-draft.sql` valida en `attach_business_expense_receipt` que el gasto pertenezca al administrador autenticado, que la ruta tenga el prefijo exacto negocio/gasto y que el objeto exista en el bucket. También impide asociar un segundo comprobante cuando ya existe uno.

**Limitación importante:** en el proyecto Supabase consultado no existe todavía el bucket `business-expense-receipts`, y la RPC `attach_business_expense_receipt` no está instalada. El código de interfaz y las migraciones están preparados, pero esa parte no puede funcionar en el proyecto live hasta aplicar y probar las migraciones.

### 3. Revisión de Edge Functions

En el proyecto independiente se encontraron activas las funciones `technical-business-management`, `create-public-order`, `track-public-order`, `resolve-my-access`, `get-public-storefront` y `create-job-application`. No existe una Edge Function independiente para emitir enlaces firmados de CV o comprobantes. El diseño actual utiliza Storage directamente con la sesión del usuario y políticas RLS, lo cual es válido si las políticas de lectura están correctamente limitadas.

La Edge Function `create-job-application` usa `service_role` para crear sesiones de carga y registrar postulaciones. Antes de operar, valida que el negocio esté activo y que la página de empleo pertenezca a ese mismo negocio, sea una vacante publicada y esté aprobada. La RPC de registro repite la relación entre página y negocio, y consume la sesión de carga vinculada al mismo negocio y página. Sus privilegios efectivos están limitados a `service_role`; no permiten ejecución directa a `anon` ni a `authenticated`.

### 4. Hallazgos y acciones pendientes

- **Confirmado:** los empleados no cargan la bandeja de postulaciones desde el panel; solo la rama de administrador lo hace.
- **Confirmado:** RLS de postulaciones limita lectura/actualización a administradores del negocio.
- **Pendiente de aplicar:** política de Storage que vincula el archivo CV con la postulación exacta.
- **Confirmado:** la emisión de enlaces firmados se hace desde el cliente autenticado y depende de RLS; no hay una Edge Function separada de descarga.
- **Pendiente de desplegar:** bucket privado de comprobantes y RPC `attach_business_expense_receipt`.
- **Pendiente:** validar firma binaria y analizar malware en documentos recibidos.
- **Pendiente de pruebas:** intentar acceder a un CV o comprobante de otro negocio manipulando IDs y rutas, con cuentas reales separadas.
- **Pendiente:** comprobar el comportamiento de enlaces firmados ya emitidos después de suspender una membresía; la expiración corta limita su vigencia, pero no revoca inmediatamente un enlace ya emitido.

### Resultado

Esta revisión fue de lectura del código en `correcciones-funcionales` y consultas de solo lectura al proyecto Supabase independiente. No se emitieron enlaces reales, no se cargaron archivos, no se probaron cuentas de dos negocios, no se ejecutó SQL y no se desplegaron Edge Functions.


## Novena revisión: cuentas de clientes, historial, favoritos y datos personales

**Fecha:** 14 de noviembre de 2026  
**Alcance:** estructura live de `orders`, `order_items` y `profiles`; políticas RLS y grants; migraciones de cuenta e historial; Edge Functions de checkout y seguimiento público.

### 1. Estado real de la base de datos

En el proyecto Supabase independiente:

- `orders`, `order_items` y `profiles` tienen RLS habilitado.
- `orders.customer_user_id` todavía no existe.
- La tabla `customer_favorites` todavía no existe.
- No está instalada la RPC `get_customer_order_history()` ni la función privada `private.customer_owns_order(uuid)`.
- `public_tracking_token` sí existe, es NOT NULL y tiene `gen_random_uuid()` como valor predeterminado.
- `profiles` concede SELECT a usuarios autenticados, limitado por RLS. No se concedió SELECT a `anon`.

Por tanto, el historial de compras asociado a cuentas y los favoritos todavía no están activos en el proyecto live. Los pedidos de invitado se guardan con datos de contacto, pero aún no hay una columna que los vincule a la cuenta autenticada.

### 2. Brecha live de lectura global en pedidos

Las políticas instaladas `orders_members_select` y `order_items_members_select` incluyen una condición OR para `private.is_platform_owner()`. Esto permite al propietario técnico leer globalmente las filas de pedidos y sus líneas, independientemente del negocio.

El borrador `database/orders/order-financial-access-draft.sql` retira los grants generales de lectura y concede a los paneles únicamente columnas operativas; también deja los importes detrás de RPCs que validan el rol de administrador. La revisión anterior ya identificó esta brecha, y la consulta live confirma que todavía existe en el proyecto independiente.

La política global del propietario técnico puede ser útil para soporte y auditoría, pero expone información personal y comercial de todos los pedidos mediante acceso directo a tablas. Debe retirarse de las consultas generales y reemplazarse por operaciones técnicas específicas, con campos mínimos y registro de auditoría. No se debe aplicar el borrador sin probar primero cada panel y las funciones que hoy consultan las tablas directamente.

### 3. Acceso de administradores y empleados a datos de compradores

Las políticas live permiten a miembros activos del negocio consultar los pedidos de su propio negocio y las líneas correspondientes. Los pedidos contienen nombre, teléfono, correo, dirección de entrega y notas. Estos datos son necesarios para preparar y entregar compras, pero deben permanecer limitados al personal asignado a ese negocio.

El borrador financiero reduce las columnas directas y separa las consultas de importes. Aun después de aplicarlo, debe comprobarse que cada empleado vea únicamente los datos de entrega necesarios para sus tareas y que ningún panel de otro negocio pueda consultar esos pedidos.

### 4. Historial de compras: diseño del borrador

`database/customers/customer-account-migration.sql` añade `orders.customer_user_id` con referencia a `auth.users(id)` y `ON DELETE SET NULL`. Esto permite conservar los registros comerciales si una cuenta se elimina, sin mantener una asociación personal activa.

`database/orders/order-financial-access-draft.sql` define `get_customer_order_history()` como función `SECURITY DEFINER`, con `search_path = ''`. Obtiene el usuario mediante `auth.uid()`, rechaza cuentas bloqueadas, filtra por `customer_user_id = auth.uid()` y limita el historial a 50 pedidos. Devuelve datos del pedido, nombre del negocio y líneas con precios. No acepta un ID de usuario como argumento, por lo que el cliente no puede solicitar el historial de otra cuenta cambiando un parámetro.

El mismo borrador crea `private.customer_owns_order(uuid)`, que verifica propiedad con `auth.uid()`, y limita la lectura de líneas de pedido al cliente dueño. Los privilegios de ejecución se revocan a `PUBLIC` y `anon`, y se conceden a `authenticated`.

### 5. Favoritos: diseño del borrador

La migración de clientes crea `customer_favorites` con RLS y reglas de propiedad:

- SELECT y DELETE solo cuando `user_id = auth.uid()`.
- INSERT solo para el usuario autenticado y productos activos de negocios activos.
- No concede UPDATE, evitando reasignar un favorito a otra cuenta.
- La restricción UNIQUE `(user_id, product_id)` evita favoritos duplicados.
- Al eliminar la cuenta se eliminan sus favoritos; al eliminar un producto se elimina su relación de favorito.

El diseño es correcto a nivel estático, pero no se ha probado con dos cuentas reales ni está instalado en Supabase.

### 6. Checkout autenticado y seguimiento público

La versión de `create-public-order/index.ts` en la rama valida el JWT del comprador mediante `auth.getUser()`, consulta el perfil y rechaza cuentas bloqueadas. Solo después asigna el ID verificado a `p_customer_user_id`; no confía en un ID de usuario enviado en el JSON del navegador. Para invitados mantiene ese campo en NULL. La vinculación efectiva depende de aplicar las migraciones de cliente e idempotencia.

La función `track-public-order` consulta mediante el token UUID y devuelve número de pedido, estado, fechas, seguimiento, total y nombre del negocio. No devuelve nombre, teléfono, correo ni dirección del comprador. Las respuestas incluyen `Cache-Control: no-store, private`. El token actúa como credencial de acceso al seguimiento: debe tratarse como secreto, no mostrarse en listados públicos ni registrarse en analítica o logs de terceros.

### 7. Acciones pendientes antes de producción

1. Probar la migración de cuenta, checkout e historial en un entorno de ensayo.
2. Aplicar las migraciones solo después de verificar que el checkout de invitados y los paneles existentes siguen funcionando.
3. Retirar el bypass de lectura global del propietario técnico en pedidos y líneas, sustituyéndolo por consultas técnicas mínimas y auditadas.
4. Probar dos clientes: A no puede leer pedidos, líneas ni favoritos de B, incluso con UUIDs conocidos.
5. Probar dos negocios: administrador/empleado A no puede consultar pedidos ni datos personales de B.
6. Confirmar que el cliente solo ve sus pedidos autenticados y que los pedidos de invitado no se atribuyen automáticamente a una cuenta.
7. Revisar retención, exportación y eliminación de datos personales, incluyendo qué datos se conservan por obligaciones contables y de atención de pedidos.
8. Evitar incluir tokens de seguimiento, teléfonos, correos y direcciones en logs, analítica o mensajes de error.

### Resultado

- RLS y grants live: **consultados en solo lectura**.
- Lectura global técnica de pedidos y líneas: **confirmada en políticas instaladas**.
- Historial de cliente y favoritos: **no instalados en live**.
- Diseño de propiedad de pedidos y favoritos: **revisado estáticamente en borradores**.
- Checkout autenticado en la rama: **valida JWT y perfil antes de asignar customer_user_id**.
- Seguimiento público: **devuelve datos limitados y usa token UUID; no expone contacto ni dirección**.
- Pruebas cruzadas entre clientes y negocios: **pendientes**.
- SQL aplicado, despliegues o cambios de Auth: **ninguno**.


## Décima revisión: inventario, concurrencia y consistencia de pedidos

**Fecha:** 14 de noviembre de 2026  
**Alcance:** función live `create_public_order`, restricciones de inventario, triggers de pedidos, interfaz de productos y borradores de idempotencia y cancelación.

### 1. Checkout e inventario live

La función live `public.create_public_order(uuid,text,text,text,text,text,text,jsonb)` es `SECURITY DEFINER`, tiene `search_path = ''` y su ejecución está concedida únicamente a `service_role`; no puede ser llamada directamente por `anon` ni `authenticated`.

La función:

- Valida que el negocio esté activo y que los productos pertenezcan al negocio indicado.
- Rechaza productos inactivos, cantidades no enteras, cantidades menores que 1 o mayores que 99, productos repetidos y carritos vacíos o excesivos.
- Lee cada producto con `SELECT ... FOR UPDATE`.
- Comprueba que `inventory >= quantity`.
- Calcula el subtotal con el precio guardado en la base de datos.
- Crea el pedido y sus líneas, registra el costo histórico y descuenta las existencias.
- Devuelve el pedido con su token de seguimiento.

Como toda la función se ejecuta en una transacción PostgreSQL, si una inserción o un descuento falla, la operación completa se revierte. Las restricciones live `products_inventory_check` (`inventory >= 0`) y `order_items_quantity_check` (`quantity > 0`) agregan una segunda barrera.

### 2. Concurrencia: riesgo de interbloqueo, no de sobreventa

La función bloquea los productos uno por uno siguiendo el orden recibido en el JSON del carrito. Dos compras simultáneas con varios productos en orden inverso pueden intentar bloquear las mismas filas en distinto orden. PostgreSQL detectaría el interbloqueo y abortaría una transacción; el bloqueo evita que ambas descuenten las mismas unidades, pero una compra legítima podría fallar y requerir reintento.

Mejora recomendada: adquirir los bloqueos de todos los productos en un orden determinista (por ejemplo, UUID ascendente) antes de validar y descontar cantidades. Debe incorporarse en una migración revisada y probarse con dos checkouts concurrentes en staging.

### 3. Idempotencia: código de rama pendiente de migración

El Edge Function `create-public-order/index.ts` de la rama llama a estas RPC:

- `get_public_order_idempotent`
- `reserve_checkout_rate_limit`
- `create_public_order_idempotent`

En la base live no están instaladas esas funciones ni la tabla privada `private.checkout_idempotency`. El borrador `database/orders/checkout-idempotency-draft.sql` las define y usa una clave por intento, hash de la solicitud y bloqueos asesorados para impedir pedidos duplicados por reintentos concurrentes.

**Importante:** no desplegar la versión de Edge Function de la rama antes de instalar y verificar sus dependencias SQL. Tampoco considerar activa la idempotencia en producción solo porque el código y el borrador estén guardados en GitHub.

### 4. Edición manual de existencias en el panel

En `panel-live.js`, `saveProduct()` incluye siempre el valor de `inventory` del formulario dentro del mismo UPDATE que guarda nombre, descripción, precio y otros datos del producto.

Esto crea una condición de carrera: si el administrador abre un producto con 10 unidades, se vende una unidad mientras el formulario permanece abierto y luego guarda un cambio de descripción, el formulario podría escribir nuevamente 10 y deshacer el descuento real.

Además, el inventario se modifica directamente desde el panel; no se encontró una tabla de movimientos de inventario ni un registro separado y estructurado de ajustes con cantidad anterior, cantidad nueva, motivo y actor.

Corrección recomendada:
- Separar la edición de datos comerciales de los ajustes de existencias.
- No enviar `inventory` en una actualización normal de nombre, descripción o precio.
- Gestionar entradas y salidas mediante una RPC transaccional que bloquee la fila del producto y aplique un delta sobre el inventario actual.
- Registrar cada ajuste con actor, negocio, producto, delta, saldo anterior y posterior, motivo y fecha.
- Restringir la operación al administrador activo del negocio y auditarla.

### 5. Cancelaciones y restitución de existencias

En live existen las tablas de pedidos y solicitudes de cancelación, y el trigger `private.enforce_order_status_transition()` exige una solicitud aprobada por el mismo usuario que cambia el pedido a `cancelled`. No se encontró instalada la RPC `decide_order_cancellation`; por tanto, el flujo completo de aprobación y restitución todavía no está activo en la base independiente.

El borrador `database/orders/cancellation-flow-draft.sql` implementa:
- Solicitud de cancelación por administrador o empleado del negocio.
- Decisión exclusiva del administrador del negocio.
- Bloqueo del pedido y de la solicitud para evitar decisiones simultáneas.
- Aprobación, cambio de estado y restitución de existencias dentro de una misma transacción.
- Comprobación de que se restituyeron todos los productos existentes del pedido.
- Índice único para impedir más de una cancelación aprobada por pedido.

Si una restitución falla, PostgreSQL revierte también la aprobación y el cambio de estado. El borrador necesita pruebas de concurrencia y de inventario antes de instalarse. Los productos deben desactivarse en lugar de eliminarse cuando todavía puedan formar parte de pedidos cancelables; la FK actual de `order_items.product_id` usa `ON DELETE SET NULL`, por lo que al borrar un producto se pierde la referencia necesaria para devolver sus unidades.

### 6. Estados y consistencia funcional

Los estados live son `pending`, `confirmed`, `preparing`, `ready`, `out_for_delivery`, `delivered` y `cancelled`. El trigger impide saltos de estado no autorizados y permite cancelar solo con una solicitud aprobada.

Hay una diferencia con el flujo solicitado para MiEje Market: el nombre funcional pedido fue `received` y `on_the_way`, mientras la base usa `pending` y `out_for_delivery`. Antes de cambiarlo debe definirse una equivalencia uniforme entre base, Edge Functions, paneles y seguimiento público; no renombrar estados solo en la interfaz.

### 7. Estado de datos y pruebas

La consulta live devolvió cero registros en `orders`, `products`, `order_items` y `order_cancellation_requests`. Por tanto, no fue posible ejecutar pruebas reales de compra, concurrencia, cancelación o restitución.

No se encontró ninguna tabla pública con nombre relacionado con inventario, stock, movimientos o ajustes. Los triggers de productos instalados solo actualizan `updated_at`; no registran movimientos de inventario.

### Resultado

- Checkout live con bloqueo de filas y descuento transaccional: **confirmado por definición SQL**.
- Restricción de inventario no negativo y cantidades positivas: **confirmadas en live**.
- Ejecución directa del checkout por anon/authenticated: **denegada; solo service_role**.
- Orden determinista de bloqueo de múltiples productos: **mejora pendiente**.
- Idempotencia de checkout: **borrador en rama; RPC y tabla ausentes en live**.
- Aprobación de cancelaciones y restitución: **borrador en rama; RPC ausente en live**.
- Edición de inventario desde formulario: **riesgo de sobrescribir descuentos concurrentes identificado**.
- Libro de movimientos de inventario: **no existe en el esquema revisado**.
- Pruebas reales: **bloqueadas porque no hay productos ni pedidos de prueba en la base**.
- SQL aplicado, Edge Functions desplegadas o cambios en producción: **ninguno**.


## Correcciones preparadas después de la décima revisión: inventario y checkout

**Fecha:** 14 de noviembre de 2026  
**Estado:** cambios guardados únicamente en la rama `correcciones-funcionales`; pendientes de revisión, migración y pruebas.

### 1. Libro de movimientos de inventario

Se creó `database/inventory/inventory-movements-draft.sql`:

- Tabla `public.inventory_movements` con negocio, producto, actor, tipo, saldo anterior, saldo posterior, delta, motivo y fecha.
- FK compuesta para impedir que un movimiento relacione un producto con otro negocio.
- RLS para lectura exclusiva del administrador activo del negocio.
- Sin INSERT, UPDATE ni DELETE directo para usuarios autenticados.
- Trigger que registra inventario inicial y cada cambio posterior.
- Tipos de movimiento: `initial`, `adjustment`, `sale`, `cancellation_return`.
- RPC `adjust_business_inventory`, exclusiva para administradores activos del negocio.

La RPC bloquea el producto con `FOR UPDATE` y compara el inventario esperado enviado por el formulario con el valor actual en la base. Si hubo una venta o ajuste mientras el formulario estaba abierto, rechaza la operación y pide recargar. Así evita que un valor desactualizado sobrescriba una venta reciente.

### 2. Panel de administración

Se modificó `panel-live.js`:

- La edición de nombre, precio, descripción, categoría e imagen ya no envía el campo `inventory`.
- Al crear un producto nuevo, conserva el inventario inicial.
- Al editar un producto y cambiar las existencias, solicita un motivo.
- Envía el ajuste mediante `adjust_business_inventory`, incluyendo el inventario que el panel había leído como valor esperado.
- Si el catálogo se guarda pero el ajuste falla por concurrencia o permisos, informa expresamente que los datos del producto se guardaron y que las existencias no cambiaron.

El ajuste depende de que la nueva migración SQL esté instalada; no funcionará en live antes de eso. El guardado del catálogo y el ajuste son dos operaciones separadas: un error en la segunda no revierte los cambios comerciales ya guardados.

### 3. Checkout con bloqueos deterministas

Se creó `database/inventory/checkout-inventory-lock-order-draft.sql`, con una versión revisada de `create_public_order` que:

- Valida el tipo del carrito y los identificadores antes de convertirlos.
- Adquiere bloqueos de productos por UUID ascendente, sin depender del orden del carrito.
- Mantiene la comprobación de negocio, producto activo, existencias, precio y costo histórico.
- Registra los descuentos de venta en el libro de inventario con el tipo `sale` y el número del pedido.
- Conserva el permiso de ejecución de la función para `service_role`.

Esta migración debe compararse nuevamente con la definición live antes de ejecutarse. No reemplaza la migración de idempotencia; son protecciones distintas.

### 4. Cancelaciones y devoluciones de inventario

Se actualizó `database/orders/cancellation-flow-draft.sql` para etiquetar las restituciones con tipo `cancellation_return` y motivo que incluye el ID del pedido. También se corrigió el orden SQL del CTE de restitución para que la sentencia sea válida.

La restitución sigue siendo parte de la misma transacción que aprueba la cancelación y cambia el estado del pedido. Requiere que primero exista el trigger de movimientos de inventario para registrar la devolución.

### 5. Orden de revisión y dependencias

Orden recomendado para staging, una vez que exista un entorno disponible:

1. `database/inventory/inventory-movements-draft.sql`
2. `database/inventory/checkout-inventory-lock-order-draft.sql`
3. `database/orders/checkout-idempotency-draft.sql` (después de revisar dependencias y firmas de Edge Function).
4. `database/orders/cancellation-flow-draft.sql`.

No aplicar esta secuencia directamente en producción sin pruebas. En particular, la cancelación depende del registro de movimientos para que la devolución quede en el historial.

### Resultado de esta preparación

- Libro de movimientos y RPC de ajuste: **borrador creado**.
- Edición del panel separada del inventario: **cambio guardado en la rama**.
- Protección contra formulario desactualizado: **implementada en el borrador SQL y llamada desde el panel**.
- Bloqueo determinista del checkout: **borrador creado**.
- Registro de venta y devolución con tipo/motivo: **preparado en los borradores**.
- Cancelación: **CTE corregido y devolución clasificada**.
- Lectura y verificación de archivos en GitHub: **realizadas**.
- Migraciones SQL aplicadas, funciones desplegadas y pruebas concurrentes: **ninguna**.
- GitHub Pages y `main`: **sin cambios**.


### 6. Integración adicional del historial y permisos de inventario

- `panel-negocio.html` incorpora una sección de historial de inventario con botón de actualización.
- `panel-live.js` consulta los últimos 100 movimientos del negocio autenticado, muestra fecha, producto, tipo, saldos, variación y motivo. La consulta queda protegida por la política RLS de administradores activos.
- `database/security/business-admin-boundaries.sql` deja de conceder UPDATE directo de la columna `products.inventory` a `authenticated`. Los cambios de existencias deben pasar por `adjust_business_inventory`; la función `SECURITY DEFINER` realiza el UPDATE después de validar el rol y el negocio.
- El historial solo se podrá consultar cuando la migración de movimientos esté instalada. Si se despliega el panel antes de esa migración, la consulta mostrará el error de tabla/función ausente; por eso debe respetarse el orden de despliegue.
