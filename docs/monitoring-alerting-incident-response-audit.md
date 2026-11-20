# Auditoría de monitoreo, alertas y respuesta ante incidentes

**Estado:** revisión estática del código y definición operativa; configuración y pruebas pendientes.  
**Rama:** `correcciones-funcionales`.  
**Producción:** sin cambios. No se desplegaron funciones, no se ejecutó SQL y no se modificaron servicios activos.

## ACC-24 — Manejo de errores existente, pero sin observabilidad operativa demostrada

### Alcance revisado

Se revisaron los puntos de error de:
- `create-public-order`: validación de métodos de pago, perfil de cliente, idempotencia, rate limit y creación del pedido.
- `track-public-order`: consulta y validación del estado del pedido.
- `technical-business-management`: operaciones administrativas, invitaciones, membresías y moderación.
- `create-job-application`: límites de solicitudes, preparación de cargas y envío de postulaciones.
- `cleanup-job-application-data`: limpieza de sesiones y objetos temporales.
- `panel-live.js`: errores visibles de operaciones del panel, pagos, reembolsos, cancelaciones, Storage y acceso.

### Hallazgos

1. Hay registros `console.error` y `console.warn` con nombres de operaciones, pero no se encontró una convención común de identificador de solicitud/correlación que permita unir el error del navegador con el registro de la Edge Function y la operación de base de datos.
2. Las respuestas HTTP suelen devolver mensajes genéricos, lo cual ayuda a no exponer detalles internos, pero no se encontró una referencia de soporte estable que el usuario pueda entregar al equipo técnico.
3. No se encontró evidencia en el repositorio de un proveedor de alertas, reglas de umbral, canal de guardia, tablero operativo ni procedimiento de escalamiento.
4. El código del panel usa alertas del navegador para informar fallos. Esto comunica el error al usuario, pero no constituye monitoreo central ni garantiza que el equipo técnico reciba una notificación.
5. No se puede concluir, solo por la inspección del repositorio, si el proyecto Supabase activo tiene alertas o integraciones configuradas en el Dashboard. Esa configuración debe revisarse por separado antes de afirmar que no existe.
6. No se han ejecutado pruebas de fallos, consultas de logs recientes, pruebas de carga ni ejercicios de recuperación. Los hallazgos son estáticos.

## 1. Señales que deben monitorearse

| Servicio | Señales operativas | Impacto que debe detectarse |
|---|---|---|
| Pedidos / checkout | Tasa de respuestas 5xx, fallos de RPC, errores de idempotencia, limitación excesiva, diferencia entre solicitudes recibidas y pedidos confirmados | Clientes que no pueden comprar o riesgo de pedidos duplicados |
| Pagos y reembolsos | Fallos de confirmación, referencias duplicadas, operaciones rechazadas, discrepancias entre pedido y movimiento financiero | Estado de pago incorrecto o conciliación incompleta |
| Autenticación | Fallos de inicio de sesión, errores de renovación, MFA, invitaciones y recuperación; aumento de accesos revocados que siguen intentando operar | Usuarios legítimos bloqueados o acceso no autorizado |
| Storage | Fallos de carga/descarga, enlaces firmados, errores de permisos, objetos huérfanos y límites de tamaño | Imágenes o documentos no disponibles, exposición o pérdida de archivos |
| Edge Functions | Latencia, respuestas 4xx/5xx, excepciones, timeouts, reinicios y fallos de configuración | Interrupción de funciones públicas o administrativas |
| Base de datos | Conexiones, latencia, errores de consultas/RPC, bloqueos, saturación y errores de permisos/RLS | Operaciones lentas, bloqueadas o rechazadas |
| Auditoría e inventario | Fallos de escritura, secuencias incompletas, diferencias de conciliación y errores de integridad | Pérdida de trazabilidad o inconsistencias comerciales |

No se fijan porcentajes ni umbrales arbitrarios en esta auditoría. Los umbrales deben salir de una línea base medida en staging y de objetivos de disponibilidad y tiempos de respuesta aprobados.

## 2. Requisitos mínimos de instrumentación

Antes de habilitar alertas:

- Generar un `request_id` aleatorio por solicitud en el servidor y devolverlo como referencia de soporte, sin devolver trazas ni mensajes internos.
- Propagar ese identificador entre el panel, la Edge Function y las operaciones relacionadas cuando sea posible.
- Registrar nombre de función, acción, resultado, duración, código HTTP, código de error estable y entorno.
- Registrar identificadores internos solo cuando sean necesarios para investigar y estén protegidos; evitar datos personales.
- No registrar contraseñas, JWT, refresh tokens, OTP, claves API, secretos, tokens de carga, enlaces firmados, CV, comprobantes, direcciones, teléfonos, correos ni cuerpos completos de pedidos.
- No usar el identificador del negocio o del cliente como etiqueta de alta cardinalidad en métricas públicas.
- Separar errores esperados de validación (4xx) de fallos operativos (5xx); no alertar por cada rechazo normal de usuario.
- Definir retención, permisos de lectura y acceso de emergencia a los registros.

El `request_id` debe ser una referencia de diagnóstico, no una credencial ni un mecanismo de autorización.

## 3. Reglas de alertas propuestas

Las reglas deben configurarse solo después de identificar el proveedor y confirmar qué métricas y logs ofrece el plan activo.

### Prioridad crítica — P1
- Checkout o creación de pedidos presenta fallos generalizados.
- Se detectan pedidos duplicados o discrepancias financieras confirmadas.
- Hay indicios de acceso entre negocios, exposición de CV/comprobantes o filtración de secretos.
- La autenticación administrativa o la autorización de paneles deja de aplicar correctamente.

**Respuesta:** activar al responsable técnico inmediatamente, preservar registros, contener el componente afectado y evitar reintentos que puedan duplicar operaciones.

### Prioridad alta — P2
- Una Edge Function crítica presenta fallos repetidos o latencia anormal.
- Confirmación de pagos, reembolsos, Storage o invitaciones se degrada para un conjunto de usuarios.
- La base de datos presenta saturación, bloqueos o errores de permisos.

**Respuesta:** investigar dentro del turno de atención definido, comunicar la afectación y aplicar recuperación controlada.

### Prioridad informativa — P3
- Fallos aislados de validación, solicitudes mal formadas, rate limits normales o errores recuperables de un usuario.
- Limpiezas que no completan un lote, siempre que no exista riesgo de eliminación incorrecta.

**Respuesta:** registrar tendencia y revisar; no generar una alerta crítica por cada evento.

La frecuencia de notificación, escalamiento y tiempos máximos de atención siguen pendientes de aprobación.

## 4. Procedimiento común de respuesta

1. **Detectar y clasificar:** registrar hora UTC, entorno, servicio, alcance y prioridad.
2. **Confirmar:** comprobar si el evento es reproducible y si afecta a un negocio o a varios. No usar datos reales de clientes en pruebas.
3. **Contener:** deshabilitar temporalmente solo la operación afectada si existe riesgo de duplicación, exposición o corrupción. No suspender toda la plataforma por un error aislado.
4. **Preservar evidencia:** conservar logs y referencias técnicas; no borrar pedidos, pagos, archivos ni auditorías para ocultar el síntoma.
5. **Diagnosticar:** correlacionar request_id, función, código HTTP, RPC y momento del evento. Revisar primero cambios recientes y dependencias.
6. **Recuperar:** aplicar una corrección revisada en staging y luego un despliegue autorizado. Evitar reintentos ciegos en operaciones financieras o no idempotentes.
7. **Verificar:** ejecutar pruebas de lectura y escritura controladas, confirmar aislamiento entre negocios y conciliar el estado final.
8. **Cerrar:** documentar causa raíz, alcance, duración, datos afectados, acciones y prevención. Si hubo datos personales comprometidos, activar el procedimiento legal y de privacidad aplicable.

## 5. Guías específicas por servicio

### Pedidos y checkout
- Consultar el pedido por su referencia/idempotency key y verificar si ya existe antes de reintentar.
- Revisar la respuesta de `create-public-order`, los errores de RPC y la transacción de inventario.
- No crear manualmente un segundo pedido para “reemplazar” uno cuyo resultado sea incierto.
- Conciliar pedido, líneas, inventario y pago antes de dar el incidente por resuelto.

### Pagos y reembolsos
- No repetir confirmaciones ni reembolsos sin comprobar el registro financiero y la referencia de la pasarela/medio de pago.
- Separar el estado del pedido del movimiento financiero; no cambiar ambos manualmente sin procedimiento transaccional.
- Si existe discrepancia, bloquear temporalmente la acción financiera afectada y escalar al administrador autorizado.

### Autenticación y paneles
- Comprobar disponibilidad de Auth, estado de sesión, MFA, perfil y membresía.
- No compartir tokens ni pedir contraseñas por soporte.
- No eliminar usuarios de Auth como solución rápida: puede dejar sesiones o membresías en estados inconsistentes.
- Si hay sospecha de cuenta comprometida, preservar evidencia y aplicar un procedimiento de revocación validado, sin improvisar cambios en membresías.

### Storage
- Distinguir bucket público de buckets privados.
- Para CV y comprobantes, revisar ruta, negocio, asociación con el registro y permisos antes de emitir una nueva URL firmada.
- No convertir un bucket privado en público para resolver una descarga fallida.
- No borrar objetos huérfanos durante el incidente hasta verificar referencias y periodo de espera.

### Edge Functions y base de datos
- Revisar logs por función, hora y request_id; comprobar variables de entorno sin imprimir sus valores.
- Ante timeout, determinar si la transacción llegó a confirmarse antes de repetir la solicitud.
- No aplicar SQL correctivo directamente en producción como primera respuesta.
- Toda corrección de esquema o permisos debe pasar por revisión, staging y aprobación.

## 6. Recuperación y continuidad

Antes de declarar que la plataforma puede recuperarse, debe existir evidencia de:

- Copias de seguridad de base de datos y configuración de recuperación del proveedor.
- Política de recuperación de objetos Storage; una copia de la base no demuestra que los archivos estén respaldados.
- Inventario de secretos y procedimiento de rotación sin incluir valores secretos en documentación.
- Versiones desplegadas de Edge Functions y procedimiento de rollback.
- Migraciones SQL versionadas y orden de aplicación.
- Pruebas periódicas de restauración en un proyecto aislado.
- Conciliación posterior de pedidos, pagos, reembolsos e inventario.

**RPO** (cantidad máxima de datos que se acepta perder) y **RTO** (tiempo máximo para recuperar el servicio) no están definidos. No se deben inventar ni prometer hasta revisar el plan contratado, las copias disponibles y una prueba real de restauración.

## 7. Pruebas necesarias en staging

- Simular un error controlado de checkout y confirmar que genera una referencia de soporte sin duplicar pedidos.
- Simular fallo de RPC, timeout y respuesta 5xx; verificar que la alerta se dispara una sola vez por ventana y que el registro no contiene PII.
- Probar Auth con sesión vencida, MFA incorrecto y membresía suspendida.
- Probar Storage con archivo inexistente, URL firmada vencida y usuario de otro negocio.
- Probar que una alerta de negocio A no expone información de negocio B.
- Simular fallo de limpieza y comprobar que el reintento no elimina CV asociado.
- Restaurar una copia en un proyecto aislado y verificar base de datos, archivos y consistencia comercial.
- Documentar resultado esperado, resultado real, evidencia sanitizada y responsable.

## 8. Decisiones pendientes

1. Confirmar el proveedor de monitoreo/alertas y si se usarán primero las herramientas disponibles en Supabase.
2. Definir quién recibe alertas P1/P2, canal de contacto y horario de atención.
3. Aprobar umbrales a partir de métricas reales.
4. Definir RPO, RTO y retención de logs.
5. Identificar el estado real de backups de Storage y probar restauración.
6. Aprobar si se incorporará instrumentación `request_id` en las Edge Functions y en el panel.

## Dictamen

La aplicación ya comunica y registra ciertos errores, pero todavía no existe evidencia suficiente para considerar implementado un sistema completo de monitoreo, alertas y respuesta ante incidentes. Este documento establece el alcance y los controles necesarios sin introducir servicios, secretos, tareas programadas ni cambios de producción.

**No se configuraron alertas ni integraciones, no se modificó Supabase activo y no se ejecutaron pruebas de incidente o restauración.**
