# Auditoría de Storage: imágenes, hojas de vida y comprobantes

**Proyecto:** MiEje Market Independiente  
**Rama revisada:** `correcciones-funcionales`  
**Fecha:** 16 de noviembre de 2026  
**Alcance:** buckets, políticas RLS de `storage.objects`, rutas de archivos, cargas desde navegador/Edge Function y enlaces de descarga.  
**Método:** consultas SQL de solo lectura, revisión del código y comparación con la documentación vigente de Supabase. No se subieron, borraron ni modificaron objetos o políticas activas.

## 1. Resumen ejecutivo

Se identificaron dos bloqueos funcionales importantes y una brecha de seguridad en las políticas activas:

1. Las políticas activas del bucket `business-assets` comparan el UUID del negocio con una ruta construida desde `b.name`, que es el nombre del negocio y no el nombre del objeto. La condición correcta debe obtener el UUID desde `storage.objects.name`. Con los nombres actuales de negocio, las operaciones autenticadas de carga, listado/lectura de metadatos, reemplazo y eliminación pueden fallar.
2. El bucket `business-expense-receipts` no existe en Storage activo, aunque el panel ya intenta subir comprobantes y crear enlaces firmados desde ese bucket. El módulo de comprobantes no puede operar en el proyecto activo hasta aplicar el borrador de creación del bucket y sus políticas.
3. La política activa de lectura de hojas de vida privadas está limitada por negocio activo y rol de administrador, pero necesita pruebas de aislamiento A/B y de vinculación exacta entre ruta, postulación y negocio antes de considerarla aprobada.

El bucket `business-assets` es público por diseño: cualquiera que conozca la URL puede descargar las imágenes. La RLS sigue controlando quién puede subir, actualizar o borrar objetos, pero no hace privadas las descargas de un bucket público. No se deben guardar documentos, comprobantes ni información personal en ese bucket.

## 2. Estado real observado en Supabase

### Buckets encontrados

| Bucket | Existe | Público | Límite | Tipos permitidos | Objetos observados |
|---|---:|---:|---:|---|---:|
| `business-assets` | Sí | Sí | 5 MB | PNG, JPEG, WEBP | 0 |
| `job-applications-private` | Sí | No | 5 MB | PDF, DOC, DOCX | 0 |
| `business-expense-receipts` | No | — | — | — | — |

La consulta no encontró objetos en los dos buckets existentes. Por ello no fue posible validar archivos reales, URLs públicas, reemplazos ni descargas firmadas con datos de prueba.

## 3. Hallazgos por bucket

### 3.1 `business-assets` — logos e imágenes de productos

**Uso en el código**
- `panel-live.js` carga imágenes bajo `<business_uuid>/logo/<uuid>.<ext>` o `<business_uuid>/products/<uuid>.<ext>`.
- La carga se realiza con `upsert: false`, límite de 5 MB y MIME declarado PNG/JPEG/WEBP.
- Las imágenes se publican mediante `getPublicUrl`.
- Al reemplazar una imagen, el panel intenta borrar la anterior.

**Hallazgo crítico: ruta mal referenciada en las políticas activas**

Las cuatro políticas activas `business_assets_admin_upload/read/update/delete` comparan `b.id` con `storage.foldername(b.name)`. El alias `b` apunta a `public.businesses`; `b.name` es el nombre comercial, no el nombre de archivo. La ruta del objeto debe obtenerse de `storage.objects.name`.

**Corrección preparada**
- `database/security/storage-policy-fix.sql` reemplaza las cuatro políticas y toma la primera carpeta desde `storage.foldername(objects.name)`.
- Exige exactamente dos carpetas, UUID válido para el negocio, segundo nivel `logo` o `products`, negocio activo y rol `business_admin`.
- En UPDATE valida tanto la fila original como la nueva ruta mediante `USING` y `WITH CHECK`.
- No concede permisos a empleados ni al propietario técnico para administrar los archivos comerciales por Data API.

**Riesgo residual**
- El bucket público permite descarga a cualquier persona con la URL. Esto es apropiado para logos e imágenes públicas, pero no para archivos privados.
- El límite y MIME configurados en el bucket son controles adicionales; la validación de `file.type` en navegador no demuestra que el contenido real del archivo sea una imagen válida.
- La interfaz crea nombres UUID y no reutiliza objetos. No se requiere UPDATE para la carga ordinaria; el permiso DELETE sí es necesario para retirar imágenes reemplazadas.
- No hay objetos activos para probar el comportamiento real.

### 3.2 `job-applications-private` — hojas de vida

**Estado**
- El bucket existe y es privado, con límite de 5 MB y MIME permitido PDF/DOC/DOCX.
- La Edge Function `create-job-application` genera una ruta `<business_uuid>/<application_uuid>/<random_uuid>.<ext>` y una URL/token de carga temporal.
- El visitante carga con `uploadToSignedUrl`; no se encontró una política INSERT pública para el bucket. El diseño evita conceder cargas directas generales.
- La Edge Function comprueba que el negocio esté activo y que la página corresponda a una vacante publicada y aprobada.
- Al enviar la postulación, verifica que exista una sesión temporal coincidente, no consumida y no vencida, y que el objeto se encuentre en Storage.
- El panel administrador crea un enlace firmado de descarga con vigencia de 300 segundos.
- La política activa SELECT permite la lectura autenticada cuando la ruta corresponde a un negocio activo y el usuario es su administrador.

**Controles positivos**
- El bucket privado no permite descargas públicas.
- La sesión de carga vincula negocio, página, ruta y vencimiento.
- El borrador de limpieza elimina sesiones vencidas de forma controlada; no debe desplegarse sin su Edge Function coordinada.
- La política de lectura preparada en `storage-policy-fix.sql` exige que el objeto coincida exactamente con `job_applications.resume_path`, con negocio y postulación coincidentes.

**Riesgos pendientes**
- La Edge Function verifica extensión, MIME declarado y tamaño, pero no inspecciona la firma binaria real del archivo ni ejecuta análisis antimalware. Un MIME/extensión enviados por el navegador no demuestran que el documento sea seguro.
- El objeto puede quedar huérfano si se genera la URL de carga, se sube el archivo y la persona no termina la postulación. El borrador de limpieza contempla sesiones vencidas; debe verificarse que el proceso programado también elimine el objeto del bucket, no solo la fila temporal.
- El token de carga puede seguir siendo válido después del vencimiento de la sesión SQL, dependiendo de su vigencia propia. El envío se rechaza al vencer la sesión, pero puede quedar un archivo no asociado hasta la limpieza.
- La Edge Function de limpieza inicialmente reutilizaba el valor de `SUPABASE_SERVICE_ROLE_KEY` como secreto HTTP de autenticación. Se corrigió en la rama para exigir el secreto separado `JOB_APPLICATION_CLEANUP_SECRET`; el service role permanece solo como credencial interna del cliente servidor. Antes de desplegar, configurar ambos secretos en el entorno de ensayo y enviar el secreto de limpieza solo desde el programador autorizado.
- No se probó la descarga firmada con administrador A/B ni la denegación al empleado, visitante y administrador de otro negocio.

**Recomendación**
Antes de permitir descargas reales, incorporar inspección del tipo real del archivo y un proceso de análisis/validación de documentos. Si no se dispone de antivirus en esta etapa, mantener los archivos privados, no ejecutarlos ni previsualizarlos automáticamente y limitar las descargas a administradores autorizados.

### 3.3 `business-expense-receipts` — comprobantes de gastos

**Bloqueo crítico:** el bucket no existe en Storage activo.

El panel ya intenta:
- subir archivos PDF/JPG/PNG/WEBP de hasta 5 MB;
- guardarlos bajo `<business_uuid>/<expense_uuid>/<random_uuid>.<ext>`;
- asociar la ruta con la RPC `attach_business_expense_receipt`;
- crear enlaces firmados de 300 segundos para consultarlos.

Sin el bucket, la carga y lectura fallan.

**Corrección preparada**
- `database/finance/expense-receipts-storage-draft.sql` crea el bucket privado con límite de 5 MB y tipos permitidos.
- SELECT permite al administrador del negocio activo leer comprobantes vinculados a gastos de ese negocio.
- INSERT permite subir solo a la ruta de un gasto activo perteneciente al negocio del administrador.
- No crea UPDATE ni DELETE: los comprobantes quedan como evidencia de auditoría, incluso si el gasto se anula.
- La RPC de asociación comprueba que el gasto pertenezca al administrador, que no tenga ya comprobante y que el objeto exista en el bucket privado.

**Riesgo residual**
- Si la carga funciona pero la RPC de asociación falla, el objeto queda sin vínculo. Se debe preparar una rutina segura para localizar y eliminar únicamente archivos huérfanos no referenciados, con registro de auditoría y periodo de espera.
- El borrador no permite borrar ni reemplazar un comprobante asociado. Esto es deliberado para conservar evidencia, pero la interfaz debe comunicarlo y ofrecer un flujo de corrección mediante anulación/nota, no sobrescritura.

## 4. Pruebas de autorización requeridas

| Prueba | Administrador A | Administrador B | Empleado A | Visitante |
|---|---|---|---|---|
| Subir logo/producto de A | Permitido | Denegado | Denegado | Denegado |
| Borrar imagen de A | Permitido | Denegado | Denegado | Denegado |
| Descargar imagen pública con URL | Permitido | Permitido | Permitido | Permitido |
| Leer hoja de vida de A | Permitido, URL firmada | Denegado | Denegado | Denegado |
| Leer comprobante de A | Permitido, URL firmada | Denegado | Denegado | Denegado |
| Subir comprobante a gasto de A | Permitido | Denegado | Denegado | Denegado |

También deben probarse:
- rutas con UUID de otro negocio;
- rutas con carpetas adicionales o faltantes;
- negocio suspendido;
- reemplazo con archivo nuevo y retirada del anterior;
- extensión/MIME no permitido y archivo por encima de 5 MB;
- URL firmada vencida;
- postulación sin terminar y sesión vencida;
- objeto cargado pero no asociado;
- gasto anulado y comprobante ya asociado.

Cada prueba debe registrar rol, negocio, operación, resultado esperado, resultado real y evidencia sin datos personales.

## 5. Orden de migración y despliegue

1. Aplicar primero `business-admin-boundaries.sql`, que crea los helpers y límites de negocio requeridos.
2. Aplicar `storage-policy-fix.sql` para corregir las políticas del bucket de imágenes y reforzar la lectura de hojas de vida.
3. Crear `business-expense-receipts` y sus políticas con `expense-receipts-storage-draft.sql`.
4. Aplicar `business-expense-audit-draft.sql` después de crear el bucket y revisar las RPC.
5. Coordinar la migración de limpieza con `cleanup-job-application-data`; no desplegar la función de limpieza sin su RPC y pruebas.
6. Ejecutar todas las pruebas A/B con usuarios de ensayo antes de publicar.

No crear políticas generales para `authenticated` ni convertir hojas de vida o comprobantes en buckets públicos.

## 6. Documentación oficial consultada

- Supabase Storage Access Control: https://supabase.com/docs/guides/storage/security/access-control
- Supabase Storage Buckets: https://supabase.com/docs/guides/storage/buckets/fundamentals
- Supabase Product Security: https://supabase.com/docs/guides/security/product-security
- Supabase Changelog — restricciones de esquema Storage: https://supabase.com/changelog/34270-restricting-access-on-auth-storage-and-realtime-schemas-on-april-21-2025

Supabase confirma que los buckets privados aplican RLS a las descargas, mientras que un bucket público permite que cualquiera que conozca la URL descargue el archivo. También confirma que las cargas y reemplazos siguen sujetos a políticas; el reemplazo con `upsert` requiere INSERT, SELECT y UPDATE. Este proyecto usa `upsert: false` para las imágenes y por eso no necesita abrir permisos de reemplazo general.

## 7. Dictamen y estado

- Revisión de buckets activos: completada.
- Revisión de políticas de Storage: completada.
- Revisión de rutas y cargas en frontend/Edge Function: completada.
- Corrección de ruta para `business-assets`: ya existe como borrador en la rama; no aplicada al proyecto activo.
- Bucket de comprobantes: falta en Supabase activo; borrador preparado, no aplicado.
- Pruebas reales con usuarios A/B y archivos de ensayo: pendientes.
- Análisis de archivos de postulantes: pendiente de definir e implementar.
- Limpieza de archivos huérfanos: pendiente de verificar y coordinar.

**Conclusión:** Storage no está listo para producción. El error de ruta en las políticas activas puede impedir la gestión autenticada de imágenes y el bucket de comprobantes falta por completo. Las hojas de vida están en un bucket privado, pero todavía requieren pruebas de aislamiento y controles adicionales sobre el contenido de los archivos. No se hicieron cambios en Supabase activo ni se desplegaron funciones.

## 8. Revisión complementaria de Storage en Supabase activo — 19 nov 2026

Se repitió la consulta en modo solo lectura sobre storage.buckets, storage.objects, pg_policies y los privilegios de storage.objects.

**Resultado observado:**
- Los buckets existentes continúan siendo business-assets (público, 5 MB, PNG/JPEG/WEBP) y job-applications-private (privado, 5 MB, PDF/DOC/DOCX).
- En ambos buckets se observaron cero objetos. Por tanto, no se identificaron archivos existentes que pudieran descargarse, pero tampoco fue posible probar una descarga o carga real.
- storage.objects tiene RLS habilitado.
- anon y authenticated tienen privilegios SQL generales sobre storage.objects, pero RLS limita las filas: no se encontró una policy para anon en los buckets privados; authenticated solo tiene la policy SELECT prevista para hojas de vida y políticas de negocio para activos comerciales. No hay políticas directas de INSERT/UPDATE/DELETE sobre el bucket privado de CV.
- service_role conserva privilegios amplios sobre Storage. Esto es propio del rol de servicio y permite que las Edge Functions operen sin RLS; su clave debe permanecer exclusivamente en secretos del servidor y nunca enviarse al navegador.

**Diferencia precisa entre base activa y rama:**
- La policy activa job_application_documents_business_admin_read limita por bucket, carpeta del negocio activo y rol business_admin, pero no exige que el objeto coincida con una fila de job_applications ni con su resume_path exacto. La política de database/security/storage-policy-fix.sql añade esa relación entre negocio, postulación y ruta, y valida el nombre UUID del archivo con extensión permitida.
- Las policies activas de business-assets siguen usando storage.foldername(b.name) en vez de storage.foldername(objects.name). El verificador de la rama ya detecta ese error; el archivo storage-policy-fix.sql sustituye las cuatro policies con una ruta de objeto correctamente validada.
- No se ejecutó storage-policy-fix.sql, no se cambió ninguna policy activa y no se desplegó ninguna Edge Function.

**Controles del panel y de las Edge Functions revisados:**
- panel-live.js consulta postulaciones filtrando por business_id, y solo solicita un enlace firmado de 300 segundos cuando el administrador pulsa Descargar.
- create-job-application crea rutas con UUID de negocio, postulación y archivo; la carga se entrega mediante token firmado, no mediante una policy INSERT pública.
- cleanup-job-application-data valida el formato de la ruta antes de borrar un objeto huérfano y conserva los CV asociados a postulaciones.
- La limpieza requiere el secreto separado JOB_APPLICATION_CLEANUP_SECRET; el service_role se utiliza únicamente en el servidor.

**Pendientes antes de producción:**
1. Aplicar el paso 7 (storage-policy-fix.sql) únicamente en staging y ejecutar pruebas A/B de administrador, empleado, visitante y negocio suspendido.
2. Probar la carga de una imagen y la descarga de un CV con dos negocios distintos, incluyendo intento de usar la ruta de otro negocio.
3. Incorporar análisis antimalware o un proceso de cuarentena/validación de documentos antes de que el personal abra CVs.
4. Definir una política de retención para postulaciones y CV asociados; la limpieza actual solo cubre sesiones temporales y archivos huérfanos.
5. Mantener service_role y JOB_APPLICATION_CLEANUP_SECRET solo en el entorno de servidor.

El verificador integral se amplió para exigir que las cuatro policies de business-assets usen la ruta real del objeto y que la policy privada vincule negocio, postulación y resume_path. Estas verificaciones siguen pendientes de ejecución en staging.


## 9. ACC-20 — El verificador no descartaba políticas adicionales que ampliaran el acceso a CV privados

**Hallazgo de revisión estática:** el verificador comprobaba que existiera la policy esperada `job_application_documents_business_admin_read` y que no hubiera una policy de `anon` que mencionara explícitamente el bucket privado. Sin embargo, no recorría todas las demás políticas de `storage.objects` para descartar una regla genérica de `authenticated` o `public` que pudiera permitir acceso al mismo bucket por combinación permisiva de políticas.

En PostgreSQL, varias políticas permisivas aplicables se combinan de forma que una regla adicional amplia puede abrir filas que la policy específica pretendía restringir. La comprobación de una sola policy no basta para descartar ese escenario.

**Corrección en la rama:** se reforzó `database/integration/verify-integration-package.sql` para:
- Revisar las policies de `storage.objects` aplicables a `public`, `anon` y `authenticated`.
- Exigir que cada policy distinta de la policy específica de CV limite expresamente el bucket y no incluya `job-applications-private`.
- Revisar `USING` para SELECT/DELETE y `WITH CHECK` para INSERT/UPDATE.
- Exigir que la policy de lectura de CV esté asignada exclusivamente a `authenticated`.

**Commit:** `a23d42dd923f4e6cb678099150cf3e15453b0d98`.

Este refuerzo es una comprobación preventiva del verificador. No demuestra que el proyecto activo tenga una política adicional vulnerable: las consultas de solo lectura anteriores no mostraron otra policy para el bucket privado. La condición nueva debe ejecutarse en staging después de aplicar el paquete y revisar manualmente cualquier policy que haga fallar el control.


## 10. ACC-21 — La lectura de comprobantes no exigía que el objeto fuera el comprobante asociado al gasto

**Hallazgo de revisión estática:** la policy propuesta `business_expense_receipts_admin_read` validaba bucket privado, estructura de ruta, UUID de negocio, UUID de gasto, extensión y rol de administrador. Sin embargo, no comparaba el nombre del objeto con `business_expenses.receipt_path`.

Esto no permitía leer archivos de otros negocios, pero sí dejaba que un administrador autorizado del mismo negocio leyera cualquier objeto que siguiera el patrón de ruta de uno de sus gastos, aunque ese objeto no fuera el comprobante asociado al registro. La asociación exacta reduce la superficie de acceso a archivos huérfanos o no vinculados.

**Corrección en la rama:** la policy SELECT ahora exige `e.receipt_path = name`, además de las condiciones anteriores. La RPC `attach_business_expense_receipt` ya valida la existencia del objeto y asocia la ruta exacta; el verificador integral ahora exige también la condición `receipt_path` en la policy de lectura.

**Commits:**
- Policy de Storage: `553fb906a1a86faab29fc0c1d4628c7920ee6cf3`
- Verificador: `54392017238dae227548cdeefd9ee5d39ad1296d`

La corrección afecta únicamente el borrador y el verificador en GitHub. No se creó el bucket, no se aplicó SQL y no se modificó Supabase activo.


## 11. ACC-22 — La limpieza de archivos temporales no tiene un programador configurado en el repositorio

**Hallazgo:** existe la Edge Function `cleanup-job-application-data` y el borrador SQL de limpieza de sesiones vencidas, pero la rama no contiene un workflow programado ni una configuración de `pg_cron` que demuestre que la función se ejecutará periódicamente. En el proyecto activo ya se había observado que `pg_cron` no estaba instalado y no se había acreditado otro programador.

La función no se ejecuta por existir en el repositorio. Sin un programador privado que la invoque con `JOB_APPLICATION_CLEANUP_SECRET`, las sesiones vencidas y los archivos temporales pueden permanecer almacenados.

**Estado y decisión:** no se creó un cron ni un workflow improvisado. Antes de elegirlo hay que definir dónde se ejecutará el programador, cómo almacenará el secreto, la frecuencia, las alertas de fallos y el procedimiento de reintento. El programador no debe exponer el secreto en el navegador ni en un repositorio.

**Pruebas pendientes:** invocación autorizada y no autorizada, ejecución repetida, lotes con más de 100 sesiones, error de Storage, reintento, preservación de CV asociados y evidencia de que los archivos temporales no se eliminan antes de expirar sus tokens.

Este hallazgo es operativo y de retención; no significa que los CV asociados a postulaciones se estén borrando. La limpieza actual está diseñada para conservar los archivos vinculados a postulaciones y retirar únicamente objetos de sesiones vencidas sin postulación.
