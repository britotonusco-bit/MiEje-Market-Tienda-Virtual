# Diseño de conservación, archivo y eliminación de datos

**Estado:** propuesta técnica para revisión.  
**Rama:** `correcciones-funcionales`.  
**Producción:** no aplicada. No se ejecutaron cambios en Supabase.

## 1. Objetivo

Evitar que una acción de cierre, archivo o eliminación borre accidentalmente postulaciones, hojas de vida, pedidos, registros financieros o auditoría. La eliminación debe distinguir entre:

- **Despublicar:** deja de mostrarse al público, pero conserva el registro.
- **Archivar:** bloquea nuevas operaciones y conserva el historial.
- **Anonimizar:** elimina o sustituye datos personales que ya no se necesitan, sin destruir registros operativos que deban conservarse.
- **Eliminar:** borra definitivamente el registro y, cuando corresponda, sus archivos de Storage.

No se deben usar estas acciones como sinónimos.

## 2. Hallazgos verificados en la rama y el proyecto

### Vacantes y postulaciones

- El panel del administrador permite crear publicaciones y consultar postulaciones. La lista de publicaciones no presenta actualmente un botón de eliminación o archivo.
- La política RLS existente `business_content_pages_admin_delete` sí permite al administrador activo eliminar publicaciones de su negocio. Por tanto, la ausencia de un botón en la interfaz no impide que una llamada directa autorizada intente borrarlas.
- La tabla `job_applications` referencia la publicación mediante una relación compuesta `(business_id, content_page_id)`. El diseño de la base observado anteriormente usa eliminación en cascada para esa relación. Borrar físicamente una vacante con postulaciones puede borrar también los registros de candidatos.
- Los archivos de hojas de vida viven en el bucket privado `job-applications-private`. Borrar filas SQL no elimina automáticamente los objetos de Storage.
- La función `create-job-application` crea sesiones temporales de carga con vencimiento de 30 minutos. No se encontró un proceso programado de limpieza para sesiones vencidas, límites de solicitudes antiguos ni archivos huérfanos.

### Negocios

- El panel técnico ofrece estados `active`, `suspended` y `closed` mediante `set_technical_business_status`.
- La acción `closed` es un cambio de estado, no una eliminación física.
- No se encontró una acción de eliminación física de negocio en la Edge Function técnica inspeccionada.
- La tabla `businesses` es referenciada por pedidos, productos, membresías, auditoría, publicaciones, postulaciones y registros financieros. Eliminar un negocio como una operación simple no es un procedimiento seguro.

### Postulaciones y hojas de vida

- Las postulaciones incluyen datos de contacto, respuestas, consentimiento, estado y notas internas.
- La tabla actual guarda `privacy_consent` como booleano, pero no se identificaron columnas para la fecha/hora ni la versión del aviso aceptado.
- El panel genera enlaces firmados de descarga con vigencia de 300 segundos. Un enlace ya emitido puede seguir funcionando hasta que venza; revocar el permiso después de emitirlo no necesariamente invalida ese enlace de inmediato.
- La función valida extensión, MIME declarado y tamaño máximo. No realiza inspección real del contenido binario ni análisis antimalware.

## 3. Ciclo de vida recomendado

### 3.1 Vacantes y publicaciones

1. Agregar una acción **Archivar / Despublicar** que establezca `is_published = false`.
2. No permitir eliminación física desde el panel cuando existan postulaciones relacionadas.
3. Para publicaciones con postulaciones, conservar el registro padre y sus postulaciones. La vacante puede quedar archivada y dejar de aceptar candidatos.
4. Si una publicación nunca recibió postulaciones, se podrá evaluar su eliminación física mediante una operación controlada y auditada, después de validar dependencias.
5. La política RLS de DELETE debe retirarse o reemplazarse por un flujo explícito de archivo. No confiar únicamente en ocultar el botón de la interfaz.

**Regla:** una vacante con postulaciones no se elimina físicamente como operación ordinaria.

### 3.2 Postulaciones

1. Mantener cada postulación vinculada a su negocio y vacante original.
2. Registrar cambios de estado y notas internas en una auditoría inmutable o protegida contra modificación por el administrador.
3. No borrar postulaciones al archivar una vacante ni al suspender/cerrar un negocio.
4. Cuando venza el periodo de conservación aprobado, ejecutar un flujo que elimine o anonimice los datos personales según la política aprobada.
5. La anonimización debe preservar, si existe una necesidad legítima, únicamente métricas agregadas que no permitan volver a identificar al candidato.

### 3.3 Hojas de vida (Storage)

La eliminación de objetos debe realizarse mediante la API de Storage, no mediante `DELETE` directo sobre `storage.objects`. Borrar solo la fila de metadatos puede dejar el archivo físico huérfano.

Flujo recomendado:

1. Crear una solicitud de eliminación auditable con identificador único y estado `pending`.
2. Revocar la posibilidad de emitir nuevas descargas y dejar de mostrar el archivo en el panel.
3. Un proceso de servidor con permisos limitados elimina el objeto mediante Storage API.
4. Si Storage confirma que el objeto ya no existe, completar la eliminación/anonymización de los datos asociados y marcar la solicitud como `completed`.
5. Si falla la llamada, conservar la solicitud en estado reintentable, registrar el error sin incluir datos personales y volver a intentarlo de forma idempotente.
6. No marcar la solicitud como completada antes de confirmar el resultado de Storage.

No se debe conceder a los administradores acceso global al bucket ni permitirles borrar archivos de otros negocios.

### 3.4 Sesiones de carga y límites de solicitudes

- Las sesiones vencidas y no consumidas deben limpiarse después de un margen operativo definido.
- Las sesiones consumidas deben conservarse solo el tiempo necesario para prevenir reutilización y resolver incidencias.
- Los registros de rate limit deben eliminarse cuando su ventana ya no sea necesaria para aplicar límites ni investigar abuso.
- La limpieza debe ejecutarse en lotes pequeños, con índices adecuados, límites por ejecución y métricas de resultado.
- Antes de borrar una sesión, comprobar que no representa una postulación válida y completada.

Los plazos exactos no se fijan en este documento: deben definirse con base en el propósito, la operación y la política de privacidad aprobada.

### 3.5 Negocios

1. Usar `suspended` para suspensiones temporales y `closed` para cierre operativo.
2. Al cerrar un negocio, impedir nuevas ventas, publicaciones y postulaciones; conservar pedidos, movimientos de inventario, devoluciones, registros financieros y auditoría.
3. No eliminar físicamente un negocio que tenga historial transaccional.
4. Si se requiere una eliminación definitiva excepcional, primero realizar un análisis de dependencias y retención, exportación autorizada cuando corresponda, borrado de archivos por Storage API y aprobación explícita.
5. La eliminación física no debe estar disponible como acción rutinaria en el panel técnico.

### 3.6 Cuentas de clientes y usuarios de negocio

- Revocar sesiones y accesos antes de tramitar la eliminación de una cuenta.
- Eliminar datos que ya no sean necesarios, como favoritos y preferencias personales.
- Mantener los pedidos y registros financieros que deban conservarse, desvinculando la identidad de la cuenta cuando corresponda.
- No borrar auditoría histórica ni alterar importes, fechas o detalles comerciales para simular una eliminación.
- Las solicitudes de acceso, corrección o eliminación deben tener un flujo verificable y registrar su resultado sin duplicar datos personales innecesarios.

## 4. Arquitectura técnica para eliminaciones coordinadas

La base de datos y Storage no comparten una transacción atómica. Por ello, no se debe intentar resolver el borrado de un archivo y sus filas con una única transacción SQL.

Se propone un patrón de **cola de eliminación (outbox)**:

- Una tabla privada guarda el identificador del trabajo, tipo de recurso, negocio, ruta del objeto, estado, número de intentos, fechas y código de error no sensible.
- Solo funciones de servidor pueden insertar, reclamar o finalizar trabajos.
- El trabajador reclama un lote con bloqueo transaccional, elimina el objeto por Storage API y actualiza el trabajo.
- Los trabajos fallidos quedan disponibles para reintento; los completados son idempotentes.
- Cada solicitud y resultado relevante queda en auditoría.
- La ruta de Storage debe validarse contra la fila original y el negocio antes de ejecutar la operación.

La cola no debe aceptar rutas arbitrarias enviadas por el navegador.

## 5. Decisiones pendientes antes de programar la política

No se deben inventar periodos legales u operativos. El responsable del negocio debe aprobar:

1. Periodo de conservación de postulaciones y hojas de vida después del cierre de una vacante.
2. Periodo de conservación de sesiones de carga consumidas y no consumidas.
3. Periodo de conservación de registros de rate limit y archivos huérfanos.
4. Periodo de conservación de datos de clientes después de solicitar la eliminación de una cuenta.
5. Tratamiento de pedidos, comprobantes, gastos, devoluciones y registros contables al cerrar un negocio.
6. Quién puede aprobar una eliminación definitiva y qué evidencia debe quedar registrada.

Hasta que esas decisiones estén aprobadas, la opción segura es archivar, restringir el acceso y conservar los registros, no eliminarlos automáticamente.

## 6. Pruebas obligatorias antes de producción

- Un administrador solo puede archivar publicaciones de su propio negocio.
- Un administrador no puede eliminar una vacante que tenga postulaciones.
- Archivar una vacante no elimina postulaciones ni hojas de vida.
- Un administrador no puede leer, firmar ni eliminar archivos de otro negocio.
- Cerrar un negocio bloquea nuevas publicaciones y postulaciones sin borrar pedidos ni finanzas.
- Una eliminación de CV fallida no borra la postulación antes de tiempo y puede reintentarse.
- Una solicitud repetida de eliminación no duplica efectos ni genera errores destructivos.
- La limpieza por lotes no elimina sesiones de postulaciones válidas.
- El cierre o la eliminación de una cuenta no altera la integridad de pedidos ni auditoría.
- Toda operación de archivo, anonimización y eliminación registra actor, fecha, motivo y resultado.

## 7. Estado de implementación

Este documento es una propuesta de diseño. En esta revisión:

- No se modificó el esquema de producción.
- No se ejecutaron migraciones.
- No se desplegaron Edge Functions.
- No se borraron postulaciones, sesiones ni archivos.
- No se fijaron plazos de retención sin aprobación.

## 8. Limpieza técnica de sesiones y límites de solicitudes (implementación preparada)

La revisión de solo lectura del proyecto independiente confirmó:

- `job_application_upload_sessions`: 0 filas.
- `job_application_rate_limits`: 0 filas.
- `job_applications`: 0 filas.
- El bucket `job-applications-private` existe y es privado; admite PDF, DOC y DOCX, con límite de 5 MiB.
- No se encontraron funciones de limpieza.
- `pg_cron` y `pg_net` no están instalados en la base consultada; por eso no hay un programador de tareas activo.

### Comportamiento de la función preparada

La Edge Function `cleanup-job-application-data`:

1. Rechaza llamadas que no incluyan el secreto de servicio en el encabezado privado `x-cleanup-secret`.
2. Procesa un lote acotado de sesiones de carga vencidas y no consumidas.
3. Solo acepta rutas con la estructura exacta `business_id/session_id/uuid.ext`, con extensión PDF, DOC o DOCX.
4. Comprueba que no exista una postulación vinculada a esa sesión antes de tocar el archivo.
5. Si el objeto existe, lo elimina mediante Storage API. Si Storage falla, conserva la fila de sesión para un nuevo intento.
6. Elimina la fila temporal solo después de confirmar que el objeto ya no existe o que Storage completó la eliminación.
7. Limpia hasta 500 contadores de rate limit cuya ventana de 15 minutos ya venció. La condición de borrado vuelve a comprobar la fecha para no eliminar un contador que se haya renovado entre lectura y borrado.
8. No borra postulaciones ni hojas de vida asociadas a ellas.

El selector SQL devuelve únicamente rutas válidas. Las sesiones con rutas malformadas no se borran automáticamente y deben revisarse manualmente.

### Sesiones consumidas

El borrador SQL actualiza `submit_public_job_application` para eliminar la fila de sesión temporal dentro de la misma transacción en la que se inserta la postulación. La postulación conserva `resume_path` y el archivo permanece en el bucket privado. Si el registro de la postulación falla, la transacción revierte y la sesión no se pierde.

### Programación pendiente

La función está protegida para no ser invocada desde el navegador. La programación periódica queda pendiente hasta que se aprueben e instalen los componentes necesarios (`pg_cron` y `pg_net`) y se guarden las credenciales de invocación en Vault. No se debe poner la clave de servicio en el código, en GitHub, en el navegador ni en una migración SQL.

No se instaló ninguna extensión ni se creó una tarea programada en producción.
