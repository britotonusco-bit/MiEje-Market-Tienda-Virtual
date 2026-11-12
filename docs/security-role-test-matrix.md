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
