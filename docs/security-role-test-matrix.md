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


## Auditoría de solo lectura: pedidos, inventario, cancelaciones y finanzas — 13 de noviembre de 2026

Se volvió a consultar el esquema activo del proyecto independiente. Esta revisión confirma que los borradores aún no están aplicados y que los siguientes permisos siguen vigentes en live:

- `orders_members_select` y `orders_members_update_status` todavía incluyen `private.is_platform_owner()` como alternativa. El propietario técnico conserva acceso directo a filas de pedidos y a la actualización permitida por la política live.
- `order_items_members_select` todavía incluye el bypass del propietario técnico.
- `products_authenticated_select` todavía incluye el bypass del propietario técnico.
- `financial_admin_select` y `refund_admin_select` todavía permiten lectura global al propietario técnico.
- `cancellation_members_select` todavía permite lectura de solicitudes al propietario técnico y a empleados.
- `product_costs_admin_select/insert/update` todavía incluyen el bypass del propietario técnico.
- El trigger live `private.enforce_order_status_transition()` todavía permite al propietario técnico cambiar estados y no exige que el negocio esté activo. El reemplazo del borrador elimina ese bypass y exige administrador/empleado del negocio activo.
- Los grants live de `orders` solo permiten UPDATE directo de `status` y `delivery_tracking` a `authenticated`; no permiten cambiar directamente importes ni `payment_status`.
- La función live `create_public_order` es SECURITY DEFINER, pero no es ejecutable por `anon`, `authenticated` ni `PUBLIC`. La creación pública se mantiene canalizada por la Edge Function/rol de servicio; no se detectó una vía RPC directa para saltarse su validación.
- `create_public_order` bloquea cada producto con `FOR UPDATE`, valida inventario y descuenta existencias en la misma transacción que crea el pedido y sus líneas.
- En el esquema live todavía no existen las RPC nuevas de cancelación/reembolso/consulta financiera; por tanto, esos flujos continúan siendo borradores y no deben habilitarse en el panel antes de aplicar y probar sus migraciones.

### Qué corrige la rama de trabajo

El borrador `database/security/business-admin-boundaries.sql` reemplaza las políticas de pedidos, líneas, productos, costos, movimientos financieros, detalles de reembolso y solicitudes de cancelación para retirar los bypasses del propietario técnico. Conserva el acceso operativo de administradores/empleados al negocio activo y reserva la bandeja de cancelaciones y las finanzas al administrador.

El borrador `database/orders/order-financial-access-draft.sql` retira de `authenticated` la lectura directa de importes y estado de pago en `orders`, y de precios por línea en `order_items`. Los importes del negocio se consultan mediante un RPC que valida administrador activo; el historial del cliente usa otro RPC limitado a `auth.uid()`. Incluye un helper privado para que la política de líneas del cliente no requiera exponer `customer_user_id`.

Los borradores `cancellation-flow-draft.sql` y `refund-flow-draft.sql` mantienen escrituras detrás de RPCs SECURITY DEFINER con `search_path` vacío, comprobación de usuario/rol/negocio y revocación de EXECUTE a PUBLIC y anon. La cancelación aprobada restaura inventario dentro de la misma transacción; el reembolso registra una devolución total que el negocio ya realizó externamente, no transfiere dinero ni se conecta a una pasarela.

### Resultado y pruebas pendientes

La inspección de políticas live confirmó que los accesos amplios señalados siguen activos hasta aplicar las migraciones; no se deben describir como corregidos en producción. Los borradores contienen las sustituciones previstas, pero todavía no se han ejecutado.

Antes de habilitar estas funciones, aplicar en un entorno aislado y probar con cuentas reales separadas:
1. propietario técnico, administrador A, empleado A, administrador B, empleado B y cliente.
2. El técnico no debe leer pedidos, costos, finanzas ni solicitudes de cancelación por Data API.
3. El empleado solo debe ver pedidos operativos y actualizar los estados/transporte permitidos; no importes, pagos, costos ni bandeja de cancelaciones.
4. El administrador A solo debe ver y gestionar operaciones financieras y cancelaciones de A, nunca de B.
5. Un cliente solo debe consultar su historial y los precios de sus propios pedidos.
6. Reintentos y concurrencia de checkout, solicitudes y decisiones de cancelación, restauración exacta de inventario y reembolso único.
7. Comprobar que el panel del administrador utiliza los RPC financieros y que el panel de empleados no solicita columnas que se retirarán del Data API.

No se ejecutó SQL, no se desplegó ninguna función y no se modificó información de pedidos o inventario live durante esta auditoría.


### Verificación estática de la integración del panel — 13 de noviembre de 2026

Se revisó también `panel-live.js` en la rama:
- El panel del administrador consulta los importes y estados de pago mediante `get_business_admin_order_financials` y combina esos datos con una consulta operativa de pedidos y productos.
- El panel de empleados solicita únicamente identificador, número, datos de entrega, estado, fecha y nombre/cantidad de productos. No solicita `total`, `payment_status`, `unit_price` ni `line_total`.
- El panel administrativo utiliza el mismo RPC financiero para los indicadores y las listas; la bandeja de reembolsos usa el filtro `p_refundable_only`.
- Las acciones de cancelación y reembolso se invocan mediante las RPCs correspondientes; la interfaz informa que el reembolso debe haberse realizado externamente antes de registrarlo.

Resultado de comprobaciones estáticas sobre los borradores SQL y el JavaScript de panel: **15 de 15 verificaciones aprobadas**. Se comprobaron sustitución de políticas, eliminación del bypass técnico en el trigger, retiro de columnas financieras del acceso directo, ACL de RPCs y separación de consultas de administrador/empleado. Esto no equivale a pruebas de ejecución ni de autorización con usuarios reales.

La auditoría live sigue mostrando las políticas antiguas hasta que las migraciones se apliquen en staging y luego se autorice su paso a producción.


## Revisión de gastos y auditoría — 13 de noviembre de 2026

La inspección live encontró que la política `business_expenses_insert` permitía a un administrador insertar un gasto con `payment_status='paid'` y/o `paid_at` definido desde el primer INSERT. Eso permitía registrar como pagado un gasto sin pasar por la transición protegida del trigger. El trigger de UPDATE sí limita cambios posteriores: solo permite pasar de pendiente a pagado, o anular una sola vez, y compara el resto de las columnas para rechazar modificaciones adicionales.

Se corrigió el borrador `database/security/business-admin-boundaries.sql`:
- La política de INSERT ahora exige `payment_status='pending'`, `payment_method IS NULL`, `paid_at IS NULL`, estado activo y campos de anulación vacíos.
- Exige que `created_by = auth.uid()`, que el usuario sea administrador del negocio y que el negocio esté activo.
- Revoca privilegios de INSERT y UPDATE tanto a nivel de tabla como a nivel de columna (incluidas concesiones antiguas por columna).
- El INSERT solo concede columnas propias del gasto y no permite asignar ID, timestamps del sistema ni campos de pago/anulación.
- El UPDATE solo concede columnas necesarias para marcar pago o anular; el trigger sigue validando la transición y que ninguna otra columna cambie.

La política live `audit_logs_owner_or_business_admin_select` permite al propietario técnico consultar auditoría global, coherente con su función de supervisión, y a administradores consultar auditoría de su negocio. Los registros de auditoría no tienen permiso de escritura directa para `authenticated`; los eventos se generan desde funciones/operaciones controladas. La política de membresías live todavía conserva un bypass técnico y el borrador lo sustituye por lectura propia o del equipo del negocio para el administrador. La revisión de las funciones técnicas con service role y sus controles de autorización continúa pendiente.

Comprobaciones estáticas del nuevo bloque de gastos: 9/9 aprobadas. No se ejecutó SQL ni se modificaron gastos live.


## Auditoría de Edge Function técnica y operaciones con service_role — 13 de noviembre de 2026

Se comparó la función activa `technical-business-management` (versión 6) con la versión preparada en la rama `correcciones-funcionales`.

### Hallazgo crítico en la versión activa

La versión live 6 verifica la sesión, el perfil, el bloqueo y `platform_role='platform_owner'` para acciones técnicas, pero **no comprueba el nivel MFA/AAL2**. La rama incorpora `auth.mfa.getAuthenticatorAssuranceLevel(token)` y rechaza toda acción del propietario cuando `currentLevel !== 'aal2'`. La función live no se ha reemplazado; el refuerzo todavía no está activo en producción.

La Edge Function está configurada con `verify_jwt=true`. En la rama, el token también se valida con `auth.getUser(token)` antes de crear el cliente con `SUPABASE_SERVICE_ROLE_KEY`. Después se consulta el perfil y se rechazan perfiles inexistentes o bloqueados. Todas las acciones técnicas, salvo `log_login` que tiene autorización por panel/membresía, pasan por la comprobación del propietario.

### Controles comprobados en la rama

- El propietario técnico debe tener AAL2 antes de ejecutar acciones, incluida la lectura de datos técnicos.
- Las acciones de invitación solo aceptan roles `business_admin` y `employee`; no permiten asignar `platform_owner`.
- La invitación comprueba que el negocio esté activo y que el usuario no tenga ya una membresía en ese negocio.
- Los cambios de rol/cargo y las suspensiones comprueban el último administrador activo; además, los updates usan valores anteriores en el filtro para detectar cambios concurrentes. El trigger SQL preparado protege el último administrador frente a carreras, pero sigue sin estar aplicado en live.
- La creación de negocio inserta solo los datos base (nombre, categoría, slug y creador); la configuración comercial queda para el administrador.
- Las operaciones técnicas registran auditoría y reportan advertencias si una operación se completó pero el evento de auditoría falló.
- Se corrigió `log_login` para exigir que el negocio también esté activo antes de registrar como válido el acceso de un administrador o empleado. Antes se verificaba la membresía activa, pero no el estado del negocio.

### Capacidad de eliminación pendiente

La Edge Function de esta rama no tiene acciones `delete_business` ni `delete_member`. La suspensión/cierre de negocio y suspensión de membresía sí están implementados. Por tanto, la eliminación real de negocios o cuentas no debe darse por disponible. Antes de agregarla hay que definir si será eliminación lógica/archivo o borrado físico y qué datos históricos deben conservarse; pedidos, transacciones y auditoría no deberían desaparecer por borrar una membresía.

### Pruebas pendientes y estado

Se aprobaron 14/14 verificaciones estáticas de autenticación, AAL2, roles, negocio activo, control de último administrador, auditoría y ausencia de acciones de borrado no implementadas. Son comprobaciones de código, no pruebas dinámicas con usuarios.

No se desplegó la nueva Edge Function, no se cambió la configuración de Auth y no se envió ninguna invitación. La versión live continúa en v6 sin el requisito AAL2.


## Auditoría de autenticación, invitaciones y recuperación — 13 de noviembre de 2026

### Corrección de activación de invitaciones

Se detectó que `aceptar-invitacion.js` aceptaba cualquier sesión que ya estuviera guardada en el navegador, aunque la URL abierta no correspondiera a una invitación. Se corrigió en esta rama:
- Exige una señal explícita `type=invite` en la consulta o el fragmento de la URL.
- Si recibe `token_hash`, lo verifica con `verifyOtp` y tipo `invite`.
- Después exige una sesión válida.
- Al terminar la verificación, limpia parámetros y fragmentos de la URL para retirar códigos/tokens de la barra de direcciones.
- Solo entonces habilita la creación de contraseña (mínimo 10 caracteres y confirmación coincidente).
- Al activar la cuenta, cierra la sesión y redirige al login.

### Revisión de los demás flujos

- El login interno no ofrece registro público de cuentas de panel. Resuelve los permisos desde `resolve-my-access` y filtra membresías activas de negocios activos.
- El propietario técnico debe verificar TOTP y confirmar AAL2 antes de entrar al panel. `panel-live.js` vuelve a comprobar AAL2 al cargar el panel técnico.
- El panel registra el acceso mediante `log_login` después de comprobar la sesión, rol/membresía y negocio activo.
- La recuperación de contraseña no permite cambiar la clave por tener una sesión normal: `actualizar-clave.js` espera el evento `PASSWORD_RECOVERY` antes de habilitar el formulario.
- El registro público de clientes permanece separado en `cuenta.js`; no asigna roles internos desde el navegador. El trigger de Auth live crea el perfil de cliente sin elevar privilegios.
- Los pedidos históricos de invitado no se vinculan automáticamente a una cuenta de cliente.

### Bloqueos de integración confirmados en la base live

La consulta de solo lectura del proyecto independiente confirmó que existe `profiles`, pero todavía no existen `customer_favorites` ni `get_customer_order_history()`. La base tiene 1 usuario Auth, 1 perfil y 0 membresías. No se consultaron ni mostraron correos o identificadores.

Por tanto, el registro y login de clientes están preparados en código, pero favoritos e historial no pueden funcionar hasta crear y aplicar la migración correspondiente. En el repositorio de esta rama no se encontró un archivo SQL de migración para esas dos piezas.

### Configuración de Auth que sigue sin verificarse

No se pudo leer mediante las herramientas disponibles la lista efectiva de Redirect URLs permitidas, la plantilla de invitación, la plantilla de recuperación, SMTP ni la política de contraseñas configurada en Auth. No se deben enviar invitaciones reales ni dar por probada la recuperación hasta revisar en Supabase Dashboard:
- URL exacta de Pages para `aceptar-invitacion.html`.
- `cuenta.html` para confirmación de clientes.
- `actualizar-clave.html` para recuperación.
- Plantilla de invitación que conserve el indicador `type=invite` al regresar a la página.
- Plantilla y envío real de recuperación, SMTP y política de contraseñas.
- Protección de contraseñas filtradas/comprometidas.

La URL de invitación apunta a GitHub Pages, pero Pages en `main` sigue conectado al proyecto Supabase antiguo. No desplegar la función de invitaciones ni mandar invitaciones reales hasta resolver esa publicación.

### Pruebas estáticas

Resultado: 18/18 comprobaciones estáticas aprobadas para invitaciones, login, MFA, recuperación y resolución de permisos. No son pruebas end-to-end con correos reales ni usuarios de prueba.

No se enviaron correos, no se cambió Auth, no se desplegaron funciones y no se ejecutó SQL durante esta revisión.


## Preparación de migración de clientes y favoritos — 13 de noviembre de 2026

Se creó `database/customers/customer-account-migration.sql` en la rama de trabajo para cubrir el esquema que faltaba:
- Añade `orders.customer_user_id` como referencia a `auth.users` con `ON DELETE SET NULL`, para conservar pedidos si se elimina una cuenta.
- Añade índice por cliente y fecha del pedido.
- Crea `customer_favorites` con unicidad por usuario/producto y claves foráneas.
- Activa RLS y limita lectura y borrado al dueño; el INSERT solo permite productos activos de negocios activos.
- No concede UPDATE sobre favoritos ni lectura directa de `customer_user_id`.
- El historial financiero del cliente continúa detrás del RPC `get_customer_order_history()` del borrador `order-financial-access-draft.sql`.

Se ajustó `cuenta.js` para que los favoritos de productos que ya no están disponibles sigan apareciendo como no disponibles y puedan quitarse de la lista, en lugar de quedar ocultos sin opción de limpieza.

**Orden de dependencias:** primero esta migración de clientes; después `checkout-idempotency-draft.sql` y `order-financial-access-draft.sql`, porque esos borradores usan `orders.customer_user_id`. Todo debe probarse en staging antes de producción.

Resultado de comprobaciones estáticas: **12/12 aprobadas** sobre claves foráneas, índices, unicidad, RLS, políticas de dueño, límites de INSERT/UPDATE y dependencias de checkout/historial. La base live sigue sin la columna ni la tabla; no se ejecutó esta migración ni se modificaron datos.


## Auditoría de checkout público, idempotencia y seguimiento — 13 de noviembre de 2026

### Estado de la función activa frente a la rama

Se comparó la Edge Function live `create-public-order` v3 con el código de `correcciones-funcionales`. La versión activa todavía usa el flujo anterior: consume el rate limit antes de crear el pedido y llama directamente a `create_public_order`. No incluye la clave idempotente ni la asociación de la compra a la cuenta autenticada.

La rama prepara un flujo nuevo que:
- Valida el JWT del cliente cuando se envía una sesión autenticada; no confía en un `customer_user_id` enviado por el navegador.
- Rechaza perfiles inexistentes o bloqueados.
- Comprueba que el método de pago pertenezca al negocio indicado.
- Permite recuperar un pedido ya confirmado aunque el método se haya desactivado después.
- Para intentos nuevos, exige que el método siga habilitado.
- Consulta primero la clave idempotente; la función SQL serializa solicitudes simultáneas con un advisory transaction lock.
- Crea el pedido, descuenta inventario y guarda la respuesta idempotente en la misma transacción SQL.
- Rechaza reutilizar una clave con datos distintos.
- El límite se reserva mediante una RPC independiente solo para claves nuevas; la reserva permanece aunque la creación del pedido falle. Reintentar la misma clave y el mismo contenido no consume otra reserva.

### Permisos live consultados

La función activa `public.create_public_order` y `public.consume_checkout_rate_limit` son SECURITY DEFINER, propiedad de postgres y con EXECUTE concedido a `service_role`, no a `anon` ni `authenticated`. La tabla privada de rate limits no expone permisos de tabla a esos roles. Esto evita que el cliente llame directamente a la función de creación o manipule el contador mediante PostgREST.

### Corrección de privilegios en favoritos

Se detectó que el borrador de checkout concedía INSERT a nivel de tabla sobre `customer_favorites`, lo que ampliaba los privilegios más allá del diseño de la migración de clientes. Se corrigió para:
- Revocar los privilegios heredados de `PUBLIC`, `anon` y `authenticated`.
- Conceder INSERT solo en las columnas `user_id, product_id`.
- Mantener SELECT y DELETE, sujetos a RLS.
- Reemplazar las dos posibles políticas de INSERT por una sola política que exige propietario y producto/negocio activos.

### Seguimiento público de pedidos

La Edge Function live `track-public-order` v1 se incorporó al repositorio porque faltaba su fuente en la rama. El endpoint exige un token UUID, devuelve solo número de pedido, estado, fecha, negocio, total y seguimiento de entrega; no devuelve dirección, teléfono ni correo. Se añadió `Cache-Control: no-store, private` para evitar que la respuesta con datos del pedido quede almacenada en cachés compartidas.

El endpoint sigue siendo público por diseño: el token privado de seguimiento actúa como credencial de consulta. Debe mantenerse aleatorio, no mostrarse en páginas públicas ni incluirse en registros visibles.

### Pruebas estáticas y limitación de despliegue

Las verificaciones estáticas de la rama cubren validación de JWT, perfil bloqueado, método de pago asociado al negocio, recuperación idempotente, bloqueo transaccional, permisos service_role y respuesta mínima de seguimiento. El flujo nuevo no está desplegado: live sigue en v3 sin idempotencia. Tampoco se ejecutaron pruebas concurrentes ni pruebas con inventario real.

No se ejecutó SQL, no se desplegó ninguna Edge Function y no se cambió `main`.


### Refuerzo adicional del límite de solicitudes — 13 de noviembre de 2026

La revisión transaccional detectó que consumir el límite dentro de la transacción de creación provocaba que el contador se revirtiera si el pedido fallaba por inventario o validación. Eso dejaba los intentos fallidos fuera del límite.

Se corrigió el borrador SQL y la Edge Function:
- Se añadió la tabla privada `private.checkout_rate_limit_reservations`, sin permisos directos para anon, authenticated ni service_role.
- Se añadió la RPC `reserve_checkout_rate_limit`, SECURITY DEFINER, con `search_path` vacío y EXECUTE únicamente para service_role.
- La reserva se identifica por clave idempotente, IP hasheada con SHA-256 y hash del contenido del pedido.
- El límite sigue siendo 10 reservas por IP en 10 minutos.
- Una misma clave y el mismo contenido reutilizan la reserva existente; la misma clave con otra IP o contenido se rechaza.
- La Edge Function consulta primero si el pedido ya existe; si no existe, reserva el intento en una llamada RPC independiente y después crea el pedido idempotente.
- La creación del pedido y el almacenamiento de su respuesta continúan en la misma transacción; si falla la creación, no se crea un pedido parcial, pero la reserva del intento permanece.
- Las reservas se limpian después de 24 horas.

Comprobaciones estáticas: **14/14 aprobadas** para tabla privada, RLS, privilegios, hash, concurrencia por clave/IP, límite, orden de RPCs, validación de JWT y respuesta mínima de seguimiento.

Pendiente de prueba en staging: ráfagas concurrentes con distintas claves desde la misma IP, reintentos de misma clave, payload alterado, pedido rechazado por inventario y verificación de que el contador persiste tras el rollback del pedido. El nuevo SQL y la Edge Function siguen sin ejecutarse/desplegarse en el proyecto live.


### Verificación del código privado de seguimiento — 13 de noviembre de 2026

La base live confirma que `orders.public_tracking_token`:
- Es UUID NOT NULL.
- Se genera por defecto con `gen_random_uuid()`.
- Tiene un índice UNIQUE.

La Edge Function live `track-public-order` v1 y el código de la rama consultan el pedido exclusivamente por ese token y devuelven número, estado, fechas, negocio, total y estado de entrega. No devuelven teléfono, dirección ni correo. La rama añade `Cache-Control: no-store, private`; esa cabecera todavía no está en la versión live.

Pendiente: la función de seguimiento no tiene un límite de solicitudes por IP en el código revisado. El UUID aleatorio hace inviable una búsqueda práctica por fuerza bruta, pero el rate limit ayudaría a reducir abuso de recursos. Debe incorporarse antes de considerar cerrada la auditoría de endpoints públicos.

La consulta de esquema e índices fue de solo lectura. No se modificaron pedidos ni tokens.


## Auditoría integral de los cinco bloques funcionales — 13 de noviembre de 2026

**Alcance:** revisión estática del código de la rama `correcciones-funcionales`, lectura de solo lectura del proyecto Supabase independiente y comparación de funciones desplegadas con las preparadas en la rama. No equivale a una prueba end-to-end.

### Bloque 1. Checkout y funciones públicas

**Revisado**
- `create-public-order` valida UUID de negocio, método de pago, clave de idempotencia, campos de cliente, productos y cantidades.
- Consulta que el método de pago pertenezca al negocio y esté habilitado para una compra nueva.
- Si hay sesión de cliente, valida el access token con Auth, comprueba el perfil y rechaza cuentas bloqueadas; invitados pueden comprar.
- La rama usa `get_public_order_idempotent`, reserva de límite por IP y `create_public_order_idempotent`.
- `get-public-storefront` devuelve solo métodos habilitados de negocios activos.
- `track-public-order` exige un token UUID y devuelve únicamente los campos previstos para seguimiento; las respuestas usan `Cache-Control: no-store`.
- `create-job-application` valida negocio y vacante activa/aprobada, consentimiento, tipo/extensión declarados, tamaño máximo, sesión de carga con expiración y límite de solicitudes. La descarga para el administrador se hace mediante URL firmada temporal.

**Corrección aplicada**
- Se detectó una incompatibilidad potencial para compras de invitados: el navegador usa una clave moderna `sb_publishable_`, mientras que el runtime también puede exponer la clave legacy `SUPABASE_ANON_KEY`. Comparar solo contra una de ellas podía interpretar la clave pública como access token y rechazar al invitado. La rama ahora reconoce las claves anon configuradas y el prefijo público moderno; los JWT de usuario siguen pasando por `auth.getUser`.
- Commit: `3df6a65e680cc1d34afefc82f3c1d7734265cefa`.

**Bloqueo live**
- Edge Function live `create-public-order` continúa en versión 3 y no contiene la nueva idempotencia. La versión de la rama depende de `checkout-idempotency-draft.sql`, que no está aplicado ni desplegado.
- El endpoint público de seguimiento no tiene un limitador propio. El token UUID tiene alta entropía; agregar límites y métricas sigue siendo una mejora recomendada.
- Los documentos adjuntos de postulaciones no pasan por análisis antivirus ni inspección profunda del contenido. La extensión/MIME/tamaño no prueban que un documento sea seguro.

### Bloque 2. Pedidos, inventario, cancelaciones y reembolsos

**Revisado**
- La función SQL live `create_public_order` recalcula importes en servidor, valida negocio/productos activos, rechaza líneas duplicadas y cantidades inválidas, bloquea las filas de productos con `FOR UPDATE`, verifica inventario y descuenta existencias dentro de la misma transacción.
- Los productos y costos históricos se guardan en sus tablas correspondientes.
- El flujo preparado de cancelaciones bloquea pedido/solicitud, requiere aprobación administrativa, impide doble decisión y repone inventario dentro de la transacción.
- El flujo de reembolsos registra una devolución ya ejecutada externamente; no realiza transferencias ni cobros automáticos.

**Bloqueo live**
- El trigger live de estados todavía permite bypass del propietario técnico; la versión preparada en `business-admin-boundaries.sql` lo elimina y exige membresía activa de administrador/empleado.
- No existen todavía en la base live los RPC `get_business_admin_order_financials`, `mark_order_payment_received`, `request_order_cancellation`, `decide_order_cancellation` ni `complete_order_refund`. Sus definiciones están en los borradores SQL.
- El panel de administrador llama a esos RPC. En especial, `loadBusinessAdmin()` necesita `get_business_admin_order_financials`; sin aplicarlo, el panel no puede completar su carga financiera.
- La migración de checkout idempotente y la migración de vinculación de clientes deben aplicarse antes que los RPC financieros que usan `orders.customer_user_id`. Cancelaciones y reembolsos deben aplicarse después de sus dependencias.

### Bloque 3. Paneles y permisos

**Revisado**
- Las páginas activas del modelo de tres paneles son `panel-tecnico.html`, `panel-negocio.html` y `panel-personal.html`; comparten `panel-live.js`.
- Se compararon 58 selectores usados por el JavaScript con los identificadores de las tres páginas: no se encontraron referencias a IDs ausentes en el conjunto de páginas.
- El panel de empleados muestra cola de pedidos sin importes y permite avanzar estados mediante el trigger.
- El panel de administrador incluye pedidos, cancelaciones, registro de reembolsos, productos, configuración comercial, contenido/vacantes, postulaciones y auditoría.
- `panel-admin.html` se identifica explícitamente como prototipo visual sin conexión; no debe confundirse con el panel administrativo activo, que es `panel-negocio.html`.

**Funciones pendientes**
- El panel de administrador no tiene módulo de gastos operativos; tampoco presenta gráficos consolidados diarios, mensuales y anuales de ingresos/gastos.
- El panel técnico indica que finanzas globales y nómina no están conectadas. La base live no contiene `platform_financial_records` ni `payroll_records`.
- El panel técnico muestra las solicitudes de bloqueo como no disponibles; el panel de negocio puede enviar una solicitud, pero la cola técnica todavía no está implementada.
- El formulario de promociones y vacantes está presente, pero debe probarse el flujo completo de publicación, moderación, postulación, carga y descarga de documentos.

### Bloque 4. Página pública y cuentas de clientes

**Revisado**
- El registro público de clientes está separado del login interno de paneles.
- La página consulta negocios/productos registrados, métodos de pago públicos y contenido aprobado. Los productos de demostración no permiten comprar.
- El checkout puede asociar el pedido al cliente autenticado desde el servidor; no confía en un `customer_user_id` enviado por el navegador.
- Se preparó la migración `customer-account-migration.sql` para `orders.customer_user_id` y `customer_favorites`.
- El historial está encapsulado en `get_customer_order_history()`; los favoritos tienen políticas RLS de propietario.

**Bloqueo live**
- `orders.customer_user_id` y `customer_favorites` aún no existen. Por eso el historial y los favoritos no están operativos en la base independiente.
- No se vinculan automáticamente pedidos anteriores de invitado por correo; no se debe hacer esa asociación sin un proceso de verificación de titularidad.
- No hay negocios ni productos registrados en el proyecto independiente, así que no se puede completar una compra real de prueba.

### Bloque 5. Auditoría integral y seguridad

**Hallazgos confirmados en Supabase live**
- Siguen activas políticas con bypass `platform_owner` en `orders`, `order_items`, `business_memberships`, `profiles` y lectura de `business_content_pages`. El borrador de límites de administrador elimina esos bypass del Data API y reserva las operaciones técnicas a la Edge Function.
- El asesor de seguridad mantiene la advertencia de protección de contraseñas comprometidas desactivada. Debe revisarse en Auth > Password Security antes de producción.
- Las tablas internas de limitación y sesiones de carga tienen RLS habilitado sin políticas; la revisión de grants indica que no se concedió acceso a anon/authenticated, por lo que no se deben abrir para silenciar el aviso.
- El asesor detecta 16 claves foráneas sin índice, 17 índices sin uso registrado y una advertencia por dos políticas SELECT permisivas en `business_content_pages`.
- Se ajustó el borrador SQL para separar la política pública `anon` (sin invocar helpers privados) de la política `authenticated` (catálogo público más lectura del administrador de su negocio). Así se evita exigir a `anon` EXECUTE sobre `private.business_is_active` o `private.has_business_role`. El cambio actual está en el commit `4ae88a7dba0c0da9e8fc8d72ccdf8b99412bfaa1`.
- El asesor de salud no reportó hallazgos.

**Datos disponibles para pruebas**
- El proyecto independiente tiene 1 usuario Auth, 1 perfil y 0 membresías.
- No hay negocios ni productos registrados.
- Las funciones desplegadas son: `technical-business-management` v6, `create-public-order` v3, `track-public-order` v1, `resolve-my-access` v2, `get-public-storefront` v2 y `create-job-application` v2.
- La rama contiene cambios que todavía no están desplegados; no asumir que el código de GitHub coincide con la función live.

### Estado de los cinco bloques

La revisión estática de los cinco bloques quedó completada. **La auditoría funcional todavía no se puede declarar aprobada para producción**: faltan aplicar los borradores en staging, crear datos de prueba aislados, probar dos negocios con roles distintos, ejecutar compras concurrentes, validar correos/redirects y revisar los resultados de punta a punta.

No se ejecutó SQL, no se desplegaron funciones, no se fusionaron PR y no se modificó `main`.


### Verificación estática final de la revisión — 13 de noviembre de 2026

Se ejecutó una pasada adicional de 16 comprobaciones sobre la clave publishable, validación de sesión, asociación de cliente, idempotencia, límites de solicitudes, permisos de RPC, borradores de pedidos/cancelaciones/reembolsos, límites de negocio, política pública unificada y documentación. **16/16 pasaron**. Este resultado verifica presencia y consistencia estática de los controles; no sustituye ejecución SQL ni pruebas con solicitudes reales.

El PR #2 continúa abierto como borrador, desde `correcciones-funcionales` hacia `integracion-supabase-independiente`. No está fusionado. `main` no fue modificado.


### Hallazgo de dependencias durante el armado del paquete

Al preparar el verificador de staging se comprobó que los roles `anon` y `authenticated` no tienen EXECUTE sobre `private.business_is_active(uuid)` ni `private.has_business_role(uuid,text[])`. Por eso no era correcto usar esos helpers dentro de una política `FOR SELECT TO anon, authenticated`. Se corrigió el borrador `business-admin-boundaries.sql`: la política `anon` usa la condición pública y un EXISTS sobre columnas públicas de `businesses`; la política `authenticated` conserva los helpers privados. Los permisos de columnas públicas de `businesses.id/status` sí están disponibles para anon. No se otorgó EXECUTE adicional a anon.


## Paquete de integración preparado — 13 de noviembre de 2026

Se preparó la carpeta `database/integration/`:
- `README.md`: orden de aplicación, dependencias, despliegue de funciones, condiciones de MFA, pruebas y criterios de salida.
- `00-preflight.sql`: inventario previo de tablas, columnas, helpers, buckets, políticas y grants; solo lectura.
- `verify-integration-package.sql`: comprobación posterior de tablas, RPCs, RLS, grants, políticas públicas por rol, helpers privados y Storage; solo lectura.

Orden de staging definido:
1. `platform-public-settings-draft.sql`
2. `business-admin-boundaries.sql`
3. `storage-policy-fix.sql`
4. `customer-account-migration.sql`
5. `checkout-idempotency-draft.sql`
6. `order-financial-access-draft.sql`
7. `cancellation-flow-draft.sql`
8. `refund-flow-draft.sql`

`owner-mfa-rls.sql` queda como etapa condicionada posterior a desplegar y probar la interfaz MFA y la Edge Function técnica AAL2 en staging. No debe aplicarse antes.

Durante la preparación se detectó y corrigió un delimitador `DO` mal formado en `business-admin-boundaries.sql`. También se detectó que `anon` no tiene EXECUTE sobre los helpers privados de negocio; por eso las políticas de contenido se separaron por rol y no se concedió acceso adicional a esos helpers.

Comprobaciones estáticas del paquete: **50/50 aprobadas** en delimitadores, comentarios, políticas repetibles y separación de permisos de lectura pública/admin. No se ejecutó un parser SQL conectado ni se aplicaron migraciones; el resultado no equivale a ejecución real.

El paquete sigue pendiente de staging. No se ejecutó SQL, no se desplegaron Edge Functions, no se fusionó el PR ni se modificó `main`.

## Hallazgo adicional: lectura anónima del catálogo público

La prueba de solo lectura ejecutada con `SET LOCAL ROLE anon` confirmó que:
- La consulta pública de `businesses` puede ejecutarse con las columnas comerciales necesarias.
- Las consultas de `products` y `business_content_pages` fallan con `permission denied for function private.business_is_active`, porque sus políticas públicas actuales invocan un helper privado sin permiso de ejecución para `anon`.
- No se debe solucionar concediendo ejecución de helpers privados al rol anónimo.

Se añadió al borrador `database/security/business-admin-boundaries.sql`:
- Reemplazo de `products_public_active_anon` por una política que comprueba `is_active` y la existencia de un negocio con `status='active'`.
- Separación de `business_content_pages_public_read` para `anon`, también con comprobación directa del negocio activo; la política autenticada conserva sus helpers de membresía.
- Grants de lectura limitados a las columnas públicas de `businesses`, manteniendo privados `suspension_reason`, `created_by`, `created_at` y `updated_at`.
- Política explícita `businesses_public_directory_anon` para negocios activos o suspendidos.
- Verificaciones post-migración para grants, políticas y ausencia de ejecución anónima de helpers privados.

La prueba de catálogo debe repetirse en ensayo después de aplicar la migración. No se modificó el proyecto activo.

## Auditoría del flujo completo de pedidos — 14/11/2026

### Hallazgos confirmados en el proyecto Supabase activo

- `create-public-order` está desplegada como versión 3. La interfaz ya envía `idempotency_key`, pero la función activa no la lee ni llama a las RPC idempotentes: consume `consume_checkout_rate_limit` y llama directamente a `create_public_order`. Si el navegador reintenta una solicitud cuya respuesta se perdió, puede crear un segundo pedido y volver a descontar inventario.
- Las RPC `get_public_order_idempotent`, `reserve_checkout_rate_limit` y `create_public_order_idempotent` no existen todavía en la base activa. La corrección de la rama depende de aplicar primero `database/customers/customer-account-migration.sql` y después `database/orders/checkout-idempotency-draft.sql`, y desplegar la Edge Function de la misma rama.
- La función activa `private.enforce_order_status_transition()` todavía permite el bypass de `platform_owner`. Las políticas activas de `orders` y `order_items` también conservan acceso global para ese rol. La migración `database/security/business-admin-boundaries.sql` sustituye ese acceso por membresías activas de cada negocio.
- `track-public-order` está desplegada como versión 1 y no añade `Cache-Control: no-store`. La versión de la rama ya incluye esa cabecera para evitar almacenamiento en caché de respuestas que contienen información de pedidos.
- El panel de negocio y el panel de empleados permitían avanzar el pedido hasta `out_for_delivery`, pero no consultaban ni guardaban `orders.delivery_tracking`. La rama ahora solicita una referencia al iniciar el reparto y la muestra en el detalle del pedido; el cliente puede consultarla con su código privado.

### Comportamientos verificados por inspección

- La restricción `orders_status_check` de la base activa admite `pending`, `confirmed`, `preparing`, `ready`, `out_for_delivery`, `delivered` y `cancelled`.
- `create_public_order` bloquea cada fila de producto con `FOR UPDATE`, valida negocio/producto activo e inventario, calcula precios desde la base de datos y descuenta existencias dentro de la misma transacción que crea el pedido.
- El panel actualiza el pedido filtrando por `id` y `business_id`; la política RLS y el trigger de transición deben validar además la membresía y el paso permitido.
- La cancelación con aprobación y restitución de inventario está preparada en `database/orders/cancellation-flow-draft.sql`, pero sus RPC todavía no existen en la base activa. No se debe presentar como una función ya desplegada.
- La consulta pública de seguimiento utiliza un token UUID aleatorio y devuelve número de pedido, negocio, estado, fecha, total y referencia de entrega. El token debe tratarse como código privado y entregarse únicamente al cliente que realizó la compra.

### Pruebas obligatorias antes de producción

1. Repetir una misma solicitud con la misma clave y el mismo contenido: debe devolver el mismo pedido y no descontar inventario otra vez.
2. Repetir simultáneamente dos solicitudes con la misma clave: debe existir un solo pedido.
3. Reutilizar una clave con contenido diferente: debe responder conflicto.
4. Confirmar que `platform_owner` no puede consultar ni cambiar pedidos desde el Data API; admin/empleado A solo acceden a pedidos de A.
5. Avanzar cada estado en orden y comprobar que saltos, retrocesos y cancelaciones directas se rechazan.
6. Al marcar `out_for_delivery`, guardar una referencia y comprobar que aparece en el seguimiento público; verificar también que el dato se escapa como texto y no ejecuta HTML.
7. Aprobar una cancelación y comprobar que pedido e inventario cambian juntos; rechazarla y comprobar que ninguno cambia.
8. Probar dos compras concurrentes por las últimas unidades y una cancelación con varias líneas del mismo producto.
9. Ejecutar pruebas A/B con datos ficticios en un entorno controlado. La base activa inspeccionada no tiene negocios, productos ni pedidos de prueba, por lo que no se ha podido completar una compra real ni una entrega de extremo a extremo.

**Estado:** los ajustes de código y verificadores están preparados en `correcciones-funcionales`. No se han aplicado migraciones ni desplegado Edge Functions; el sitio publicado tampoco se ha cambiado.

### RPC de operaciones aún ausentes en la base activa

La consulta de solo lectura del 14/11/2026 confirmó que todavía no existen estas RPC requeridas por los paneles y por el checkout:

- `get_public_order_idempotent`, `reserve_checkout_rate_limit` y `create_public_order_idempotent`.
- `get_business_admin_order_financials` y `mark_order_payment_received`.
- `request_order_cancellation` y `decide_order_cancellation`.
- `complete_order_refund` y `get_customer_order_history`.

Por tanto, las pantallas y botones que llaman a esas RPC no deben considerarse operativos en el proyecto activo hasta aplicar y verificar las migraciones correspondientes. En particular, el panel administrativo no podrá cargar el resumen financiero ni registrar pagos recibidos; empleados/admin no podrán completar el flujo nuevo de solicitudes de cancelación y el administrador no podrá registrar reembolsos mediante estas RPC. La presencia de tablas existentes no significa que los procedimientos de negocio estén instalados.


### Hallazgo adicional: confirmación de pagos del pedido

- El panel de administrador muestra la acción **Confirmar pago recibido** únicamente cuando el pedido tiene pago pendiente. La acción llama a `mark_order_payment_received`.
- En la base activa inspeccionada, esa RPC todavía no existe. Por tanto, el botón no puede completar el registro financiero allí.
- La rama incluye la RPC en `database/orders/order-financial-access-draft.sql`. Esta valida que el actor sea el administrador activo del negocio, bloquea la fila del pedido, evita pagos duplicados, exige referencia para métodos distintos de efectivo, registra el movimiento financiero y cambia `payment_status` a `paid` en la misma transacción.
- El panel no debe afirmar que el pago fue cobrado automáticamente: es una confirmación manual de dinero que el negocio ya recibió por fuera de MiEje Market.
- El verificador de integración ahora comprueba que `mark_order_payment_received` permita ejecución a `authenticated` y la niegue a `anon`.


## Auditoría de cuentas e historial de compras — 14/11/2026

### Estado observado en Supabase activo

- `orders` no contiene `customer_user_id`; por tanto, los pedidos actuales no quedan vinculados a una cuenta autenticada.
- `customer_favorites` no existe y `get_customer_order_history()` tampoco está instalada. La pantalla `cuenta.html` puede iniciar sesión/registro, pero no puede mostrar historial ni favoritos en este proyecto hasta aplicar las migraciones.
- El trigger `on_auth_user_created` sí crea un perfil al registrar una cuenta y copia el nombre de `raw_user_meta_data.display_name`. No asigna roles internos.
- `order_items` conserva `product_name`, `quantity`, `unit_price`, `line_total` y `created_at`, por lo que existe información suficiente para mostrar el detalle histórico sin depender del catálogo actual.
- Los pedidos de invitados no se asocian por correo al registrarse posteriormente. Esto evita atribuciones automáticas inseguras; la vinculación futura de pedidos invitados requeriría un proceso de verificación de titularidad separado.

### Diseño preparado en la rama

- `customer-account-migration.sql` agrega `orders.customer_user_id` con FK `ON DELETE SET NULL`; elimina la relación con la cuenta si esta se elimina, pero conserva el pedido.
- La Edge Function `create-public-order` valida el JWT con Auth, comprueba que exista el perfil y que no esté bloqueado, y solo entonces asigna el identificador autenticado al pedido. Sin sesión, conserva `customer_user_id = NULL`.
- `get_customer_order_history()` filtra por `auth.uid()`, devuelve como máximo 50 pedidos recientes y sus líneas, importes y negocio. No acepta un identificador de cliente suministrado por el navegador.
- `customer_favorites` usa RLS para que cada cliente consulte, agregue y elimine únicamente sus propios favoritos. No permite UPDATE ni acceso anónimo.
- La pantalla de cuenta escapa los datos textuales antes de insertarlos en HTML y verifica que la sesión siga siendo la misma antes de actualizar resultados.
- El orden de migración está documentado: migración de clientes → idempotencia del checkout → acceso financiero e historial.

### Verificaciones añadidas

El verificador de integración ahora comprueba: existencia de la relación `customer_user_id`, RLS de favoritos, permisos de SELECT/INSERT/DELETE solo para `authenticated`, ausencia de UPDATE en favoritos, ejecución del historial solo para usuarios autenticados y FK `ON DELETE SET NULL`.

### Pruebas pendientes en un entorno de ensayo

1. Cliente A crea cuenta, realiza un pedido y lo ve en su historial; cliente B no puede verlo aunque conozca su UUID.
2. Un invitado realiza un pedido: `customer_user_id` queda NULL y el seguimiento por token continúa funcionando.
3. Una sesión caducada o un JWT inválido no puede vincular un pedido a una cuenta.
4. Una cuenta bloqueada no puede crear pedidos ni consultar historial.
5. Cliente A no puede consultar, insertar ni borrar favoritos de B; tampoco puede guardar un producto inactivo.
6. Borrar una cuenta conserva pedidos históricos y deja `customer_user_id` en NULL.
7. Un pedido histórico conserva nombre, cantidad y precios aunque el producto cambie de nombre o deje de estar publicado.
8. Los pedidos antiguos anteriores a la migración no se vinculan automáticamente por coincidencia de correo.

**Estado:** revisión de código y verificaciones estáticas preparadas en `correcciones-funcionales`. La base activa no ha recibido migraciones; no se ha probado registro, compra autenticada ni historial de extremo a extremo.

## Auditoría financiera de pedidos — 14/11/2026

### Estado observado en Supabase activo

- `financial_transactions` y `business_expenses` tienen RLS, pero las políticas activas `financial_admin_select` y `business_expenses_select` incluyen un bypass `private.is_platform_owner()`. Esto permite al propietario técnico lectura directa global de finanzas de negocios y contradice el modelo de paneles.
- Las RPC `register_business_expense`, `pay_business_expense` y `void_business_expense` exigen sesión y rol de administrador del negocio; el trigger `guard_business_expense_update` impide editar gastos libremente, pagar dos veces o modificar gastos anulados.
- `financial_transactions` todavía no tiene índices únicos parciales para un pago completado o reembolso completado por pedido. El índice activo `financial_business_order_id_unique` incluye también `id`, por lo que no impide múltiples movimientos del mismo tipo para el mismo pedido.
- No hay negocios, pedidos, gastos ni transacciones financieras en la base activa al momento de esta revisión; por eso no existen duplicados actuales, pero tampoco es posible probar operaciones reales.
- La base no registra actualmente una fecha de confirmación de pago en `orders`. El panel suma pedidos con `payment_status='paid'` usando `orders.created_at`; ese dato no equivale a un libro de caja por fecha efectiva de cobro.

### Correcciones preparadas en la rama

- `business-admin-boundaries.sql` elimina el bypass técnico de lectura de `financial_transactions`, `refund_details` y `business_expenses`. El técnico debe seguir usando las operaciones de gestión técnica, no las consultas financieras del negocio.
- `order-financial-access-draft.sql` crea el índice único parcial `financial_one_completed_payment_per_order` y la RPC `mark_order_payment_received()`. La RPC bloquea el pedido, acepta únicamente pagos pendientes, registra el movimiento y cambia el estado del pedido dentro de una transacción. Es una confirmación manual de un pago recibido por fuera, no una pasarela de pagos.
- `refund-flow-draft.sql` crea `financial_one_completed_refund_per_order` y `complete_order_refund()`. Solo registra un reembolso total ya realizado externamente, para un pedido cancelado y con solicitud aprobada; no mueve dinero.
- `panel-live.js` aclara las etiquetas del resumen para no presentar la suma de pedidos con pago confirmado como si fuera un libro de caja por fecha de cobro.
- El verificador de integración comprueba índices únicos de pago/reembolso, permisos de reembolso y ausencia del bypass del propietario técnico en políticas de lectura financiera.

### Pruebas obligatorias en ensayo

1. Administrador del negocio A consulta sus movimientos; no puede consultar negocio B.
2. Propietario técnico y empleados no pueden leer directamente movimientos, gastos ni detalles de reembolso de ningún negocio.
3. Una confirmación concurrente del mismo pedido solo crea un pago completado.
4. Una segunda confirmación de un pedido ya pagado falla sin insertar otro movimiento.
5. No se puede registrar un pago para pedido cancelado, fallido o reembolsado.
6. Solo un pedido cancelado, pagado y con cancelación aprobada puede registrar un reembolso.
7. Dos intentos simultáneos de reembolso no pueden crear dos devoluciones completadas.
8. El panel no cuenta un reembolso como dinero actualmente recibido.
9. Los reportes por día/mes/año se calculan con la fecha del movimiento financiero, separando ingresos, reembolsos y gastos; no se deben inferir desde `orders.created_at`.

**Estado:** revisión estática y correcciones preparadas en `correcciones-funcionales`. No se han aplicado migraciones ni desplegado funciones en el proyecto activo.
## Auditoría de inventario, costos y ganancias — 14/11/2026

### Hallazgos en Supabase activo

- `products` contiene precio de venta e inventario, pero el costo se guarda por separado en `product_costs` (costo vigente) y `order_item_costs` (costo histórico por línea de pedido).
- `create_public_order()` consulta `product_costs`, copia el costo a `order_item_costs` y descuenta existencias dentro de la misma transacción que crea el pedido. Los productos se bloquean con `FOR UPDATE`; una compra sin existencias suficientes falla.
- `order_item_costs.unit_cost` permite NULL. Si un negocio no registra el costo, el pedido igualmente puede completarse y su costo histórico queda desconocido. El reporte no debe presentar esa operación como ganancia real; debe marcarla como costo pendiente.
- El formulario de productos no tenía un campo para ingresar el costo y `panel-live.js` no consultaba ni guardaba `product_costs`. La base podía capturarlo, pero el administrador no tenía una forma integrada en el panel para mantenerlo.
- Las políticas activas de `product_costs` y `order_item_costs` permiten lectura del propietario técnico mediante `private.is_platform_owner()`. Esto contradice la separación acordada: los costos de cada negocio pertenecen a su administrador.
- `business_expenses` registra gastos por separado, con estado pendiente/pagado y anulación conservada. No deben sumarse como costo de producto ni confundirse con ventas.
- El panel presenta sumas de pedidos pagados, pero no calcula una utilidad neta verificable. Tampoco debe usarse `orders.created_at` como fecha de caja: el reporte financiero debe usar la fecha del movimiento confirmado.

### Correcciones preparadas en la rama

- `business-admin-boundaries.sql` reemplaza las políticas de `product_costs` y `order_item_costs` para que solo el administrador activo del negocio pueda consultar costos. El propietario técnico deja de tener acceso directo a costos de cada tienda.
- El formulario de productos incorpora costo unitario privado. El panel consulta los costos separados, los guarda en `product_costs` y muestra costo y margen bruto unitario; el costo no se agrega a la tabla pública `products`.
- Cuando no existe costo registrado, el panel lo muestra como pendiente y no inventa un margen. El checkout conserva el costo histórico disponible en `order_item_costs` al crear cada pedido.
- El verificador comprueba RLS en ambas tablas, políticas administrativas sin bypass técnico, ausencia de acceso anónimo y ausencia de escritura directa sobre el histórico de costos.

### Reglas para los reportes

- **Ventas:** importe de productos vendidos, separado de domicilios y reembolsos.
- **Costo de ventas:** suma de `unit_cost × quantity` de las líneas, usando el costo histórico guardado al comprar.
- **Ganancia bruta:** ventas de productos menos costo de ventas.
- **Gastos operativos:** gastos activos pagados, sin mezclar los pendientes ni los anulados.
- **Ganancia neta estimada:** ganancia bruta menos gastos operativos y otros cargos registrados por el negocio.
- Si alguna línea no tiene `unit_cost`, el reporte debe mostrar las ventas con costo pendiente y no etiquetar el resultado como utilidad real completa.
- Los reportes por día, mes y año deben basarse en la fecha del movimiento o del pedido según el indicador y explicar cuál fecha se usa. Los reembolsos reducen el ingreso neto, no se cuentan como ventas positivas.

### Pruebas obligatorias en ensayo

1. Guardar y editar costo de un producto sin exponerlo al catálogo público.
2. Administrador A no puede consultar costos del negocio B; empleados y propietario técnico tampoco pueden leerlos directamente.
3. Un pedido guarda el costo histórico aunque después cambie el costo vigente del producto.
4. Un pedido con costo ausente queda marcado como costo pendiente, sin utilidad inventada.
5. Una compra concurrente no puede dejar inventario negativo ni vender más unidades que las disponibles.
6. Una cancelación aprobada restaura existencias una sola vez; un reembolso no vuelve a sumar inventario.
7. Los gastos pendientes no se descuentan como egresos pagados; los anulados quedan fuera de los reportes.
8. Ventas, costo de ventas, ganancia bruta, gastos y ganancia neta coinciden con movimientos de prueba conocidos.

**Estado:** correcciones de interfaz, políticas y verificador preparadas en `correcciones-funcionales`. No se aplicaron migraciones ni se desplegaron funciones. La utilidad neta y los reportes completos siguen pendientes de implementación y pruebas; no se consideran listos para producción.
## Reporte financiero por periodo — 14/11/2026

- El resumen anterior suma el total de pedidos cuyo pago figura confirmado. No descuenta reembolsos, costos ni gastos y no debe llamarse ganancia.
- `financial_transactions` diferencia pagos y reembolsos. Solo se cuentan movimientos `completed`, ubicados por `completed_at` en hora de Bogotá.
- `business_expenses` solo se descuenta cuando está activo, pagado y tiene `paid_at`. Los gastos pendientes y anulados quedan fuera.
- Se añadió al borrador financiero el RPC `get_business_admin_profit_report(uuid,date,date)`, protegido para el administrador activo del negocio y con rango máximo de 367 días.
- El RPC devuelve ventas, reembolsos, ventas netas, costo histórico, ganancia bruta estimada, gastos pagados y resultado neto estimado. También informa líneas sin costo histórico.
- El panel incorpora un selector de fechas y resultados por periodo. Si el RPC no está instalado, informa que el reporte no está disponible; no inventa valores.
- El cálculo es una estimación operativa, no un estado contable certificado. No incluye impuestos, comisiones bancarias, depreciación ni cargos que el negocio no haya registrado.
- Pruebas obligatorias: periodos diario/mensual/anual; pagos y reembolsos en fechas distintas; gastos pagados/pendientes/anulados; costos ausentes; aislamiento entre negocios; fechas inválidas; comparación con movimientos de prueba.

**Estado:** reporte preparado en rama y migración pendiente. No se ejecutó SQL ni se publicó en GitHub Pages.
## Auditoría de gastos, pagos y comprobantes — 14/11/2026

### Estado comprobado en Supabase activo

- `business_expenses` tiene importe positivo, categoría, descripción, fecha, proveedor, referencia, ruta de comprobante, estado de pago, fecha de pago y campos de anulación. Los gastos se conservan al anularse.
- `register_business_expense` permite actualmente crear un gasto directamente como `paid`, sin pasar por `pay_business_expense`. Esto salta el paso uniforme de confirmación y no genera un evento propio en `audit_logs`.
- `pay_business_expense` bloquea el registro duplicado por fila y valida administrador activo, pero no exige referencia para transferencias/tarjetas y no registra evento de auditoría. El movimiento queda representado solo por columnas del gasto.
- `void_business_expense` conserva el registro y exige motivo, pero no escribe evento de auditoría.
- `financial_transactions` registra pagos/reembolsos de pedidos con estado, importe, método, proveedor, referencia, usuario y fecha de confirmación. La función de confirmación de pago del pedido crea el movimiento, actualiza el pedido y escribe auditoría en una transacción; tiene índice único parcial para evitar más de un pago completado por pedido.
- Las políticas activas de `business_expenses` y `financial_transactions` aún permiten al propietario técnico leer datos financieros. `business-admin-boundaries.sql` prepara la corrección para que solo el administrador activo del negocio tenga lectura directa.
- No existe bucket privado para comprobantes de gastos. Los buckets actuales son imágenes comerciales públicas y documentos privados de postulaciones laborales.
- El panel administrador no incluye todavía un módulo funcional para crear/listar/pagar/anular gastos ni adjuntar/consultar sus comprobantes.

### Correcciones preparadas

- Nuevo borrador `database/finance/expense-receipts-storage-draft.sql`: crea bucket privado de 5 MB para PDF/JPEG/PNG/WebP y permite leer/cargar solo al administrador del negocio propietario del gasto, con ruta `<business_uuid>/<expense_uuid>/<filename>`. No concede lectura pública ni UPDATE/DELETE de objetos.
- El verificador comprueba que el bucket permanezca privado y que existan las políticas de lectura/carga administrativa.
- La migración de límites de administrador elimina el acceso financiero global del propietario técnico.

### Pendiente antes de habilitar el módulo de gastos

1. Modificar `register_business_expense` para que siempre cree gastos pendientes; el pago debe pasar por una transición separada.
2. Exigir referencia cuando el método de pago sea transferencia o tarjeta.
3. Registrar en `audit_logs` cada creación, pago y anulación, incluyendo actor, negocio, importe y referencia, sin almacenar datos sensibles innecesarios.
4. Añadir RPC restringido para asociar el comprobante cargado al gasto y verificar que el objeto está en la ruta correcta.
5. Crear el módulo de gastos del panel administrador con lista, filtros, alta, confirmación, anulación y enlaces firmados temporales a comprobantes.
6. Probar aislamiento entre negocios A/B, empleados, propietario técnico, carga de archivos no permitidos, rutas falsificadas, doble pago y anulación.

**Estado:** hallazgos y borrador de almacenamiento privado preparados en la rama. No se aplicaron migraciones ni se desplegó el módulo. Los gastos y comprobantes no deben considerarse listos para uso real desde el panel.
- Se verificó que `audit_logs` admite negocio, actor, acción, entidad, identificador y detalles JSON. Se detectó que las funciones live de gastos no escribían eventos.
- Nuevo borrador `database/finance/business-expense-audit-draft.sql`: crea gastos únicamente pendientes; confirma pagos con referencia obligatoria para transferencia/tarjeta; bloquea la fila para impedir doble pago; registra creación, pago, anulación y adjunto de comprobante en `audit_logs`; permite asociar un único archivo existente del bucket privado a su gasto.
- El trigger de protección se amplía para permitir únicamente la transición de pago, la anulación y el adjunto único de comprobante. Los gastos anulados conservan acceso de lectura del comprobante para el administrador del negocio, sin permitir nuevas cargas.
- Se corrigieron las políticas del bucket para comparar UUID como texto y evitar conversiones de rutas no confiables, y para conservar lectura de comprobantes históricos de gastos anulados.
- La transición de pago del trigger permite actualizar la referencia junto con el método y la fecha; se revisó esta correspondencia entre RPC y trigger para evitar que el pago falle al guardar la referencia.
- La función de confirmación no procesa dinero ni valida una transferencia bancaria: registra que el administrador afirma haber recibido/realizado el pago. Se necesita conciliación humana y comprobante cuando aplique.

- Se añadió al panel administrador una sección de gastos con alta de gasto pendiente, listado, confirmación de pago, anulación y adjunto/consulta temporal de comprobantes. La interfaz invoca los RPCs del borrador y no permite que el técnico o los empleados gestionen gastos desde sus paneles.
- El formulario valida archivos PDF/JPG/PNG/WEBP de hasta 5 MB en el navegador; el bucket también limita tipos y tamaño, y Storage aplica RLS. La descarga de comprobantes usa enlaces firmados de duración corta.
- El módulo está integrado en la rama, pero queda sin prueba funcional real porque las funciones/migraciones siguen sin desplegarse y el proyecto activo no tiene datos de negocios/pedidos de ensayo.
