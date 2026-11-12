# Matriz de pruebas de aislamiento — MiEje Market

Estado: plan de pruebas; no ejecutar sobre producción con cuentas o datos reales.

## Cuentas y datos controlados necesarios

Crear en un entorno de pruebas:
- Técnico superior con MFA habilitado.
- Administrador del negocio A.
- Empleado del negocio A.
- Administrador del negocio B.
- Dos negocios de prueba activos y un negocio de prueba suspendido.
- Productos, pedidos, métodos de pago, gastos, costos, solicitudes de cancelación y postulaciones ficticios, separados por negocio.

No reutilizar cuentas de clientes ni datos personales reales.

## Matriz de permisos esperada

| Recurso/acción | Técnico superior | Admin A | Empleado A | Admin B |
|---|---|---|---|---|
| Crear negocio y asignar miembros | Sí, mediante Edge Function | No | No | No |
| Suspender/reactivar negocio o accesos | Sí, mediante Edge Function | No | No | No |
| Editar ficha comercial del negocio | No desde Data API | Solo A | No | Solo B |
| Administrar productos | No desde Data API | Solo A | No | Solo B |
| Consultar pedidos y clientes | No desde Data API | Solo A | Solo A | Solo B |
| Avanzar estado válido de pedido | No desde Data API | Solo A | Solo A | Solo B |
| Consultar costos, gastos y finanzas | No desde Data API | Solo A | No | Solo B |
| Configurar métodos de pago | No desde Data API | Solo A | No | Solo B |
| Ver solicitudes de cancelación | No desde Data API | Solo A | Solo A | Solo B |
| Aprobar/rechazar cancelación | No desde Data API | Solo A | No | Solo B |
| Registrar reembolso | No desde Data API | Solo A | No | Solo B |
| Ver postulaciones de vacantes | No desde Data API | Solo A | No | Solo B |
| Ver auditoría global | Sí | No | Solo eventos propios | No |

## Casos negativos obligatorios

1. Admin A intenta consultar, editar o borrar recursos del negocio B: debe recibir cero filas o error de autorización.
2. Empleado A intenta consultar costos, gastos, pagos, reembolsos o postulaciones: debe recibir cero filas o error de autorización.
3. Empleado A intenta cambiar precio, inventario o configuración comercial: debe ser rechazado por permisos.
4. Técnico intenta consultar pedidos, clientes, productos o finanzas mediante el Data API: no debe obtener datos privados.
5. Usuario de negocio suspendido intenta abrir el panel o modificar registros: debe ser rechazado.
6. Usuario intenta cambiar `business_id` de productos, gastos, métodos de pago, costos o membresías: el trigger debe rechazarlo.
7. Se intenta suspender o retirar al último administrador activo: la operación debe rechazarse, incluso con dos operaciones concurrentes.
8. Se intenta saltar estados de pedido, retroceder un estado o cancelar sin aprobación: debe rechazarse.
9. Se intenta aprobar una cancelación dos veces o reembolsar dos veces: debe rechazarse sin duplicar inventario ni movimientos financieros.

## Casos positivos obligatorios

1. Admin A configura su tienda, productos, métodos de pago, costos y gastos.
2. Empleado A consulta pedidos de A y avanza solo al siguiente estado permitido.
3. Empleado A registra una solicitud de cancelación; Admin A la aprueba o rechaza.
4. Al aprobar una cancelación, el inventario se restituye exactamente una vez.
5. Admin A registra un reembolso total solo después de haberlo realizado fuera de MiEje; el pedido pasa a `refunded`.
6. Técnico crea un negocio y asigna un administrador desde la Edge Function, con MFA AAL2.

## Criterio de aprobación

Cada caso debe probarse con sesiones independientes y capturar resultado esperado/obtenido. No fusionar ni desplegar los cambios mientras haya un caso negativo que permita acceso cruzado o modificación no autorizada.

Los borradores SQL de la PR aún no se han ejecutado. Las pruebas requieren primero un entorno de staging con usuarios de prueba; no deben improvisarse con datos reales.

## Pruebas específicas de checkout y catálogo

Verificaciones estáticas realizadas contra el esquema activo y la función Edge:
- La función pública `create-public-order` está desplegada con `verify_jwt=false`, porque el checkout admite visitantes; valida el formato del pedido y la forma de pago habilitada antes de llamar a la función SQL.
- La función SQL `create_public_order` recalcula subtotal y total usando precios de la base de datos, verifica negocio activo, producto activo, inventario, pedido mínimo y bloquea las filas de productos con `FOR UPDATE` antes de descontar existencias.
- La función SQL de creación de pedidos no concede `EXECUTE` a `anon` ni a `authenticated`; el acceso se realiza desde la Edge Function con credenciales de servidor.
- La tabla `orders` solo concede a `authenticated` actualización de `status` y `delivery_tracking`; no concede actualización directa de importes ni estado de pago.
- El administrador guarda los métodos de pago con códigos internos normalizados: efectivo, transferencia, tarjeta u otro. Nequi, Bancolombia y Daviplata se agrupan como transferencia.

Casos que aún deben probarse en staging:
1. Pedido con forma de pago habilitada: debe registrarse y descontar inventario una sola vez.
2. Pedido con forma de pago deshabilitada o perteneciente a otro negocio: debe rechazarse.
3. Manipulación del precio o total desde el navegador: el total persistido debe salir de los precios actuales de la base de datos.
4. Dos pedidos simultáneos por las últimas unidades: no deben vender más unidades de las disponibles.
5. Producto inactivo, negocio suspendido, pedido inferior al mínimo o cantidad inválida: deben rechazarse.
6. Llamada directa a `create_public_order` desde cliente anónimo o autenticado: debe ser denegada.
7. Métodos personalizados como Nequi o Bancolombia: deben conservar su etiqueta e instrucciones públicas, pero usar el código interno `transfer`.

## Hallazgos del estado activo que requieren migración

La inspección de políticas RLS actuales encontró bypass de `platform_owner` en lectura de pedidos, productos, partidas de pedido, métodos de pago, costos, gastos, contenido comercial, postulaciones y membresías; también existe bypass en actualización de pedidos y ficha comercial. El borrador `database/security/business-admin-boundaries.sql` reemplaza varias de estas políticas para que el técnico gestione usuarios y negocios mediante Edge Functions, sin acceso operativo global por Data API.

Este hallazgo es una diferencia entre el estado actual de Supabase y el estado propuesto en la rama. No se considera corregido en producción hasta ejecutar la migración y repetir las pruebas de permisos.

## Pruebas adicionales de creación de negocios e invitaciones

1. Crear un negocio y comprobar que la respuesta confirme la creación solo cuando el registro exista.
2. Simular un fallo de auditoría después de crear el negocio: la interfaz debe informar que el negocio sí fue creado y advertir que falta el evento de auditoría, sin sugerir repetir la creación.
3. Invitar a un usuario que ya tiene membresía activa: la operación debe responder conflicto antes de enviar un correo o crear otra asignación.
4. Intentar invitar a un usuario que ya tiene membresía suspendida: debe indicar que se debe reactivar la asignación existente, sin enviar una invitación nueva.
5. Invitar a un usuario nuevo: solo confirmar envío cuando Supabase confirme la invitación y la asignación haya sido creada.
6. Si el envío de correo falla: no debe crearse una membresía activa ni mostrarse un mensaje de invitación enviada.
7. Si el correo se envía pero la creación de membresía falla, comprobar el estado de Auth antes de reintentar; el usuario no debe recibir asignaciones duplicadas.

Estas correcciones se prepararon en la rama de trabajo. Aún requieren pruebas de integración en staging y despliegue posterior autorizado.

## Pruebas de campos editables y protección de identificadores

1. Admin A puede editar nombre, categoría, descripción, ciudad, contacto, logo, horarios, domicilio y pedido mínimo de A.
2. Admin A no puede modificar directamente el estado del negocio, el slug, el identificador ni el creador técnico.
3. Admin A puede cambiar nombre, categoría, descripción, precio, inventario, imagen, SKU y estado de sus productos.
4. Admin A no puede cambiar el ID, la fecha de creación ni el business_id de un producto.
5. Admin A puede actualizar las instrucciones y activación de sus métodos de pago, pero no su ID ni business_id.
6. Admin A puede actualizar el costo de un producto de A, pero no cambiar la asociación del costo a otro producto o negocio.
7. Empleado A intenta realizar cualquiera de las operaciones anteriores: debe ser rechazado.
8. Verificar que las actualizaciones normales de la interfaz sigan funcionando después de retirar los permisos de UPDATE a nivel de tabla y conceder únicamente columnas específicas.

## Pruebas de guardado de catálogo y Storage

1. Crear producto sin imagen y verificar que se inserte en el negocio seleccionado.
2. Editar producto existente y comprobar que la respuesta incluya el ID actualizado; una actualización bloqueada por RLS no debe mostrarse como exitosa.
3. Activar y desactivar producto; si no se actualiza ninguna fila, la interfaz debe informar el fallo.
4. Subir PNG, JPG y WEBP dentro del límite configurado de 5 MB. Rechazar otros MIME types y archivos mayores.
5. Confirmar que la ruta de imagen sea business_uuid/products/archivo y la ruta del logo business_uuid/logo/archivo.
6. Admin A no puede subir, reemplazar ni borrar objetos en la carpeta del negocio B. Empleado A no puede administrar imágenes del negocio A.
7. Verificar que el bucket business-assets siga siendo público para visualizar imágenes del catálogo, pero que las operaciones de escritura estén limitadas al administrador del negocio propietario.
8. Introducir horarios inválidos junto con un archivo de logo: no debe subirse ningún archivo ni quedar un objeto huérfano.
9. Forzar que el UPDATE de la ficha comercial no encuentre una fila o sea rechazado por RLS: la interfaz no debe afirmar que guardó correctamente.
10. Forzar un fallo al actualizar un método de pago existente o desactivar uno anterior: mostrar que los datos generales pudieron guardarse, pero que los métodos de pago quedaron pendientes de revisión.

## Pruebas de cambios de estado de pedidos desde los paneles

1. Admin A y empleado A pueden avanzar un pedido de su negocio por las transiciones permitidas: pending, confirmed, preparing, ready, out_for_delivery y delivered.
2. Ningún usuario puede saltar estados, retroceder un pedido ni cambiarlo directamente a cancelled desde el botón de estado.
3. Admin B y usuarios sin membresía no pueden modificar pedidos del negocio A.
4. Si RLS o el trigger rechazan el cambio, la interfaz debe mostrar el error y no presentar el cambio como exitoso.
5. Si el pedido no existe o no pertenece al negocio activo, la actualización no debe devolver un falso éxito.
6. Confirmar que la transición a delivered impide nuevas solicitudes de cancelación y que la cancelación solo se realiza mediante la solicitud aprobada por el administrador.

## Pruebas de configuración de métodos de pago

1. Guardar la tienda con al menos un método de pago válido: debe actualizar la ficha comercial y conservar los métodos habilitados.
2. Intentar guardar sin ningún método de pago válido: debe detenerse antes de modificar la ficha comercial y explicar que el checkout necesita al menos una opción.
3. Si falla la actualización de un método existente o la desactivación de uno anterior, la interfaz debe reportar el resultado parcial con claridad y no afirmar que todo quedó guardado.
4. Confirmar que Nequi, Bancolombia y Daviplata se clasifican como transferencia, sin perder su nombre e instrucciones particulares para el cliente.

## Pruebas de idempotencia del checkout público

1. Enviar una compra con una clave nueva: se debe crear un único pedido y descontar inventario una sola vez.
2. Repetir la misma solicitud con la misma clave y el mismo contenido: debe devolver el mismo pedido, sin crear otro pedido ni descontar inventario de nuevo.
3. Enviar simultáneamente dos solicitudes con la misma clave: debe existir un solo pedido.
4. Reutilizar la misma clave con un carrito, dirección, cliente o forma de pago diferente: debe responder conflicto y no crear un segundo pedido.
5. Simular pérdida de respuesta después de que el servidor confirmó la transacción: el reintento con la misma clave debe recuperar el pedido original.
6. Verificar que un reintento secuencial idempotente ya registrado no consuma nuevos cupos del límite por IP.
7. Una clave nueva debe consumir el límite normal de 10 solicitudes por IP en 10 minutos.
8. Dos solicitudes simultáneas con la misma clave pueden contabilizar dos intentos en el límite por IP, pero deben producir un solo pedido; comprobar que esto no genere falsos errores de recuperación.
8. Si falla el inventario o la creación del pedido, la transacción no debe conservar una clave exitosa ni dejar descuentos parciales.
9. Confirmar que solo service_role puede ejecutar la función idempotente y que anon/authenticated no pueden consultar la tabla privada de claves.
10. Verificar que el endpoint público siga funcionando con verify_jwt=false y valide la clave UUID en el servidor.

## Observaciones del diseño idempotente

- La clave se conserva en el navegador mientras el usuario reintenta exactamente el mismo contenido del checkout.
- Si cambian los datos del cliente, dirección, método de pago o productos/cantidades, se genera una clave nueva.
- El servidor comprueba que una clave existente corresponda al mismo contenido antes de devolver el pedido guardado.
- La consulta de recuperación ocurre antes del límite por IP, para que una compra confirmada cuya respuesta se perdió pueda recuperarse sin duplicarla.
- La creación del pedido y el registro de su respuesta idempotente se ejecutan en la misma transacción PostgreSQL.

## Pruebas de cuentas de clientes, historial y favoritos

1. Registrar una cuenta con correo y nombre; verificar que el trigger existente cree su perfil con rol público predeterminado `user`.
2. Confirmar el correo si la configuración de Auth lo exige y después iniciar sesión.
3. Crear un pedido con sesión autenticada: el pedido debe guardar el UUID de esa cuenta en `customer_user_id`.
4. Crear un pedido como invitado: `customer_user_id` debe permanecer NULL y el checkout público debe seguir funcionando.
5. Consultar el historial con el cliente A: solo debe devolver pedidos asociados al UUID del cliente A.
6. Intentar consultar directamente el pedido del cliente B desde la sesión A: RLS debe ocultarlo.
7. Consultar los artículos del pedido: solo deben aparecer artículos de pedidos propios.
8. Guardar un producto favorito desde una sesión autenticada; comprobar que no se pueda insertar un favorito para otro `user_id`.
9. Intentar leer o eliminar favoritos de otro usuario: RLS debe impedirlo.
10. Eliminar un favorito propio y comprobar que desaparezca de la lista.
11. Verificar que los pedidos históricos anteriores a la migración sigan conservados y no se asignen automáticamente por coincidencia de correo.
12. Verificar que la cuenta bloqueada no pueda crear nuevos pedidos y que la navegación pública y el checkout de invitados continúen disponibles.

## Recuperación y confirmación de cuentas

1. Desde la cuenta de cliente, solicitar recuperación de contraseña; la respuesta de la página debe ser genérica y no revelar si el correo existe.
2. Confirmar que el correo de recuperación dirige a `actualizar-clave.html` en GitHub Pages.
3. Abrir un enlace vigente: solo el evento Auth `PASSWORD_RECOVERY` debe habilitar el formulario de cambio.
4. Abrir `actualizar-clave.html` con una sesión normal ya iniciada, pero sin un evento de recuperación: el formulario debe permanecer bloqueado.
5. Abrir un enlace vencido o ya utilizado: no debe permitir cambiar la contraseña y debe indicar que se solicite otro enlace.
6. Cambiar la contraseña correctamente: debe cerrar la sesión si es posible y permitir iniciar sesión con la nueva contraseña.
7. Confirmar que un error al cerrar sesión después de actualizar la contraseña no muestre falsamente que el cambio de contraseña falló.
8. Desde el registro de clientes, comprobar que el correo de confirmación redirige a la página pública `cuenta.html`.
9. Comprobar que la URL de `cuenta.html` esté agregada a la lista de Redirect URLs permitidas en Supabase Auth antes de probar el registro en producción.
10. Probar envío y entrega real de correos con SMTP configurado; el servicio de correo predeterminado tiene límites y no debe asumirse como canal de producción.

13. Confirmar que el historial pueda mostrar el nombre del negocio mediante permiso de lectura limitado a `businesses.id` y `businesses.name`, solo para negocios activos; no debe poder leer teléfono, dirección, horarios ni otra configuración comercial.

## Checkout idempotente y formas de pago

1. Crear un pedido con una clave nueva: el límite por IP debe consumirse exactamente una vez.
2. Repetir la misma solicitud con la misma clave y contenido: debe recuperar el mismo pedido sin consumir otro intento ni descontar inventario.
3. Ejecutar dos solicitudes simultáneas con la misma clave: debe existir un solo pedido.
4. Reutilizar la clave con datos distintos: debe responder conflicto y no crear otro pedido.
5. Desactivar el método de pago después de crear el pedido y repetir la solicitud original: debe recuperarse el pedido existente.
6. Intentar crear un pedido nuevo con un método desactivado: debe rechazarse.
7. Reintentar una compra existente sin encabezado de IP: la consulta idempotente debe poder recuperar el pedido; una clave nueva sin IP válida debe rechazarse antes de crear el pedido.
8. Comprobar que el límite por IP sigue funcionando para claves nuevas y que no se cuenta dos veces desde Edge Function y SQL.

## Cancelaciones, inventario y reembolsos

1. Solicitar cancelación desde un empleado del mismo negocio y comprobar que queda pendiente.
2. Intentar solicitar cancelación desde una cuenta de otro negocio: debe rechazarse.
3. Aprobar con el administrador correcto: pedido y reposición de inventario deben confirmarse en una sola transacción.
4. Rechazar una solicitud: el estado del pedido y el inventario deben permanecer iguales.
5. Intentar aprobar dos veces o en paralelo: solo una decisión puede completarse y el inventario no debe duplicarse.
6. Intentar cancelar un pedido entregado o ya cancelado: debe rechazarse.
7. Comprobar que un producto eliminado (product_id nulo en el detalle histórico) no impide cancelar los demás artículos; si un producto asociado ya no pertenece al negocio esperado, la operación debe revertirse.
8. Registrar reembolso solo para un pedido cancelado, pagado y con solicitud aprobada.
9. Rechazar reembolso para pedido gratuito (total cero), pendiente de pago, no cancelado o sin solicitud aprobada.
10. Intentar registrar dos reembolsos simultáneos para el mismo pedido: solo uno debe completarse.
11. Verificar que el reembolso registre importe, método, referencia y auditoría, y cambie payment_status a refunded en la misma transacción.
12. Confirmar que la aplicación no comunica que el dinero fue transferido: el procedimiento solo registra una devolución que el negocio ya realizó por fuera de MiEje.

## Segunda pasada de políticas RLS del propietario técnico

La comparación de todas las políticas activas que contienen `private.is_platform_owner()` encontró tres políticas adicionales que la primera versión de la migración no había sustituido:
- `business_expenses_select`: permitía lectura global de gastos.
- `order_item_costs_admin_select`: permitía lectura global de costos asociados a pedidos.
- `profiles_select_self_or_owner`: permitía leer perfiles de todos los usuarios desde el Data API.

Se añadieron reemplazos al borrador `database/security/business-admin-boundaries.sql`:
- Gastos y costos asociados a pedidos: solo el administrador del negocio activo.
- Perfiles: cada usuario solo puede leer su propio perfil mediante Data API. La Edge Function técnica consulta perfiles puntuales con credenciales de servidor después de autenticar al propietario y validar MFA AAL2.

Antes de aplicar esta migración, probar en staging que las vistas de pedidos de administradores/empleados no dependan de leer directamente perfiles de clientes; el helper de nombres de clientes del panel usa actualmente una consulta a `profiles`. Si esa consulta necesita habilitarse para administradores, debe diseñarse una política limitada a clientes con pedidos del mismo negocio y exponer únicamente los campos imprescindibles, no restaurar acceso global.


## Resultado de la revisión de consultas de perfiles y permisos de empleados

La revisión del código de `panel-live.js` encontró que los pedidos de administradores y empleados ya muestran los datos de contacto guardados en cada pedido (`customer_name`, `customer_phone`, dirección y notas). Esas vistas no necesitan consultar `profiles` para identificar al comprador.

La función auxiliar `getUserNames` sí consulta `profiles` para mostrar nombres en los registros de acceso, auditoría y solicitudes de bloqueo. Con la política propuesta de lectura del perfil propio, esos nombres pueden quedar sustituidos por identificadores abreviados. Esto no bloquea la consulta ni las acciones de auditoría, pero debe comprobarse visualmente en staging. No se debe ampliar la política de `profiles` para recuperar nombres de forma global.

Permisos de empleados revisados en el estado activo y en el borrador:

- Los empleados no tienen privilegios de tabla para insertar, actualizar o eliminar pedidos; la actualización autorizada se limita a las columnas `status` y `delivery_tracking`.
- La política propuesta de pedidos limita SELECT y UPDATE al personal del negocio activo, sin bypass del propietario técnico.
- El trigger propuesto permite únicamente el avance secuencial de estados y exige una solicitud aprobada para cancelar.
- Las políticas de productos, métodos de pago, costos, gastos, movimientos financieros y postulaciones reservan esas operaciones al administrador del negocio.
- El empleado puede registrar una solicitud de cancelación mediante la función controlada; no puede aprobarla ni registrar reembolsos.

Pendiente de staging: probar con cuentas separadas de administrador A, empleado A, administrador B y técnico. Confirmar que el empleado A pueda consultar y avanzar pedidos de A, pero no modificar productos, inventario, precios, métodos de pago, gastos ni datos financieros; confirmar también que no pueda consultar pedidos de B. La migración sigue sin ejecutarse y estas reglas todavía no están activas en producción.


## Corrección adicional del flujo concurrente de cancelaciones

La función `decide_order_cancellation` ahora establece explícitamente un orden de bloqueo consistente: primero obtiene y bloquea la fila del pedido, y después bloquea la solicitud de cancelación. La función `request_order_cancellation` ya bloquea primero el pedido. Esto evita que ambos flujos intenten adquirir los mismos bloqueos en orden inverso.

Pruebas pendientes en staging:
1. Dos empleados intentan crear simultáneamente una solicitud para el mismo pedido: debe quedar una sola solicitud pendiente.
2. Un empleado solicita cancelación mientras el administrador decide una solicitud existente: las operaciones deben serializarse sin duplicar inventario ni dejar solicitudes inconsistentes.
3. Dos administradores (o dos sesiones del administrador) intentan decidir la misma solicitud simultáneamente: solo una decisión debe completarse.
4. Tras aprobar, el pedido debe quedar cancelado y cada producto debe recuperar exactamente las unidades compradas una sola vez.
5. Tras rechazar, el pedido y el inventario deben permanecer sin cambios.

Se consultó el esquema live y se confirmó que los estados permitidos por la restricción CHECK de `orders.status` son `pending`, `confirmed`, `preparing`, `ready`, `out_for_delivery`, `delivered` y `cancelled`. Coinciden con los estados utilizados por el panel y el trigger propuesto. Esta consulta fue de solo lectura; no se modificó la base de datos.


## Ajuste de visibilidad de solicitudes de cancelación

La inspección de las políticas RLS activas de `order_cancellation_requests` encontró que empleados y administradores podían consultar la bandeja de solicitudes, aunque la matriz funcional reserva esa bandeja al administrador. Se añadió al borrador `business-admin-boundaries.sql` el reemplazo de esa política: solo el administrador del negocio activo puede leer las solicitudes. Los empleados conservan la posibilidad de registrar solicitudes mediante `request_order_cancellation`, pero no pueden consultar la bandeja ni aprobar/rechazar.

La tabla solo concede SELECT a `authenticated`; no concede INSERT, UPDATE ni DELETE a ese rol. La creación y decisión se mantienen detrás de funciones RPC controladas. Esta es una corrección de borrador: no se ha aplicado a Supabase.


## Auditoría de reembolsos y movimientos financieros

Consultas de solo lectura al esquema live confirmaron:
- `financial_transactions.amount` exige un valor mayor que cero; el borrador ya rechaza pedidos con total cero antes del INSERT.
- Los estados financieros permitidos son `pending`, `completed`, `failed` y `reversed`; el tipo `refund` está admitido.
- `refund_details` exige `financial_transaction_id`, negocio, pedido, método y usuario registrador; el borrador aporta esos campos.
- Las claves foráneas compuestas vinculan la transacción y el detalle al mismo negocio y pedido.
- No se encontraron reembolsos completados duplicados en los datos existentes al momento de la consulta; el índice único parcial propuesto no colisiona con esos datos.
- La tabla `orders` solo concede UPDATE directo a `authenticated` en `status` y `delivery_tracking`; no concede actualización directa de `payment_status`. El procedimiento SECURITY DEFINER es el único flujo propuesto para marcar el pedido como `refunded`.
- El trigger de transición de estado solo ejecuta reglas cuando cambia `orders.status`; actualizar `payment_status` no provoca una transición ficticia de estado.

### Corrección encontrada en política de cancelaciones
Una pasada final detectó que el mismo archivo SQL volvía a declarar más abajo la política de lectura de cancelaciones permitiendo `business_admin` y `employee`, anulando el cambio previo. Se corrigió esa última declaración para que la política efectiva del borrador sea `cancellation_admin_select`, exclusiva del administrador del negocio activo. Los empleados siguen solicitando cancelaciones por RPC sin consultar la bandeja.

Pruebas de staging pendientes:
1. Reembolso válido por el importe total, con pago previamente realizado fuera de MiEje.
2. Segundo intento simultáneo de reembolso para el mismo pedido: debe rechazarse por bloqueo del pedido y por el índice único.
3. Empleado, administrador de otro negocio y técnico por Data API: no pueden consultar ni registrar reembolsos de ese negocio.
4. Pedido pendiente, fallido, no cancelado, sin cancelación aprobada o con total cero: debe rechazarse.
5. Verificar que la transacción financiera, detalle, cambio de `payment_status` y auditoría se confirmen juntos o se reviertan juntos.
6. Confirmar que la interfaz solo muestra pedidos cancelados y pagados, y que después de registrar el reembolso desaparecen de la lista.

No se ejecutó SQL ni se desplegó la función. La devolución del dinero debe haberse realizado por fuera de MiEje antes de registrar el comprobante.

## Auditoría de inventario y protección de reintentos del checkout

La inspección de solo lectura del esquema y de la función live `public.create_public_order` confirmó:
- Cada producto se consulta con `FOR UPDATE` antes de validar disponibilidad; las compras concurrentes del mismo producto quedan serializadas.
- La función comprueba que el inventario alcance para la cantidad solicitada y descuenta las unidades dentro de la misma transacción que crea el pedido y sus detalles.
- La restricción `products_inventory_check` impide inventario negativo.
- La cancelación propuesta agrupa las líneas por producto y suma las cantidades antes de restituirlas. Verifica que se hayan actualizado todos los productos vinculados; si falta alguno, revierte la operación completa.
- Los detalles de pedido conservan `product_name`, `quantity` y `unit_price`; si un producto se elimina, su FK queda en NULL y ya no existe una fila de inventario que pueda restituirse.

Se corrigió `app.js` para conservar la clave idempotente del intento de checkout en `sessionStorage` durante la pestaña. El contenido almacenado incluye únicamente una huella SHA-256 del payload y la clave UUID, no los datos personales del comprador. Así, si el navegador recarga la página después de enviar el pedido, el mismo payload puede reutilizar la clave y recuperar la respuesta original del servidor. La clave se limpia al confirmar el pedido.

Pruebas pendientes en staging:
1. Dos compras simultáneas que soliciten las últimas unidades de un producto: solo una debe completarse.
2. Compra con inventario exacto: debe terminar en cero; una unidad adicional debe rechazarse.
3. Dos líneas repetidas del mismo producto: la API debe rechazarlas o normalizarlas sin permitir una venta superior al inventario.
4. Cancelación aprobada con varios productos y cantidades repetidas: cada inventario debe aumentar exactamente por la suma comprada.
5. Cancelación rechazada: no debe cambiar el inventario.
6. Recargar la pestaña después de enviar el checkout, antes de recibir respuesta, y reenviar el mismo payload: debe recuperarse el mismo pedido.
7. Reutilizar la clave con un payload diferente: debe devolver conflicto y no crear otro pedido.
8. Simular un error durante la restitución: el estado del pedido y el inventario deben revertirse juntos.

La corrección de `app.js` está en la rama `correcciones-funcionales`. La migración de checkout idempotente y la migración de cancelaciones siguen siendo borradores; no se ejecutó SQL ni se desplegó ninguna Edge Function. Las pruebas de concurrencia y navegador todavía no se han ejecutado.

## Protección de datos visibles al cambiar de cuenta de cliente

La revisión de `cuenta.js` detectó una condición de carrera: si una consulta de historial o favoritos de la cuenta A seguía pendiente cuando se cerraba sesión y se iniciaba sesión con la cuenta B, la respuesta tardía podía actualizar el DOM con datos de A. Se corrigió el panel de cuenta para:
- Mantener el identificador de la sesión activa.
- Ignorar resultados de historial/favoritos si la sesión cambió mientras se ejecutaba la consulta.
- Limpiar el contenido privado al cerrar sesión.
- Actualizar la vista de acceso al completar el cierre de sesión.

Prueba pendiente en navegador: iniciar sesión como A, provocar una carga lenta del historial, cerrar sesión e iniciar sesión como B; la interfaz de B no debe mostrar datos de A ni siquiera momentáneamente. Repetir al cerrar sesión sin iniciar otra cuenta y verificar que el historial/favoritos queden vacíos.
