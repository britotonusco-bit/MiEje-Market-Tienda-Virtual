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
