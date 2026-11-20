# Matriz de pruebas integrales — ACC-27

**Rama:** `correcciones-funcionales`  
**Fecha de preparación:** 20 de noviembre de 2026  
**Estado:** matriz preparada; ejecución pendiente.  
**Entorno autorizado para ejecución:** exclusivamente un proyecto Supabase de staging aislado.  
**Producción:** no se modificó. No se crearon usuarios, no se aplicaron migraciones, no se desplegaron funciones y no se ejecutaron transacciones.

## 1. Propósito y criterio de aprobación

Esta matriz verifica el comportamiento integrado de la tienda pública, autenticación, los tres paneles, Edge Functions, PostgreSQL/RLS y Storage.

Una prueba solo se marca como aprobada cuando:
1. Se ejecuta en el staging identificado y se registra el commit y la versión de esquema.
2. Se comprueba el resultado esperado mediante la interfaz y una consulta de verificación de solo lectura.
3. Se confirma el resultado negativo desde una identidad que no debe tener acceso.
4. Se guarda evidencia sin nombres, correos, teléfonos, tokens, direcciones, CV ni secretos.

No se permite usar pagos reales, datos personales reales ni el proyecto de producción.

## 2. Bloqueadores antes de ejecutar

Los siguientes puntos siguen pendientes y bloquean la ejecución real:

- Identificar o crear un proyecto staging independiente, con proyecto/URL/keys inequívocos y sin compartir DB, Auth, Storage ni secretos con producción.
- Confirmar que el proyecto staging tiene el esquema y las Edge Functions del commit que se va a probar.
- Aplicar migraciones y desplegar funciones únicamente en staging, después de revisar el diff y obtener autorización para esa tarea.
- Configurar redirects y plantillas Auth para el dominio de staging.
- Preparar buzones/cuentas de prueba controladas y usuarios de los roles requeridos.
- Confirmar que no hay claves `service_role` en frontend ni en archivos versionados.
- Verificar las políticas RLS, grants y exposición Data API del staging antes de cargar datos sintéticos.

El runbook `docs/staging-auth-security-test-runbook.md` contiene la preparación de Auth, MFA, sesiones, invitaciones y aislamiento. Esta matriz lo complementa; no lo sustituye.

## 3. Datos sintéticos

Crear exclusivamente en staging:

### Negocios
- **NEGOCIO-A:** identificador sintético A.
- **NEGOCIO-B:** identificador sintético B.

### Usuarios de prueba
- **OWNER:** propietario técnico con MFA habilitado y AAL2.
- **ADMIN-A:** administrador activo del NEGOCIO-A.
- **EMP-A:** empleado activo del NEGOCIO-A.
- **ADMIN-B:** administrador activo del NEGOCIO-B.
- **EMP-SUSP:** empleado suspendido del NEGOCIO-A.
- **NO-MEMBER:** usuario autenticado sin membresía de negocio.
- **BLOCKED:** perfil de prueba bloqueado.
- **CUSTOMER-A:** cliente de prueba para pedidos en NEGOCIO-A.
- **CUSTOMER-B:** cliente de prueba para pedidos en NEGOCIO-B.
- **INVITE-PENDING:** usuario/correo de prueba para aceptación y vencimiento de invitación.

Las identidades deben usar buzones de prueba bajo control del equipo y no corresponder a clientes reales. Las credenciales no se incluyen en el repositorio ni en evidencias.

### Catálogo y operaciones
- Producto A1, NEGOCIO-A, precio 10.000 COP, inventario inicial 10 unidades, coste sintético 4.000 COP.
- Producto B1, NEGOCIO-B, precio 20.000 COP, inventario inicial 8 unidades, coste sintético 9.000 COP.
- Un producto A2 con coste no registrado para comprobar el tratamiento de ganancias incompletas.
- Un pedido sintético con domicilio gratuito y otro con tarifa de domicilio configurada.
- Una vacante y un CV de prueba no personal, únicamente para verificar Storage privado.

No reutilizar estos importes como precios de producción; son valores de prueba arbitrarios.

## 4. Casos de prueba

### A. Acceso y separación de roles

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| AUTH-01 | CUSTOMER-A | Registrarse e iniciar sesión | Se crea una cuenta de cliente; no se crea membresía de negocio. |
| AUTH-02 | ADMIN-A | Iniciar sesión | Acceso solo al panel y negocio A. |
| AUTH-03 | EMP-A | Iniciar sesión | Acceso solo a funciones operativas autorizadas de A. |
| AUTH-04 | EMP-SUSP | Intentar entrar al panel | Acceso denegado; no puede leer ni mutar datos del negocio. |
| AUTH-05 | BLOCKED | Iniciar sesión/llamar función privada | Acceso denegado por perfil bloqueado. |
| AUTH-06 | NO-MEMBER | Abrir panel de negocio | Sin autorización y sin datos comerciales. |
| AUTH-07 | OWNER | Abrir panel técnico con AAL1 | Acción técnica sensible rechazada hasta AAL2. |
| AUTH-08 | OWNER | Abrir panel técnico con AAL2 | Acceso técnico permitido, limitado a funciones de plataforma. |
| AUTH-09 | ADMIN-A | Solicitar recurso de B cambiando IDs | Cero acceso; no debe revelar si el recurso existe. |
| AUTH-10 | ADMIN-B | Solicitar recurso de A | Cero acceso. |

### B. Configuración comercial y catálogo

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| CAT-01 | ADMIN-A | Crear producto A2 | Se crea asociado a A. |
| CAT-02 | ADMIN-A | Editar nombre, precio, descripción y stock de A2 | Cambios guardados y validados. |
| CAT-03 | ADMIN-A | Enviar business_id de B al editar A2 | Rechazo; no cambia producto ni negocio B. |
| CAT-04 | EMP-A | Intentar cambiar precio o configuración comercial | Rechazo si el permiso no está concedido al empleado. |
| CAT-05 | ADMIN-B | Consultar catálogo | Solo productos de B. |
| CAT-06 | Cliente | Abrir tienda pública | Solo se muestran negocios/productos activos y publicados. |

### C. Checkout y pedidos

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| ORD-01 | CUSTOMER-A | Comprar 2 unidades de A1 | Pedido A con líneas, subtotal, domicilio y total coherentes. |
| ORD-02 | CUSTOMER-B | Comprar B1 | Pedido asociado solo a B. |
| ORD-03 | CUSTOMER-A | Solicitar cantidad superior al stock | Rechazo sin pedido parcial ni stock negativo. |
| ORD-04 | CUSTOMER-A | Repetir misma clave idempotente y mismo payload | Se devuelve el mismo resultado; no se duplica pedido ni descuento. |
| ORD-05 | CUSTOMER-A | Reutilizar clave idempotente con payload distinto | Rechazo por conflicto; no crea segundo pedido. |
| ORD-06 | CUSTOMER-A | Enviar consentimiento ausente o versión incorrecta | Checkout rechazado; no crea pedido. |
| ORD-07 | CUSTOMER-A | Enviar business_id de B con producto A | Rechazo; no crea pedido cruzado. |
| ORD-08 | Cliente no autenticado | Crear pedido si el flujo exige cuenta | Rechazo sin crear pedido. |
| ORD-09 | ADMIN-A | Ver pedidos | Solo pedidos de A. |
| ORD-10 | EMP-A | Ver pedido operativo | Ve datos necesarios para preparar/entregar, no datos financieros restringidos. |

### D. Estados, cancelaciones e inventario

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| FLOW-01 | EMP-A | Avanzar pedido por estados permitidos | Solo transiciones válidas; negocio A. |
| FLOW-02 | EMP-A | Saltar estado o modificar pedido cancelado | Rechazo. |
| INV-01 | Checkout | Completar pedido con stock disponible | Descuento exacto una sola vez. |
| INV-02 | Dos clientes simultáneos | Comprar las últimas unidades | No sobreventa; una operación puede rechazarse por stock. |
| INV-03 | EMP-A | Solicitar cancelación | Se registra solicitud, no reembolso automático. |
| INV-04 | ADMIN-A | Aprobar cancelación | Reposición exacta una sola vez y estado cancelado. |
| INV-05 | ADMIN-A | Repetir decisión de cancelación | Sin segunda reposición. |
| INV-06 | ADMIN-A | Ajustar stock con valor esperado obsoleto | Conflicto; no sobrescribe ajuste concurrente. |
| INV-07 | EMP-A | Ajustar inventario directamente | Rechazo si no tiene permiso. |
| INV-08 | Auditoría | Consultar ledger | Cada movimiento corresponde a negocio/producto/pedido válidos; no hay huérfanos. |

### E. Pagos y reembolsos

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| PAY-01 | ADMIN-A | Confirmar pago pendiente válido | Un único movimiento financiero completado por importe y moneda del pedido. |
| PAY-02 | EMP-A | Confirmar pago | Rechazo. |
| PAY-03 | ADMIN-A | Confirmar pago dos veces | No duplica movimiento ni ingreso. |
| PAY-04 | ADMIN-A | Confirmar pago de pedido cancelado | Rechazo. |
| PAY-05 | ADMIN-A | Reembolsar pedido cancelado y pagado | Un reembolso vinculado al pago y al pedido correctos. |
| PAY-06 | ADMIN-A | Reembolsar dos veces | Segundo intento rechazado; sin duplicado. |
| PAY-07 | ADMIN-A | Reembolsar importe superior al pago | Rechazo. |
| PAY-08 | ADMIN-A | Reembolsar pedido no cancelado o no pagado | Rechazo. |
| PAY-09 | ADMIN-A | Usar ID de transacción de B | Rechazo sin filtrar datos de B. |
| PAY-10 | Cliente | Consultar historial | Solo sus pedidos; sin información de otros clientes. |

### F. Costes, gastos e informes

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| FIN-01 | ADMIN-A | Registrar coste de A1 | Coste asociado al producto y negocio A. |
| FIN-02 | ADMIN-A | Cambiar coste vigente de A1 tras pedido | Snapshot histórico del pedido no cambia. |
| FIN-03 | ADMIN-A | Consultar ganancias con coste faltante A2 | Ganancia marcada incompleta/no calculable, no como cero. |
| FIN-04 | ADMIN-A | Registrar gasto pendiente y marcar pagado | Estado, fecha y medio de pago coherentes. |
| FIN-05 | ADMIN-A | Anular gasto | Motivo y actor registrados; no se borra historial. |
| FIN-06 | ADMIN-A | Consultar informe | Solo A; ingresos, reembolsos, costes y gastos separados. |
| FIN-07 | ADMIN-B | Consultar informe | Solo B. |
| FIN-08 | EMP-A | Consultar datos financieros | Rechazo o vista limitada según permisos definidos. |

### G. Storage, vacantes y privacidad

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| STO-01 | ADMIN-A | Cargar imagen comercial permitida | Archivo asociado a A y con MIME/tamaño permitido. |
| STO-02 | ADMIN-A | Intentar cargar en ruta de B | Rechazo. |
| STO-03 | EMP-A | Descargar CV de postulante | Rechazo. |
| STO-04 | ADMIN-A | Descargar CV de vacante de A | URL firmada breve y acceso correcto. |
| STO-05 | ADMIN-B | Solicitar CV de A | Rechazo. |
| STO-06 | Anónimo | Consultar bucket privado de CV | Sin acceso. |
| STO-07 | Solicitante | Enviar postulación sin consentimiento válido | Rechazo; no persiste postulación ni objeto final. |
| STO-08 | Limpieza | Ejecutar limpieza en staging con datos de prueba | Solo elimina temporales vencidos y huérfanos; conserva CV vinculados a postulaciones. |

### H. Invitaciones, sesiones y auditoría

| ID | Actor | Acción | Resultado esperado |
|---|---|---|---|
| INVITE-01 | OWNER | Invitar ADMIN-A | Invitación pendiente, token no almacenado en claro. |
| INVITE-02 | Usuario invitado | Aceptar invitación válida | Membership activa solo tras completar pasos de verificación. |
| INVITE-03 | Usuario invitado | Aceptar invitación vencida/revocada | Rechazo. |
| INVITE-04 | Usuario existente no confirmado | Reenviar confirmación | Se reutiliza el usuario existente; no se duplica identidad. |
| INVITE-05 | OWNER | Revocar invitación | No puede aceptarse después de revocada. |
| SESS-01 | Usuario | Cerrar sesión y volver a abrir panel | No conserva acceso privado. |
| SESS-02 | Admin | Suspender membresía mientras otra sesión está abierta | Panel revalida y pierde acceso conforme a las garantías documentadas. |
| AUD-01 | Cada flujo crítico | Generar evento de auditoría | Evento con actor, acción, recurso, negocio y fecha; sin tokens ni PII innecesaria. |
| AUD-02 | Usuario no autorizado | Modificar o borrar evento de auditoría | Rechazo. |

## 5. Pruebas de integridad al cierre

Ejecutar los verificadores de solo lectura y guardar resultados:

- Subtotal de cada pedido = suma de líneas.
- Total = subtotal + tarifa de domicilio (si no hay otros componentes aprobados).
- Cada línea = cantidad × precio unitario.
- Pagos completados = un movimiento único por operación válida.
- Reembolsos no superan pagos y no están duplicados.
- Movimientos de inventario cuadran con stock final.
- Cancelación repone exactamente lo descontado y no más de una vez.
- Costes históricos no cambian cuando cambia el coste vigente.
- Informes y consultas no cruzan business_id.
- No hay referencias huérfanas, relaciones entre negocios ni acceso de roles incorrectos.

Si el ledger `inventory_movements` no está desplegado en staging, los casos INV-08 y la conciliación de movimientos quedan bloqueados; no se deben marcar aprobados usando únicamente `products.inventory`.

## 6. Registro de ejecución

Por cada caso registrar:

| Campo | Valor |
|---|---|
| ID de prueba | |
| Fecha/hora UTC | |
| Proyecto staging / referencia | |
| Commit exacto | |
| Versión de esquema | |
| Actor sintético | |
| Resultado esperado | |
| Resultado observado | |
| Estado | Pendiente / Aprobado / Fallido / Bloqueado |
| Evidencia sanitizada | |
| Incidencia vinculada | |

No adjuntar secretos, tokens, datos de contacto, CV reales ni capturas con información personal.

## 7. Severidad y cierre

- **P0 — Bloqueante:** acceso entre negocios, exposición de datos personales/financieros, duplicación de pagos/reembolsos, pérdida o corrupción de pedidos.
- **P1 — Alta:** checkout incorrecto, inventario inconsistente, cancelación/reembolso defectuoso, invitaciones o bloqueo que no respeten permisos.
- **P2 — Media:** errores de informes, estados secundarios, notificaciones o procesos de mantenimiento sin impacto de seguridad/integridad inmediato.
- **P3 — Baja:** problemas cosméticos o de usabilidad que no alteran datos ni autorizaciones.

Criterio para cerrar ACC-27:
- Todos los casos P0/P1 aprobados.
- Ningún caso de aislamiento de negocio fallido.
- Conciliación de pedidos, pagos, reembolsos e inventario sin diferencias.
- Los fallos P2/P3 documentados y priorizados.
- Evidencias sanitizadas y reproducibles adjuntas al registro de pruebas.

## Dictamen actual

**ACC-27 está preparado documentalmente, pero no ejecutado.** En la revisión disponible no se identificó un proyecto de staging listo con migraciones, funciones y cuentas de prueba instaladas. No se debe interpretar esta matriz como una prueba aprobada ni como certificación funcional.

No se realizaron cambios en Supabase activo, no se aplicó SQL, no se desplegaron Edge Functions y no se crearon usuarios ni datos de prueba.
