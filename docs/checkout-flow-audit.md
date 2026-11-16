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

La base de datos inspeccionada no contiene las funciones `get_public_order_idempotent`, `reserve_checkout_rate_limit` ni `create_public_order_idempotent`. La función Edge activa `create-public-order` está desplegada en versión 3, mientras que la rama contiene una fuente más reciente que depende de esas RPC. Por tanto, el flujo idempotente de la rama no está implementado en el proyecto activo.

El borrador `database/orders/checkout-idempotency-draft.sql` propone una clave única por intento, un hash del contenido, una reserva de límite por IP y bloqueo transaccional para que dos solicitudes simultáneas con la misma clave no creen dos pedidos. Debe revisarse junto con la Edge Function antes de aplicarlo.

### 2. Carrera entre suspensión del negocio y checkout

La función SQL activa lee el negocio con estado `active`, pero no bloquea su fila durante la transacción. Si un administrador suspende el negocio justo después de esa lectura, el pedido podría continuar mientras la suspensión se procesa.

La función propuesta en `database/inventory/checkout-inventory-lock-order-draft.sql` debe obtener el registro del negocio activo con `FOR SHARE` antes de procesar productos. Así, la suspensión y el checkout quedan serializados: o el pedido termina primero, o la función detecta que el negocio ya no está activo.

### 3. El borrador de bloqueo de inventario está dañado y no se puede ejecutar

La revisión estática encontró un bloque incompleto de validación de UUID/cantidades, una expresión regular sin cerrar y fragmentos duplicados después del primer `COMMIT`. El archivo también repite partes de la función de checkout y del trigger de estados.

**Bloqueo:** no ejecutar `database/inventory/checkout-inventory-lock-order-draft.sql` en Supabase hasta reconstruirlo, revisar el SQL completo y validar su sintaxis en un entorno de ensayo.

La corrección debe validar todos los UUID y cantidades antes de convertirlos, rechazar IDs de producto duplicados incluso si cambian las mayúsculas, bloquear el negocio activo con `FOR SHARE` y bloquear los productos en orden UUID ascendente.

### 4. Carrito con datos desactualizados

El navegador conserva en memoria los precios y existencias que recibió al cargar el catálogo. El servidor vuelve a comprobarlos al crear el pedido, lo cual evita aceptar precios o inventario antiguos. Sin embargo, cuando el servidor rechaza un pedido por cambio de precio, producto inactivo o falta de stock, el navegador no actualiza automáticamente el catálogo y el carrito para mostrar la situación nueva.

Antes de implementar se debe añadir una recuperación clara: informar el motivo, volver a consultar el negocio y sus productos, señalar qué líneas cambiaron y permitir que el cliente revise el nuevo total antes de volver a confirmar.

### 5. Reintentos después de perder la respuesta

El navegador guarda temporalmente la clave de idempotencia en `sessionStorage` y la reutiliza cuando el mismo contenido se vuelve a enviar en la misma sesión. Esto ayuda si el servidor creó el pedido, pero la respuesta no llegó al navegador.

El carrito como tal permanece solo en memoria. Debe probarse el caso de recarga/cierre de página durante el checkout y decidir si se guarda una copia temporal del carrito y de los datos no sensibles necesarios para reconstruir el mismo intento. No guardar datos de pago sensibles.

### 6. Reglas del carrito y del método de pago

- El carrito admite productos de un solo negocio a la vez; al elegir otro negocio, pide confirmación para vaciarlo.
- Los productos de demostración y los negocios suspendidos no pueden iniciar una compra.
- El checkout toma el identificador del método de pago del negocio.
- La Edge Function valida que el método pertenezca al negocio. La función SQL propuesta vuelve a comprobar que siga habilitado y guarda el nombre como histórico.
- El navegador no envía el precio como autoridad; la función SQL calcula el precio real.
- El método de entrega se registra actualmente en las notas del pedido. Debe verificarse que las opciones que se muestran correspondan a las opciones reales configuradas por cada negocio.

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
10. Recarga de página durante el checkout.
11. Método de pago desactivado entre la carga de la tienda y la confirmación.
12. Pedido inferior al mínimo y cantidades fuera de los límites.
13. Carrito con productos de dos negocios.
14. Verificar que un error en cualquier inserción revierta pedido, detalles y descuento de inventario.

## Estado de implementación

Esta auditoría no ejecutó SQL, no modificó datos de Supabase, no desplegó Edge Functions, no fusionó ramas, no modificó `main` ni publicó GitHub Pages. Las verificaciones fueron de lectura y análisis estático; no equivalen a pruebas de navegador o compras reales.

La migración de inventario mencionada está bloqueada por errores de sintaxis y duplicación. La idempotencia sigue siendo un borrador. El checkout de producción no debe considerarse listo para pruebas completas hasta disponer de un entorno de ensayo y corregir esos puntos.
