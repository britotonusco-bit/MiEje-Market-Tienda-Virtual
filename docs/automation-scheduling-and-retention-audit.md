# Auditoría de automatizaciones, tareas programadas y conservación

**Estado:** revisión estática completada; decisiones operativas y pruebas pendientes.  
**Rama:** `correcciones-funcionales`.  
**Producción:** sin cambios. No se ejecutó SQL, no se desplegaron funciones y no se configuró ningún programador.

## ACC-23 — No existe una ejecución programada demostrada para los procesos de mantenimiento

### Alcance revisado

Se inspeccionaron los archivos de mantenimiento, las Edge Functions, `supabase/config.toml`, los borradores de invitaciones, idempotencia de checkout y auditoría, además de los documentos de conservación y automatización. En el árbol de esta rama no se encontró un workflow de GitHub Actions bajo `.github/workflows/`.

La auditoría previa de solo lectura del proyecto Supabase activo documentó que `pg_cron` no estaba instalado y que no existían `cron.job` ni `cron.job_run_details`. No se ha obtenido evidencia nueva de un scheduler privado externo. Por tanto, no se debe afirmar que estas tareas se ejecutan automáticamente.

### 1. Limpieza de sesiones de postulaciones y CV temporales

La rama contiene:

- `supabase/functions/cleanup-job-application-data/index.ts`.
- `database/maintenance/job-application-cleanup-draft.sql`.
- La RPC `list_expired_job_application_upload_sessions`, limitada a un máximo de 100 sesiones por llamada.
- Una limpieza de hasta 500 filas antiguas de `job_application_rate_limits` por llamada.

Controles positivos observados:

- Método POST y secreto independiente `JOB_APPLICATION_CLEANUP_SECRET`; la función no está pensada para el navegador.
- `SUPABASE_SERVICE_ROLE_KEY` se usa únicamente dentro de la función de servidor.
- Comparación del secreto en tiempo constante.
- La RPC solo selecciona sesiones no consumidas, vencidas y con una ruta que coincide con el patrón esperado de negocio/sesión/UUID/extensión.
- Antes de borrar el archivo se comprueba si existe una postulación con la misma sesión, negocio, vacante y ruta.
- Si la postulación existe, se conserva el CV y solo se elimina la sesión temporal.
- Si no existe postulación, se elimina el objeto mediante Storage API y después se elimina la fila temporal.
- Si Storage falla, la fila de sesión se conserva para permitir otro intento.
- La eliminación de filas de rate limit vuelve a comprobar la antigüedad en el DELETE para no borrar un contador que se haya renovado entre lectura y borrado.
- Las respuestas no incluyen rutas ni datos de candidatos.

Límites y pruebas pendientes:

- No hay programador configurado ni despliegue de esta función.
- Cada invocación procesa un lote acotado; el invocador debe repetirla mientras `hasMoreUploadSessions` o `hasMoreRateLimitRows` sea verdadero, con límites de tiempo y protección contra ejecuciones simultáneas.
- La función no implementa un bloqueo global de ejecución. Si se habilita concurrencia, se debe probar el comportamiento con dos invocaciones simultáneas y confirmar que las operaciones condicionales mantienen la idempotencia.
- La comprobación de archivos por carpeta debe probarse con objetos ausentes, rutas malformadas, múltiples objetos y errores parciales de Storage.
- No hay análisis antimalware del CV. La limpieza no sustituye la cuarentena ni el escaneo antes de permitir que un administrador abra un archivo.
- No se ejecutaron pruebas Deno, Storage ni staging; estos controles son hallazgos de revisión estática, no resultados de ejecución.

### 2. Vencimiento de invitaciones

El borrador `database/security/business-invitations-draft.sql` incluye vencimiento por invitación y una RPC `expire_business_invitation(uuid)` restringida a `service_role`. También actualiza a estado `expired` algunas invitaciones vencidas durante la preparación o aceptación.

No se encontró un procedimiento por lotes ni un scheduler para recorrer periódicamente todas las invitaciones pendientes vencidas. En consecuencia, una invitación puede haber superado `expires_at` sin que su fila cambie inmediatamente a `expired`; la autorización debe seguir rechazándola por la fecha de expiración aunque el estado todavía diga `pending`.

Pendiente: diseñar una RPC de expiración por lotes con límite, bloqueo de filas, auditoría idempotente y reintentos. No se debe crear ni programar hasta probar sus efectos sobre membresías suspendidas, invitaciones revocadas y el índice único de pendientes.

### 3. Idempotencia y reservas del checkout

El borrador `database/orders/checkout-idempotency-draft.sql` crea:

- `private.checkout_idempotency`, con clave, negocio, hash de solicitud, respuesta y `created_at`.
- `private.checkout_rate_limit_reservations`, con fecha de creación e índices por clave/IP y antigüedad.

La RPC de reservas elimina registros antiguos de `checkout_rate_limit_reservations` durante nuevas solicitudes, incluyendo un barrido de más de 24 horas. Es una limpieza oportunista: si no llegan nuevas solicitudes, los registros pueden permanecer.

No se encontró una política de expiración ni una tarea de limpieza para `private.checkout_idempotency`. La tabla conserva respuestas de idempotencia indefinidamente en el diseño actual. No debe agregarse un borrado automático sin definir cuánto tiempo debe poder repetirse una solicitud y recuperar el mismo pedido. Una expiración prematura puede permitir que un reintento tardío cree un segundo pedido.

Decisión requerida: aprobar una ventana de retención de claves idempotentes y diseñar una eliminación por lotes que nunca afecte pedidos ni pagos ya creados. La retención de la clave no equivale a eliminar el pedido.

### 4. Auditoría y registros financieros

El borrador `database/security/audit-log-immutability-draft.sql` agrega protección contra UPDATE, DELETE y TRUNCATE en `audit_logs`, y valida los metadatos de nuevos eventos. Es un borrador, no está aplicado en el proyecto activo. La auditoría anterior observó que el rol `service_role` aún tenía permisos de modificación en la tabla activa.

Los borradores de movimientos de inventario, costes históricos, líneas de pedido y gastos contienen controles de inmutabilidad o transiciones restringidas, pero no se debe asumir que protegen la base activa hasta aplicar y probar el paquete en staging.

No se encontró una política aprobada de retención/archivo para `audit_logs`, pedidos, pagos, reembolsos, movimientos de inventario ni costes históricos. La recomendación conservadora es no borrarlos automáticamente. Si se define una retención, debe distinguir los datos personales que puedan anonimizarse de los registros comerciales/contables que deban conservar integridad y trazabilidad.

### 5. Otras tareas no demostradas

No se encontró un proceso programado confirmado para:

- Expirar invitaciones pendientes en lote.
- Limpiar claves de idempotencia de checkout.
- Reconciliar cuentas Auth creadas sin membresía tras fallos parciales de invitación.
- Ejecutar revisiones periódicas de archivos huérfanos en Storage.
- Archivar o anonimizar postulaciones y datos personales al cumplirse un plazo aprobado.
- Verificar periódicamente la integridad de los ledgers y de los registros de auditoría.

La ausencia de un scheduler en el repositorio no prueba que no exista un servicio externo; solo significa que no está configurado ni documentado en el material revisado. Antes de habilitarlo hay que identificar el proveedor y la configuración real.

## Decisiones necesarias antes de automatizar

1. Elegir el entorno privado que invocará los procesos: Supabase Cron con una extensión disponible y habilitada, o un scheduler externo con identidad/secretos administrados.
2. Aprobar frecuencia y zona horaria para cada tarea. No se fija una frecuencia por defecto en esta auditoría.
3. Guardar los secretos en el almacén seguro del entorno ejecutor; nunca en Git, archivos públicos, JavaScript del navegador ni parámetros de URL.
4. Definir lotes, concurrencia máxima, timeout, reintentos con espera progresiva, límite de intentos y alertas.
5. Registrar únicamente identificadores técnicos y contadores necesarios; no registrar tokens, rutas privadas, CV, nombres, correos ni teléfonos.
6. Definir periodos de conservación de idempotencia, postulaciones, CV, rate limits y auditoría antes de habilitar borrados.
7. Probar primero en staging con objetos válidos, huérfanos, faltantes, rutas inválidas, errores de Storage, dos workers concurrentes y fallos/reintentos.
8. Mantener un modo de simulación/reporte previo a cualquier eliminación permanente y conservar evidencia de cada lote.

## Dictamen

La rama tiene una base técnica para limpiar sesiones de carga y límites de postulaciones, pero no tiene una ejecución programada demostrada. El vencimiento de invitaciones depende de operaciones individuales; las reservas de rate limit se limpian oportunísticamente; las claves de idempotencia no tienen retención definida; y la inmutabilidad de auditoría sigue siendo un borrador no aplicado.

**No configurar cron, workflow, borrados ni retenciones automáticas todavía.** Primero deben aprobarse el entorno, la frecuencia, los secretos y los periodos de conservación, y luego ejecutar pruebas en staging. No se realizaron cambios en Supabase activo.
