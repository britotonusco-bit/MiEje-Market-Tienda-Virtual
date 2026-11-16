# Auditoría de conexión entre paneles y operaciones de pedidos

**Fecha:** 16/11/2026  
**Rama:** `correcciones-funcionales`  
**Alcance:** revisión estática de llamadas desde `panel-live.js` y `app.js`, comparación con firmas SQL candidatas y consulta de existencia de RPC en Supabase Independiente.

## Resultado principal

Se confirmó que la interfaz contiene llamadas para confirmar pagos, solicitar y decidir cancelaciones, registrar reembolsos y crear pedidos públicos. Las firmas y argumentos de las llamadas revisadas coinciden con las funciones SQL candidatas de la rama.

Sin embargo, la consulta de solo lectura al proyecto Supabase independiente no encontró ninguna de estas cinco RPC:
- `mark_order_payment_received`
- `complete_order_refund`
- `request_order_cancellation`
- `decide_order_cancellation`
- `get_business_admin_order_financials`

Por tanto, los controles de pagos, reembolsos, cancelaciones y datos financieros no pueden considerarse operativos en el proyecto activo todavía. La interfaz muestra mensajes de error cuando las funciones no están desplegadas, pero no sustituye la instalación de las migraciones.

## Matriz de llamadas

| Acción de interfaz | Llamada | Resultado estático |
|---|---|---|
| Confirmar pago recibido | `mark_order_payment_received` | Argumentos coinciden con la firma candidata |
| Solicitar cancelación | `request_order_cancellation` | Argumentos coinciden con la firma candidata |
| Aprobar/rechazar cancelación | `decide_order_cancellation` | Argumentos coinciden con la firma candidata |
| Registrar reembolso realizado | `complete_order_refund` | Argumentos coinciden con la firma candidata |
| Consultar finanzas del negocio | `get_business_admin_order_financials` | Argumentos coinciden con la firma candidata |
| Crear pedido público | Edge Function `create-public-order` | Validación, idempotencia y llamada RPC visibles en código |

## Hallazgos y observaciones

### 1. Confirmación de pago

La interfaz solicita confirmación expresa, proveedor, referencia y notas. Para métodos distintos de efectivo exige referencia. Deshabilita el botón antes de invocar la RPC y lo reactiva ante error. El SQL candidato vuelve a validar el rol, estado del pedido e importe y usa bloqueo de fila.

**Pendiente:** comprobar la operación con dos solicitudes simultáneas en staging y verificar que solo quede un ingreso completado.

### 2. Cancelaciones

La interfaz permite registrar una solicitud desde el panel y presentar la decisión al administrador. El SQL candidato restringe la solicitud a miembros activos del negocio y la decisión al administrador. La aprobación devuelve inventario en la misma transacción.

**Observación funcional:** el texto de la interfaz describe el motivo como comunicado por el cliente, pero la acción se inicia desde el panel del negocio. No es una solicitud directa del cliente desde su cuenta. Debe mantenerse claro quién registra la solicitud y quién toma la decisión.

### 3. Reembolsos

La interfaz etiqueta la acción como “Registrar reembolso realizado” y solicita método, proveedor, referencia y notas. Esto coincide con el alcance real de la RPC: registrar una devolución externa ya ejecutada, no enviar dinero.

**Pendiente:** prueba de doble envío, conciliación del importe y revisión del manejo de referencias en la auditoría para no guardar información bancaria innecesaria.

### 4. Checkout público

El cliente deshabilita el botón durante el envío, crea una clave idempotente y conserva el intento cuando el resultado es incierto. La Edge Function valida identificadores, método de pago, productos y cantidades; identifica al cliente autenticado verificando el token con Auth y llama a RPC de consulta/reserva/creación idempotente.

La Edge Function fija `@supabase/supabase-js@2.75.0`. Debe comprobarse que esa versión sigue siendo compatible y que la cabecera `cf-connecting-ip` está presente en el despliegue real; no se puede verificar desde la revisión estática.

### 5. Estados de pedido

El panel presenta transiciones lineales y deshabilita el botón durante la actualización. La autorización final debe permanecer en la base de datos, no depender del botón o del JavaScript. La matriz de pruebas debe incluir transiciones fuera de orden, usuario sin membresía y cambio simultáneo desde dos sesiones.

## Pruebas pendientes obligatorias

1. Confirmación simultánea del mismo pago: un solo movimiento completado.
2. Solicitudes simultáneas de cancelación: una sola solicitud pendiente.
3. Dos aprobaciones simultáneas: una sola restitución por producto.
4. Reembolso simultáneo: un solo reembolso completado.
5. Fallo inducido en cada paso: rollback de todas las escrituras relacionadas.
6. Aislamiento entre negocio A y B para administrador y empleado.
7. Checkout repetido con la misma clave y mismo contenido: devolver el mismo pedido sin duplicar inventario.
8. Checkout con la misma clave y contenido distinto: rechazarlo.
9. Pruebas de cabeceras/IP en el entorno real de Edge Functions.

## Conclusión

**Conexiones estáticas coherentes; operación real no verificada.** El principal bloqueo es que las RPC financieras y de cancelación revisadas no existen todavía en el proyecto Supabase activo. Los SQL siguen siendo borradores en la rama.

No se ejecutó SQL, no se modificó Supabase, no se desplegaron Edge Functions, no se fusionó ningún PR y no se publicó GitHub Pages.
