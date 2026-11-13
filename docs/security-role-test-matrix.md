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

## Auditoría de registro, recuperación e historial de clientes

Se revisó el código de `cuenta.html`, `cuenta.js`, `recuperar-clave.html`, `recuperar-clave.js`, `actualizar-clave.html`, `actualizar-clave.js` y `login.js`, además del borrador SQL y el esquema live del proyecto independiente.

### Hallazgos confirmados
- El trigger live `private.handle_new_auth_user()` crea un perfil básico al registrarse y toma `display_name` de los metadatos. No asigna rol administrativo automáticamente.
- La base live todavía no tiene `orders.customer_user_id` ni la tabla `customer_favorites`; por eso el historial asociado a una cuenta y los favoritos no pueden funcionar hasta aplicar el borrador de clientes.
- La migración draft añade políticas de lectura de pedidos por `customer_user_id = auth.uid()`, y de líneas de pedido solo cuando el pedido pertenece a esa misma cuenta. Favoritos permiten SELECT/INSERT/DELETE únicamente para el propietario del registro.
- La migración draft también concede lectura limitada de `businesses(id,name)` para que el historial pueda mostrar el nombre del negocio, sin abrir el resto de sus datos.
- En el esquema live siguen existiendo políticas que dan bypass al propietario técnico en pedidos, productos, líneas de pedido y perfiles. El borrador `business-admin-boundaries.sql` debe revisarse y aplicarse coordinadamente con la migración de clientes para que la separación prevista sea efectiva.
- El registro dirige el correo de confirmación a `cuenta.html`; la recuperación dirige a `actualizar-clave.html`. El código usa URLs absolutas calculadas desde la página actual.
- La URL de recuperación ya se había agregado a Redirect URLs de Supabase. La URL pública `https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/cuenta.html` sigue pendiente de agregarse a esa lista. Hasta entonces, la confirmación de registro puede redirigir al Site URL configurado (actualmente localhost) en lugar del portal publicado.
- La recuperación exige el evento Auth `PASSWORD_RECOVERY` antes de habilitar el cambio de contraseña; una sesión normal guardada no basta.
- El login privado usa `resolve-my-access` y separa el acceso de clientes del acceso a paneles. No hay registro público desde `login.html`.

### Pendientes de configuración y pruebas
1. Agregar a Supabase Auth > URL Configuration la Redirect URL exacta `https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/cuenta.html`. Mantener las URLs de localhost necesarias para desarrollo; no cambiar Site URL sin coordinar el flujo.
2. Confirmar que las plantillas de confirmación y recuperación enlacen correctamente con `{{ .ConfirmationURL }}` o el flujo de token que corresponda al tipo de sesión configurado. No se pudo leer la configuración privada de plantillas desde la conexión disponible.
3. Confirmar SMTP personalizado y entrega real de mensajes antes de producción. No se pudo verificar la configuración SMTP ni hacer envíos reales desde esta auditoría.
4. Aplicar las migraciones solo en staging y probar alta, confirmación, login, logout, recuperación, enlace vencido y cambio de contraseña.
5. Crear dos cuentas de prueba y verificar que cada una solo vea sus pedidos y favoritos; comprobar también el acceso de admin/empleado de negocio y técnico después de aplicar la matriz RLS.
6. Probar que el trigger de perfil no eleva a un cliente a `platform_owner`, `business_admin` ni `employee`.
7. Verificar en navegador el cambio de sesión A→B y el cierre de sesión, para confirmar que no se muestran resultados atrasados de otra cuenta.

No se ejecutó ninguna migración, no se cambió la configuración Auth, no se enviaron correos de prueba y no se crearon usuarios de prueba.

## Revisión del Security Advisor de Supabase

La revisión de seguridad del proyecto independiente del 12 de noviembre de 2026 muestra:
- Tres avisos INFO `rls_enabled_no_policy`: `private.checkout_rate_limits`, `public.job_application_rate_limits` y `public.job_application_upload_sessions`.
- La consulta de privilegios confirmó que las dos tablas públicas no conceden privilegios a `anon` ni `authenticated`; los permisos visibles están reservados a `service_role`. La tabla privada de límites tampoco mostró privilegios para esos roles.
- Por ahora, estos tres avisos no justifican añadir políticas RLS para usuarios públicos; hacerlo podría exponer tablas internas de control. Se mantienen cerradas al cliente.
- Sigue activo el aviso WARN `auth_leaked_password_protection`: la protección contra contraseñas comprometidas está deshabilitada. Debe revisarse y habilitarse en Auth > Password Security antes de producción, después de comprobar la política de contraseñas y el flujo de recuperación.

Referencia del aviso de Supabase: https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection

La consulta fue de solo lectura. No se modificaron permisos ni configuración de Auth.

## Segunda auditoría de aislamiento entre negocios y panel técnico

La inspección de solo lectura de las políticas RLS y privilegios del proyecto live confirmó que todavía están activos varios bypass de `platform_owner` en pedidos, productos, líneas de pedido, métodos de pago, costos, gastos, reembolsos, postulaciones y contenido comercial. El borrador `business-admin-boundaries.sql` reemplaza esas políticas por reglas de negocio activo y rol de membresía; también limita perfiles a la propia cuenta. Estos cambios siguen pendientes de aplicar y probar en staging.

### Hallazgos de compatibilidad entre el borrador RLS y los paneles
- El panel técnico cargaba las publicaciones comerciales mediante una consulta directa a `business_content_pages`. El borrador elimina el bypass global del técnico en esa tabla, por lo que esa consulta dejaría de funcionar aunque la moderación siga siendo una función legítima del técnico.
- Se corrigió `technical-business-management` con la acción `list_content_moderation`, que devuelve como máximo 100 publicaciones para el panel técnico usando la función de servidor ya protegida por verificación de sesión y MFA.
- Se corrigió `panel-live.js` para cargar la bandeja de moderación mediante esa Edge Function y no mediante el Data API. La acción de aprobar/rechazar ya utilizaba la Edge Function.
- El panel técnico sigue sin consultar globalmente pedidos, clientes, productos ni finanzas. Su acceso a negocios, membresías, auditoría y moderación pasa por endpoints específicos.
- La vista `storefront_business_directory` usa `security_invoker=true` y `security_barrier=true`; el esquema otorga a los roles públicos solo las columnas necesarias del directorio, no las columnas internas de negocios.
- Los privilegios de membresías permanecen en lectura; la creación y modificación de asignaciones se hace desde la Edge Function técnica. Los métodos de pago no tienen permiso DELETE para authenticated.
- El borrador impide actualizar `business_id` en productos, gastos y métodos de pago mediante privilegios por columna y triggers de inmutabilidad; los costos de producto también validan que producto y negocio coincidan.
- Las restricciones compuestas existentes en costos, movimientos financieros, pedidos y postulaciones vinculan los registros con el negocio correcto.

### Pruebas de aislamiento que aún deben ejecutarse en staging
1. Crear dos negocios de prueba A y B, cada uno con administrador y empleado distintos.
2. Como admin A, consultar/actualizar productos, métodos, contenido, pedidos, costos, gastos, postulaciones y finanzas de B: debe devolver cero filas o permiso denegado.
3. Repetir como empleado A; solo debe poder ver y actualizar los pedidos permitidos de A, sin acceder a costos, finanzas, equipo ni configuración comercial de B.
4. Como usuario con membresía en A y B, confirmar que solo ve los datos de los negocios a los que pertenece y que no puede cambiar el `business_id` de registros existentes.
5. Como técnico, verificar que el Data API no permita leer pedidos, clientes, productos ni datos financieros de todas las tiendas; la gestión de negocios, miembros, auditoría y moderación debe funcionar por Edge Function con MFA.
6. Comprobar que el panel técnico puede listar y moderar contenido después de aplicar el borrador, sin recuperar SELECT global a `business_content_pages`.
7. Confirmar que las páginas públicas siguen leyendo únicamente directorio, productos activos y contenido aprobado de negocios activos.

No se aplicaron las políticas live ni se ejecutaron pruebas con usuarios reales. Los cambios de moderación solo están en la rama `correcciones-funcionales`; la Edge Function no se desplegó.

## Auditoría de Storage y hojas de vida privadas

### Configuración live comprobada por introspección
- `business-assets`: bucket público, máximo 5 MB, tipos PNG/JPEG/WebP. Se utiliza para logos e imágenes de productos que deben mostrarse en la tienda pública.
- `job-applications-private`: bucket privado, máximo 5 MB, tipos PDF/DOC/DOCX. No debe convertirse en público.
- La tabla `job_applications` concede SELECT a authenticated, pero RLS limita las filas a administradores del negocio. El borrador también exige que el negocio esté activo.
- La tabla `job_application_upload_sessions` tiene RLS activado y no concede privilegios a anon ni authenticated; solo service_role accede a ella.
- Las funciones RPC `submit_public_job_application` y `consume_job_application_rate_limit` solo tienen EXECUTE para postgres/service_role, no para anon ni authenticated.
- La política live de lectura de hojas de vida exige el bucket privado y un administrador activo del negocio indicado en la primera carpeta. No se encontró una política SELECT para anon.
- El panel administrativo genera enlaces firmados de descarga con duración de 300 segundos (5 minutos), solo después de listar las postulaciones de su negocio.
- La función pública `create-job-application` usa enlaces firmados de carga, valida vacante publicada/aprobada y negocio activo, comprueba nombre/extensión/MIME/tamaño declarado, usa una ruta aleatoria y una sesión de carga de 30 minutos. La carga se limita además por el bucket a 5 MB y MIME permitidos.
- La RPC de envío consume la sesión de carga una sola vez y exige que corresponda al mismo negocio, vacante, ruta y vencimiento.

### Correcciones preparadas en la rama
- Se guardó en el repositorio el código fuente de la Edge Function live `create-job-application`, que antes existía desplegada pero no estaba versionada.
- Se amplió `database/security/storage-policy-fix.sql` con una política de lectura privada que acepta únicamente la ruta exacta `<business_uuid>/<application_uuid>/<random_uuid>.(pdf|doc|docx)`, y exige administrador de ese negocio activo.
- La política nueva no habilita INSERT/UPDATE/DELETE en el bucket privado: la carga continúa exclusivamente por signed upload URL emitida por la Edge Function.
- Las políticas de `business-assets` siguen siendo borradores; corrigen el uso incorrecto de `storage.foldername(b.name)` para consultar la ruta real `storage.foldername(objects.name)`.

### Límites y pruebas pendientes
- Los buckets no tenían objetos al momento de la consulta; por eso no fue posible probar una descarga real, el vencimiento de enlaces ni el aislamiento entre dos negocios con archivos.
- No se ejecutó el SQL de Storage ni se desplegó la Edge Function desde el repositorio.
- La función valida MIME y extensión declarados, y el bucket restringe MIME, pero no realiza análisis antivirus ni inspección profunda del contenido. No se debe tratar un DOC/DOCX/PDF como libre de malware solo por su extensión.
- En staging crear dos negocios A/B, subir una postulación con archivo a cada uno y comprobar que admin A solo obtiene enlace de A, admin B solo obtiene enlace de B, empleados no pueden descargar, y anon no puede listar ni descargar objetos privados.
- Verificar que un enlace firmado deja de funcionar al vencer, que una sesión de carga expirada/reutilizada se rechaza y que archivos mayores de 5 MB o MIME no permitido no se aceptan.
- Probar carga sin adjunto, carga interrumpida, solicitud repetida, vacante suspendida/no aprobada y descarga tras suspender el negocio.
- Revisar una estrategia de análisis antimalware antes de permitir que personal descargue archivos adjuntos de usuarios externos.

No se alteró la configuración live de Storage, no se subieron ni descargaron archivos reales y no se enviaron postulaciones de prueba.

## Gestión de cuentas, membresías y perfil de panel

### Reglas funcionales incorporadas en la rama
- Solo platform_owner, validado en la Edge Function technical-business-management y con sesión MFA AAL2, puede crear negocios, enviar invitaciones, asignar membresías, suspender/reactivar accesos o cambiar el rol y cargo laboral.
- Los administradores y empleados no reciben operaciones de alta/cambio de membresías en el cliente. La base de datos conserva solo SELECT de membresías para usuarios autenticados; las mutaciones quedan reservadas a service_role a través de la función técnica.
- El administrador que necesita un empleado debe contactar al soporte técnico por WhatsApp; el técnico realiza la invitación y asignación.
- Las invitaciones requieren nombre completo, correo, rol y cargo laboral. El rol permitido es únicamente business_admin o employee.
- El campo job_title se guarda en business_memberships, no en profiles, porque una misma persona puede tener cargos distintos en negocios diferentes.
- La función técnica permite cambiar rol/cargo de una membresía y registra el cambio en auditoría. El borrador SQL añade un trigger transaccional que protege al último administrador activo.
- resolve-my-access devuelve nombre, avatar, correo, panel, rol, cargo y negocio activo asignado. El panel muestra estos datos y usa avatar_url cuando existe.
- Las políticas borrador limitan lectura de profiles al propio usuario y permiten actualizar únicamente display_name, avatar_url y phone; no platform_role, is_blocked ni blocked_reason.
- Se añadieron controles de perfil y soporte WhatsApp a los tres paneles activos: panel-tecnico.html, panel-negocio.html y panel-personal.html.

### Configuración pública global de MiEje Market
- Se aclaró la separación entre la plataforma y los negocios: el técnico puede configurar nombre, descripción, logo, imagen principal y WhatsApp de soporte de MiEje Market.
- El técnico no puede modificar desde el panel técnico la ficha comercial, logo, portada, productos, pagos ni horarios de los negocios; cada administrador configura únicamente su propio negocio.
- Se preparó database/platform/platform-public-settings-draft.sql para crear platform_public_settings con los datos públicos globales, sin acceso directo desde anon/authenticated.
- Se añadió la Edge Function pública de solo lectura get-platform-public-settings, que expone únicamente los campos públicos y no concede acceso a tablas privadas.
- La función técnica permite leer y actualizar la configuración global con MFA y registra los cambios en auditoría.
- La página pública lee la configuración y aplica nombre, descripción, logo e imagen principal. Los campos de imagen aceptan direcciones HTTPS; todavía no se implementó carga de archivos desde el panel.
- El esquema live no tenía la tabla platform_public_settings; por tanto, estos ajustes requieren ejecutar la migración draft y desplegar ambas Edge Functions antes de funcionar en el sitio publicado.

### Límites y pruebas pendientes
1. Aplicar primero las migraciones en un entorno de pruebas, no en producción, y confirmar que el esquema incluye business_memberships.job_title y platform_public_settings.
2. Confirmar que un administrador y un empleado no pueden crear, insertar, cambiar, borrar ni trasladar membresías mediante Data API o invocación directa de la función técnica.
3. Confirmar que un usuario no puede elevar profiles.platform_role, cambiar is_blocked ni modificar el rol de una membresía desde su propio perfil.
4. Invitar a un correo nuevo: verificar entrega, aceptación, creación de contraseña, nombre completo, rol, cargo y acceso solo al negocio asignado.
5. Asignar un usuario existente a otro negocio; comprobar que conserva sus otros roles y que cada negocio muestra su cargo independiente.
6. Cambiar employee a business_admin y viceversa; comprobar auditoría, permisos y protección del último administrador activo con dos operaciones simultáneas.
7. Suspender/reactivar una membresía y suspender/reactivar el negocio; confirmar que resolve-my-access no devuelve asignaciones suspendidas ni negocios inactivos.
8. Configurar el WhatsApp técnico y comprobar el enlace desde los tres paneles; verificar que el endpoint público solo devuelve los campos permitidos.
9. Guardar nombre, descripción, logo e imagen principal en el panel técnico y comprobar que la página pública los aplica sin alterar los datos de los negocios.
10. Completar la carga segura de foto de perfil; por ahora se muestra avatar_url existente, pero no se añadió todavía un flujo de subida de imágenes.
11. Confirmar que todos los cambios del panel técnico requieren MFA AAL2 y quedan registrados en auditoría.

No se ejecutaron estas migraciones, no se desplegaron las Edge Functions y no se modificó el proyecto live. Los cambios permanecen en la rama de trabajo y el PR continúa como borrador.

## Revisión de invitaciones y membresías — 13 de noviembre de 2026

Auditoría de solo lectura del proyecto independiente `cqixlrwbqatbhzmpygiz` y de la rama `correcciones-funcionales`:

- La función activa `technical-business-management` está en versión 6 y todavía no exige MFA AAL2. La rama contiene la comprobación AAL2 antes de permitir acciones técnicas; el cambio no está desplegado.
- La función activa `resolve-my-access` está en versión 2 y todavía no devuelve el perfil ampliado ni el cargo de la membresía. La versión de la rama añade esos campos y filtra membresías suspendidas o asociadas a negocios inactivos.
- El esquema activo de `business_memberships` todavía no contiene `job_title`. La función de la rama consulta e inserta ese campo, por lo que la lista de miembros y las invitaciones nuevas requieren primero la migración pendiente.
- El esquema activo no tiene todavía el trigger transaccional `guard_last_active_business_admin`. El borrador SQL lo incorpora para impedir que dos operaciones simultáneas retiren al último administrador activo.
- En el esquema activo, `authenticated` no tiene permisos efectivos de INSERT, UPDATE o DELETE en `business_memberships`; tampoco puede insertar perfiles ni modificar columnas de rol/bloqueo. La política SELECT actual sí permite al propietario técnico leer membresías y perfiles de otros usuarios; el borrador elimina ese acceso directo y deja las consultas técnicas en Edge Functions con service role.
- El trigger de registro de Auth llama a `private.handle_new_auth_user()`, que crea el perfil con el nombre recibido y no asigna `platform_owner`. El registro de clientes continúa separado de las invitaciones internas.
- La página `aceptar-invitacion.html` y su JavaScript existen en `main`; sin embargo, `main/supabase-config.js` sigue apuntando al proyecto Supabase anterior. No se considera validado el flujo real de invitación en la plataforma publicada.
- Se corrigió en `panel-live.js` la recarga del selector de membresías después de cambiar rol/cargo: ahora actualiza `#assignmentMemberSelect` en vez del selector de suspensión.

### Pruebas pendientes antes de habilitar invitaciones

1. Aplicar primero, en un entorno de pruebas, el esquema de `job_title` y el trigger de último administrador.
2. Probar invitación nueva, correo ya registrado sin membresía, membresía activa duplicada y membresía suspendida.
3. Confirmar que el correo llega y redirige a `aceptar-invitacion.html` en la versión publicada que usa el proyecto independiente.
4. Verificar que la persona establece contraseña, cierra la sesión de activación y luego entra al panel asignado.
5. Probar asignación y cambio de rol/cargo con técnico AAL2; confirmar que admin, empleado y cliente no pueden invitar ni cambiar membresías.
6. Intentar dos suspensiones/demotions concurrentes sobre los dos últimos administradores y comprobar que el negocio conserva al menos uno.
7. Probar que un negocio suspendido o una membresía suspendida no permite abrir el panel, aunque el usuario conserve su cuenta de Auth.

No se ejecutaron cambios en la base de datos ni se desplegaron funciones durante esta auditoría. La rama y el PR continúan siendo borradores.

8. Confirmar en Authentication > URL Configuration que la URL exacta `https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/aceptar-invitacion.html` esté en Redirect URLs. Supabase ignora un `redirectTo` que no esté permitido y usa el Site URL; por eso no basta con que la página exista en GitHub Pages.

9. La acción `list_business_members` devuelve `job_title` y el correo consultado desde Auth; la consulta se ejecuta únicamente después de validar propietario técnico y MFA AAL2.
10. La actualización de rol/cargo ahora usa comparación de estado, rol y negocio leídos previamente; si la membresía cambió entre lectura y escritura, devuelve conflicto en vez de sobrescribir el cambio.

11. Se dejó explícita la opción `verify_jwt` de las seis Edge Functions activas y la función pública nueva aún pendiente de despliegue en `supabase/config.toml`: las funciones públicas conservan `false` y las funciones técnicas/de acceso conservan `true`. Esto evita que una futura publicación por CLI cambie accidentalmente el comportamiento de las funciones públicas por depender del valor predeterminado.

12. Bloqueo de publicación del flujo de invitación: la función de la rama redirige a `https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/aceptar-invitacion.html`, pero GitHub Pages sirve actualmente `main`, cuyo `supabase-config.js` apunta al proyecto anterior `ibnwejpbntvoujdawkwh`. No desplegar la función de invitación ni enviar invitaciones reales hasta publicar una versión de `aceptar-invitacion.html` y `supabase-config.js` conectada a `cqixlrwbqatbhzmpygiz`, y permitir esa URL en Supabase Auth Redirect URLs. La rama de trabajo no se sirve automáticamente desde GitHub Pages.

13. Las operaciones técnicas de invitación, cambio de rol/cargo, suspensión y reactivación de membresías ya no responden como si la operación hubiera fallado cuando el cambio se guardó pero falló la inserción de auditoría. Devuelven el cambio confirmado junto con `audit_warning`; el panel muestra la advertencia y evita inducir al técnico a repetir una acción que ya se realizó. La auditoría sigue siendo un requisito pendiente de resolver si aparece esa advertencia.

14. La política de lectura de perfiles del borrador mantiene el acceso propio y permite que el administrador de un negocio activo consulte los perfiles de las personas que tienen o tuvieron una membresía en ese mismo negocio, incluso si está suspendida. Esto conserva los nombres de los actores en la auditoría sin devolver al propietario técnico una lectura global por Data API ni permitir que un administrador consulte perfiles de otras tiendas. Debe comprobarse con dos negocios y cuentas separadas antes de aplicar la migración.

15. La migración de límites de negocio se revisó para que todas las políticas que crea tengan un `DROP POLICY IF EXISTS` previo. Se corrigieron dos excepciones detectadas al revisar la reejecución: la política de cancelaciones y la nueva política de lectura de perfiles de miembros del mismo negocio. La migración sigue sin ejecutarse; la idempotencia estática no sustituye una prueba de aplicación y reversión en una base de ensayo.

16. El borrador también limita las columnas de lectura directa de `profiles` a `id`, `display_name`, `avatar_url` y `phone`. Los campos internos `platform_role`, `is_blocked` y `blocked_reason` quedan fuera del Data API de clientes y miembros; las funciones de confianza siguen consultándolos con `service_role`. Verificar que la auditoría y los perfiles propios sigan mostrando solo los datos necesarios después de aplicar la migración.

17. Se detectó que los permisos efectivos de `authenticated` en perfiles, productos, métodos de pago, costos y negocios estaban concedidos por columna. Un `REVOKE UPDATE ON TABLE` por sí solo no retiraba esos permisos de columna. El borrador ahora revoca explícitamente las columnas antiguas antes de conceder únicamente los campos editables aprobados. También limita explícitamente las columnas SELECT de perfiles. Esta corrección se basa en la introspección de privilegios reales de PostgreSQL; todavía requiere una prueba de permisos después de aplicar el SQL en un entorno aislado.

18. La nueva columna `business_memberships.job_title` recibe permiso SELECT por columna para `authenticated`, sujeto a la política RLS que limita las filas a la propia membresía o al equipo del negocio administrado. No se concede INSERT, UPDATE ni DELETE directo; los cambios siguen pasando por la función técnica.

19. **Separación de datos financieros de pedidos.** Se detectó que la política RLS de `orders` limitaba filas por negocio, pero el rol compartido `authenticated` podía leer también `total`, `subtotal`, `delivery_fee` y `payment_status` de los pedidos operativos de empleados. RLS no filtra columnas por rol de membresía. Se añadió `database/orders/order-financial-access-draft.sql`: retira SELECT directo de importes y estados de pago, conserva columnas operativas, entrega finanzas a administradores mediante `get_business_admin_order_financials` y mantiene el historial financiero de clientes mediante `get_customer_order_history`, que consulta únicamente pedidos del usuario autenticado. También retira precios por línea de `order_items` en consultas directas. **Orden de migración:** aplicar primero `checkout-idempotency-draft.sql` (crea `customer_user_id` y políticas de historial) y después este borrador. El panel de administrador y `cuenta.js` se actualizaron para usar los RPCs. Todo sigue pendiente de prueba en una base aislada; no se ejecutó SQL.

20. Se añadió `database/orders/verify-order-financial-access.sql`, una verificación de solo lectura para ejecutar después de aplicar el borrador de acceso financiero. Comprueba que authenticated no pueda leer importes ni precios por línea directamente, que conserve las columnas operativas y que los RPCs estén ejecutables solo por authenticated, no por anon ni PUBLIC. Esta verificación valida grants y ACL, pero no reemplaza pruebas con usuarios reales de negocio A/B, empleado, administrador y cliente.

21. **Confirmación de pagos recibidos.** La auditoría read-only no encontró una función que cambiara `orders.payment_status` a `paid`; el checkout siempre inicia en `pending`. Se añadió al borrador financiero `mark_order_payment_received`, exclusivo del administrador activo, que bloquea el pedido, rechaza cancelados/fallidos/reembolsados y valores cero, exige referencia para transferencias/tarjetas/otros medios, inserta el movimiento `payment_received`, actualiza el pedido y registra auditoría en una sola transacción. Un índice único impide registrar dos ingresos completados para el mismo pedido. El panel del administrador incorpora el botón “Confirmar pago recibido” y exige confirmación explícita; no se realiza ningún cobro automático ni se conecta a pasarelas. La introspección live encontró 0 pedidos y 0 movimientos financieros, por lo que no había datos existentes que migrar ni duplicados al momento de la revisión. Sigue sin ejecutarse y requiere prueba en staging.

22. La política RLS de `order_items` para clientes se ajustó para no depender de conceder SELECT sobre `orders.customer_user_id`. El helper `private.customer_owns_order` verifica la propiedad con `SECURITY DEFINER`; solo authenticated puede ejecutarlo y la función no devuelve el identificador del cliente. Se confirmó por introspección que el rol authenticated tiene USAGE del esquema `private` y EXECUTE de los helpers de negocio existentes. Falta probar la política en staging con dos clientes y pedidos distintos.
