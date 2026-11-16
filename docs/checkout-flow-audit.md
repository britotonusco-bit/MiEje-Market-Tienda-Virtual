# Auditoría del flujo de compra y checkout

Fecha: 16 de noviembre de 2026  
Rama revisada: `correcciones-funcionales`  
Proyecto inspeccionado: MiEje Market Independiente

## Alcance

Revisión estática del carrito público, la función Edge `create-public-order`, la función SQL activa `public.create_public_order` y los borradores de idempotencia y bloqueo de inventario. La revisión de la base de datos fue de solo lectura.

## Lo que ya está protegido en la función SQL activa

La función `public.create_public_order` está definida como `SECURITY DEFINER`, usa `search_path = ''` y solo permite ejecución a `service_role`. No está concedida directamente a `anon` ni a `authenticated`.

La función activa:

- Comprueba que el negocio esté activo.
- Comprueba que cada producto pertenezca al negocio indicado y siga activo.
- Bloquea cada fila de producto con `FOR UPDATE` antes de comprobar y descontar inventario.
- Calcula el subtotal usando los precios almacenados en la base de datos, no los precios enviados por el navegador.
- Comprueba el pedido mínimo y calcula el total con el domicilio.
- Inserta pedido, detalles, costos históricos y auditoría, y descuenta inventario dentro de la misma transacción.

Esto protege el stock frente a compras concurrentes sobre la misma fila de producto. El servidor sigue siendo la autoridad sobre precios y existencias.

## Problemas y correcciones necesarias

### 1. Idempotencia todavía no activa

La inspección del código realmente desplegado confirma que `create-public-order` está en versión 3. Esa versión no lee ni usa `idempotency_key` y llama directamente a `create_public_order`. Por eso, aunque el navegador guarde una clave temporal en `sessionStorage`, la función activa la ignora: un reintento después de perder la respuesta puede generar un segundo pedido.

Además, la versión desplegada consulta que el método de pago esté habilitado antes de crear el pedido, pero no bloquea la fila del método ni vuelve a validarla dentro de la misma transacción. Si el negocio desactiva el método entre esa consulta y la creación, existe una ventana para registrar un pedido con un método que ya se deshabilitó. La nueva propuesta de rama corrige el diseño con una comprobación transaccional y bloqueo `FOR SHARE`.

La versión 3 consume el límite de solicitudes por IP antes de validar el formato de cada producto y cantidad. Por eso, las solicitudes inválidas también consumen parte del límite de 10 intentos por 10 minutos. La validación de entrada debe ejecutarse antes de reservar el intento, manteniendo el límite también en el servidor.

La función Edge desplegada tampoco vincula el pedido con la cuenta autenticada del cliente. La asociación de pedidos con cuentas y el historial de compras siguen pendientes de aplicar y probar.


La base de datos inspeccionada no contiene las funciones `get_public_order_idempotent`, `reserve_checkout_rate_limit` ni `create_public_order_idempotent`. La función Edge activa `create-public-order` está desplegada en versión 3, mientras que la rama contiene una fuente más reciente que depende de esas RPC. Por tanto, el flujo idempotente de la rama no está implementado en el proyecto activo.

El borrador `database/orders/checkout-idempotency-draft.sql` propone una clave única por intento, un hash del contenido, una reserva de límite por IP y bloqueo transaccional para que dos solicitudes simultáneas con la misma clave no creen dos pedidos. Debe revisarse junto con la Edge Function antes de aplicarlo.

### 2. Carrera entre suspensión del negocio y checkout

La función SQL activa lee el negocio con estado `active`, pero no bloquea su fila durante la transacción. Si un administrador suspende el negocio justo después de esa lectura, el pedido podría continuar mientras la suspensión se procesa.

La versión corregida del borrador `database/inventory/checkout-inventory-lock-order-draft.sql` obtiene el registro del negocio activo con `FOR SHARE` antes de procesar productos. Así, la suspensión y el checkout quedan serializados: o el pedido termina primero, o la función detecta que el negocio ya no está activo. Este cambio está guardado solo en la rama de trabajo.

### 3. El borrador de bloqueo de inventario fue reconstruido

La versión inicial del archivo tenía un bloque incompleto, una expresión regular sin cerrar y fragmentos repetidos después del primer `COMMIT`. Se reconstruyó el archivo en la rama, conservando una sola función de checkout, un solo trigger de estados y una sola transacción.

La versión actual incorpora:

- Validación de UUID antes de convertirlos.
- Cantidades entre 1 y 99, validadas antes de convertir a entero.
- Rechazo de productos duplicados aunque sus UUID solo cambien en mayúsculas/minúsculas.
- Bloqueo del negocio activo con `FOR SHARE` durante el pedido.
- Bloqueo de productos en orden UUID ascendente con `FOR UPDATE`.
- Actualización de inventario acotada por `product_id` y `business_id`.
- Lectura del costo histórico con `FOR SHARE`, para que un cambio simultáneo de costo no altere la instantánea de ese pedido.
- Registro del movimiento de inventario como venta.

Los controles estáticos confirmaron que el archivo ya no contiene el fragmento incompleto ni duplicaciones y que conserva un único cierre `COMMIT`. **Esto no sustituye una validación de sintaxis en PostgreSQL.** El archivo sigue siendo un borrador y no se ha ejecutado en Supabase.

### 4. Respuesta de errores del checkout

El navegador anteriormente mostraba el mensaje genérico de `supabase-js` cuando la Edge Function respondía con un error HTTP, aunque el servidor enviara una explicación útil (por ejemplo, inventario insuficiente o método de pago deshabilitado).

Se corrigió `app.js` en la rama para leer el JSON de la respuesta HTTP mediante `error.context.clone().json()` y mostrar el campo `error` enviado por la función. Si no hay un cuerpo JSON legible, conserva el mensaje técnico de respaldo. La clave idempotente pendiente no se elimina cuando la solicitud falla, de modo que el cliente puede reintentar el mismo intento.

La corrección pasó controles estáticos, pero falta comprobarla desde el navegador con respuestas reales 400, 409, 429 y 500. También se corrigió la clasificación de la respuesta de producto no disponible: el texto real del SQL es plural (`Uno de los productos no está disponible`) y ahora la Edge Function lo devuelve como conflicto HTTP 409, no como error genérico 400.

### 5. Carrito con datos desactualizados

El navegador conserva en memoria los precios y existencias que recibió al cargar el catálogo. El servidor vuelve a comprobarlos al crear el pedido, lo cual evita aceptar precios o inventario antiguos. Sin embargo, cuando el servidor rechaza un pedido por cambio de precio, producto inactivo o falta de stock, el navegador no actualiza automáticamente el catálogo y el carrito para mostrar la situación nueva.

Antes de implementar se debe añadir una recuperación clara: informar el motivo, volver a consultar el negocio y sus productos, señalar qué líneas cambiaron y permitir que el cliente revise el nuevo total antes de volver a confirmar.

### 6. Reintentos después de perder la respuesta

El navegador guarda la clave de idempotencia y la huella del pedido en `localStorage`, sin guardar nombre, teléfono, dirección ni datos de pago. La conserva aunque se cierre la pestaña o se recargue la página.

La revisión adicional encontró dos riesgos: si el cliente cambiaba algún dato después de perder la respuesta, la página podía generar una clave nueva; y si el almacenamiento local del navegador no estaba disponible, continuaba con una clave que no podría recuperar tras cerrar la pestaña o recargar.

Se corrigió `app.js` en la rama:

- Lee la clave pendiente sin borrarla cuando cambia el contenido del pedido.
- Bloquea un segundo checkout con datos distintos mientras el intento anterior siga sin resolverse.
- Exige guardar la clave en `localStorage` antes de enviar el pedido; si no puede guardarla, no envía la solicitud.
- Conserva la clave ante errores del servidor cuya respuesta sea incierta.
- Limpia la clave ante rechazos HTTP 400, 409 o 429 que confirman que la operación no se creó, excepto si el mensaje indica conflicto de reutilización de la clave.

También se ajustó el borrador SQL de límite por IP: ahora permite que el mismo intento y contenido se reintenten desde una IP distinta, por ejemplo al cambiar de red, creando una reserva para esa IP sin borrar la reserva anterior. Una misma clave con contenido diferente sigue siendo rechazada. Las reservas se identifican por la combinación de clave e IP, y la función de creación exige la reserva correspondiente a la IP del intento actual.

El carrito sigue sin persistirse: después de recargar o cerrar la pestaña, el cliente debe reconstruir exactamente los mismos datos, productos y cuenta para recuperar el intento. La huella incluye el identificador de la cuenta autenticada (o NULL para invitados), de modo que un cambio de cuenta no se confunda con el mismo intento. Esta corrección reduce el riesgo de duplicados, pero debe validarse con pruebas de navegador y respuestas reales.

### 7. Reglas del carrito y del método de pago

- El carrito admite productos de un solo negocio a la vez; al elegir otro negocio, pide confirmación para vaciarlo.
- Los productos de demostración y los negocios suspendidos no pueden iniciar una compra.
- El checkout toma el identificador del método de pago del negocio.
- La Edge Function comprueba que el método pertenezca al negocio. El borrador idempotente vuelve a bloquear la fila del método con `FOR SHARE`, comprueba que siga habilitado y guarda el nombre como histórico.
- El navegador no envía el precio como autoridad; la función SQL calcula el precio real.
- El método de entrega se registra actualmente en las notas del pedido. Debe verificarse que las opciones que se muestran correspondan a las opciones reales configuradas por cada negocio.

## Compatibilidad con cancelaciones y reembolsos

La migración de checkout cambia los estados iniciales al vocabulario canónico: `received` y `on_the_way`. El borrador de cancelaciones usa estados terminales `delivered` y `cancelled`, por lo que no depende de los nombres antiguos `pending` ni `out_for_delivery`.

La cancelación aprobada actualiza el pedido y restituye las existencias dentro de la misma transacción. El borrador de movimientos de inventario registra esa restitución como `cancellation_return`. También propone impedir el borrado físico de productos que ya aparecen en líneas de pedido, para conservar la referencia necesaria para devolver existencias.

Los reembolsos se mantienen separados: el borrador financiero solo registra un reembolso total cuando el pedido ya está cancelado y existe exactamente un pago completado que coincide con el total. No ejecuta transferencias ni llama a una pasarela de pagos.

Durante la normalización de estados, el trigger `orders_audit_status` permanece activo y registrará los cambios de estados antiguos a los canónicos como eventos de auditoría. Debe revisarse ese efecto al preparar la migración definitiva, especialmente si ya existen pedidos reales al momento de aplicarla.

## Riesgos y límites pendientes de la idempotencia

1. La Edge Function consulta el registro del método de pago antes de buscar la respuesta idempotente. En el esquema activo, los administradores autenticados no tienen permiso SQL de DELETE sobre `business_payment_methods`; las operaciones normales de configuración desactivan métodos en vez de borrarlos. Esto permite recuperar un pedido anterior aunque el método se haya desactivado. La eliminación física solo está disponible para `service_role` y debe evitarse si existe historial asociado.
2. Las RPC de idempotencia solo deben ser ejecutables por `service_role`. La Edge Function debe mantenerse como la única puerta pública; no conceder ejecución de esas RPC a `anon` ni `authenticated`.
3. El límite por IP usa `cf-connecting-ip` y, como respaldo, `x-forwarded-for`. Antes de publicar, confirmar que el encabezado de respaldo lo establece un proxy confiable y no puede ser enviado libremente por el cliente; de lo contrario, debe eliminarse el respaldo y rechazarse solicitudes sin IP confiable.
4. La consulta de respuesta idempotente se hace antes de reservar un nuevo intento. Esto evita contar dos veces los reintentos legítimos, pero debe probarse que una clave no permita recuperar datos de pedido a alguien que no conoce el contenido original. No exponer la RPC de búsqueda directamente al navegador.
5. La tabla `private.checkout_idempotency` no tiene todavía una política de limpieza ni un plazo de conservación. No se debe inventar un plazo: hay que definirlo junto con la política de retención de pedidos, teniendo en cuenta que borrar la clave demasiado pronto puede permitir que un reintento tardío cree un segundo pedido.

## Estado de la base de datos al revisar

- Negocios: 0.
- Productos: 0.
- Pedidos: 0.
- Detalles de pedido: 0.
- Métodos de pago: 0.
- Extensión `pgcrypto`: instalada en el esquema `extensions`.

No existen registros reales con los que ejecutar pruebas de compra o concurrencia en este proyecto.

## Pruebas pendientes en entorno de ensayo

1. Compra válida con precio e inventario vigentes.
2. Cambio de precio después de cargar el catálogo.
3. Producto desactivado después de agregarlo al carrito.
4. Negocio suspendido justo antes de confirmar el pedido.
5. Dos clientes intentando comprar la última unidad.
6. Dos solicitudes simultáneas con la misma clave de idempotencia.
7. Reintento con la misma clave y el mismo contenido.
8. Reutilización de la clave con contenido diferente.
9. Error de red después de que el servidor haya creado el pedido.
10. Recarga de página durante el checkout y recuperación del carrito/clave idempotente.
15. Comprobar que el navegador muestra el mensaje real de la Edge Function en errores 400, 409, 429 y 500.
16. Cerrar la pestaña después de enviar el pedido, volver a abrir la tienda y repetir exactamente el mismo pedido: debe recuperarse el mismo número, sin descontar inventario otra vez.
17. Reintentar el mismo intento desde otra red/IP: debe crear la reserva para la IP nueva y recuperar/continuar el mismo pedido.
18. Intentar cambiar los datos o la cuenta mientras existe un intento sin resolver: el navegador debe bloquear un segundo checkout.
19. Abrir dos pestañas y enviar el mismo pedido simultáneamente: debe existir un solo pedido y un solo descuento de inventario.
20. Deshabilitar un método de pago entre la carga de la tienda y la confirmación; no debe crearse el pedido con un método deshabilitado.
21. Intentar borrar un método desde una cuenta de administrador; la operación debe estar denegada y el método histórico debe conservarse.
11. Método de pago desactivado entre la carga de la tienda y la confirmación.
12. Pedido inferior al mínimo y cantidades fuera de los límites.
13. Carrito con productos de dos negocios.
14. Verificar que un error en cualquier inserción revierta pedido, detalles y descuento de inventario.

## Estado de implementación

Esta auditoría no ejecutó SQL, no modificó datos de Supabase, no desplegó Edge Functions, no fusionó ramas, no modificó `main` ni publicó GitHub Pages. Las verificaciones fueron de lectura y análisis estático; no equivalen a pruebas de navegador o compras reales.

El archivo de bloqueo de inventario ya fue reconstruido en la rama, pero sigue pendiente de validación de sintaxis en PostgreSQL y de pruebas en un entorno de ensayo. La idempotencia también sigue siendo un borrador: las RPC que necesita no existen todavía en el proyecto activo. El checkout de producción no debe considerarse listo para pruebas completas hasta disponer de un entorno de ensayo, revisar todas las migraciones en conjunto y probar los escenarios de concurrencia.
