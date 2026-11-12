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
