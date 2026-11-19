# Auditoría de integridad de clientes, checkout e inventario — MiEje Market

**Fecha:** 16 de noviembre de 2026  
**Rama revisada:** `correcciones-funcionales`  
**Proyecto consultado en modo lectura:** `MiEje Market Independiente` (`cqixlrwbqatbhzmpygiz`)  
**Estado:** borradores corregidos; no se aplicaron migraciones ni se desplegó código.

## 1. Resumen

Se revisaron las migraciones de clientes, favoritos, checkout idempotente, inventario, líneas de pedido e historial financiero, junto con la Edge Function `create-public-order`.

Se encontraron y corrigieron dos asuntos:
1. El borrador de idempotencia repetía la creación de `orders.customer_user_id`, su índice y la tabla `customer_favorites`, aunque el paso 8 ya es su fuente de verdad.
2. La Edge Function usaba `x-forwarded-for` como alternativa a `cf-connecting-ip` para el límite de solicitudes. Un valor de `x-forwarded-for` no verificado puede ser controlado por el cliente en una ruta que no lo normalice. Se eliminó ese fallback; si el proxy de confianza no proporciona `cf-connecting-ip`, el checkout falla de forma cerrada en lugar de confiar en una IP suministrada por el cliente.

## 2. Integridad referencial

### Productos y negocios

La consulta de solo lectura al esquema activo confirmó que `public.products` tiene:
- clave primaria `(id)`;
- restricción única `(business_id, id)`;
- restricción única `(business_id, sku)`.

Por tanto, la clave única compuesta requerida por `inventory_movements_product_business_fk` ya existe en el esquema activo y permite que la FK compuesta del borrador compruebe que el producto pertenece al negocio indicado.

### Líneas de pedido y productos

El paso 9 cambia la FK de `order_items.product_id` a `ON DELETE RESTRICT`. Esto preserva las referencias históricas de productos vendidos y permite restituir existencias en una cancelación. La política esperada es desactivar productos en vez de borrarlos físicamente cuando ya tienen ventas.

### Favoritos

La relación `customer_favorites` tiene:
- `user_id` vinculado a `auth.users(id)` con `ON DELETE CASCADE`;
- `product_id` vinculado a `products(id)` con `ON DELETE CASCADE`;
- unicidad `(user_id, product_id)`, que evita favoritos repetidos.

El borrado de una cuenta elimina sus favoritos, pero no los pedidos: `orders.customer_user_id` usa `ON DELETE SET NULL`. El borrado de un producto limpia su favorito asociado, aunque el paso de inventario impide borrar productos que siguen referenciados por líneas de pedido.

### Pagos e idempotencia

El borrador vincula `orders.payment_method_id` con el método del negocio y conserva `payment_method_name` como texto histórico. La función de creación valida que el método pertenezca al mismo `business_id`, esté habilitado y que su código coincida con el método recibido. La clave de idempotencia se bloquea con advisory lock y el hash de la solicitud impide reutilizar la misma clave con un contenido distinto.

La reserva de límite se realiza antes de la transacción de creación, para que un intento fallido por falta de inventario también cuente. La función final exige la reserva correspondiente y guarda el pedido junto con la respuesta idempotente en la misma transacción.

## 3. Correcciones guardadas en la rama

### 3.1 Fuente única del esquema de clientes

`database/customers/customer-account-migration.sql` es ahora la única migración que crea:
- `orders.customer_user_id`;
- el índice `orders_customer_user_created_idx`;
- `customer_favorites` y su índice.

Se retiraron esas definiciones repetidas de `database/orders/checkout-idempotency-draft.sql`. El paso 12 conserva las políticas de favoritos necesarias para usar `private.business_is_active()`, así como las políticas de lectura de pedidos y líneas para el historial.

### 3.2 IP de origen para el rate limit

`supabase/functions/create-public-order/index.ts` ahora usa únicamente `cf-connecting-ip`, que debe llegar desde el proxy de confianza del servicio. Se eliminó la alternativa `x-forwarded-for`.

**Prueba obligatoria en staging:** confirmar que el runtime de Supabase entrega `cf-connecting-ip` en las solicitudes reales de Edge Function. Si no está presente, el checkout responderá con error de validación de origen y no se deben reactivar cabeceras no confiables como alternativa. Se debe seleccionar una fuente de IP documentada y verificada por la plataforma.

### 3.3 Guía de integración

Se actualizó `database/integration/README.md` para dejar claro que:
- el paso 8 es la única fuente de verdad de la estructura de clientes;
- el paso 12 solo ajusta las políticas y crea la idempotencia;
- los pasos 2 y 11 ya no duplican la normalización de estados ni el trigger.

## 4. Revisión de aislamiento y permisos

- Favoritos: RLS habilitado; SELECT, INSERT y DELETE limitados al propietario mediante `auth.uid()`; no hay UPDATE directo.
- Historial: las RPC comprueban `auth.uid()` y entregan únicamente pedidos del usuario. El helper `private.customer_owns_order` no devuelve datos de otros clientes.
- Personal del negocio: las columnas directas de pedidos y líneas se limitan a los campos operativos; importes y datos financieros se entregan mediante RPC que exigen `business_admin`.
- Checkout: las RPC idempotentes y el rate limit están limitados a `service_role`; la Edge Function valida el token del cliente y deriva `p_customer_user_id` del usuario autenticado, nunca del JSON enviado por el navegador.
- Inventario: los ajustes directos pasan por una RPC que valida `auth.uid()`, negocio activo y rol `business_admin`; el bloqueo de fila y la cantidad esperada evitan sobrescribir un cambio concurrente.

## 5. Estado real del proyecto Supabase consultado

Se consultó el proyecto independiente en modo lectura. El proyecto estaba `ACTIVE_HEALTHY`.

El esquema activo todavía no contiene:
- `orders.customer_user_id`;
- `public.customer_favorites`;
- `public.inventory_movements`;
- `private.checkout_idempotency`.

La lista de migraciones activas tampoco incluye estos borradores. Esto confirma que las correcciones están guardadas en GitHub, pero no instaladas en Supabase. La restricción única `products_business_id_id_unique` sí está presente en el esquema actual.

No se modificaron tablas, políticas, funciones, datos, migraciones ni configuraciones del proyecto.

## 6. Pruebas pendientes en staging

1. Verificar que `cf-connecting-ip` está disponible y no puede ser sustituida por una cabecera enviada por el cliente.
2. Dos clientes no pueden consultar, insertar ni borrar favoritos del otro.
3. La misma pareja usuario/producto no se puede guardar dos veces.
4. Eliminar una cuenta deja intactos los pedidos y elimina solo sus favoritos.
5. No se puede guardar un método de pago que pertenezca a otro negocio o esté deshabilitado.
6. Misma clave idempotente y mismo contenido devuelven el mismo pedido; contenido diferente produce conflicto.
7. Diez intentos en la ventana de diez minutos se aplican de forma consistente ante solicitudes concurrentes desde la misma IP.
8. Dos carritos con productos en orden inverso no provocan deadlock; la última unidad no se vende dos veces.
9. La cancelación aprobada restituye existencias una sola vez y crea el movimiento correspondiente.
10. Los empleados no pueden consultar columnas financieras ni cambiar cantidades o precios de las líneas.

## 7. Dictamen

La integridad referencial del producto y la clave compuesta requerida están respaldadas por el esquema activo. Se eliminó la duplicación del esquema de clientes y se cerró el fallback inseguro de IP en el rate limit.

El paquete sigue siendo un borrador. No está aprobado para producción hasta que se ejecute en un entorno de ensayo separado y se completen las pruebas concurrentes, de permisos y de Edge Function.
