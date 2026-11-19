# Auditoría de imágenes de negocios y productos

**Rama:** `correcciones-funcionales`  
**Proyecto revisado:** MiEje Market Independiente  
**Estado:** auditoría y correcciones preparadas en rama; no desplegadas.  
**Fecha:** 16 de noviembre de 2026.

## 1. Configuración observada en Supabase

El bucket `business-assets` existe y es público. Su configuración observada:

- Tamaño máximo: 5 MiB por archivo.
- Tipos MIME permitidos: PNG, JPEG y WEBP.
- Versionado de objetos: desactivado.
- Lectura pública: habilitada por diseño para que la tienda pueda mostrar logos e imágenes sin enlaces firmados.

El bucket `job-applications-private` es privado y no debe utilizarse para imágenes públicas de productos o negocios. Los documentos de candidatos permanecen separados.

En la consulta de solo lectura realizada durante esta auditoría, `storage.objects` no contenía objetos en los dos buckets revisados. Las tablas `businesses` y `products` tampoco tenían registros ni imágenes asociadas. Por eso no fue posible probar una sustitución real de imagen con datos existentes.

## 2. Convención de rutas

El panel genera rutas con esta estructura:

- Logo: `<business_id>/logo/<uuid>.(png|jpg|webp)`
- Producto: `<business_id>/products/<uuid>.(png|jpg|webp)`

El código usa `crypto.randomUUID()`, carga con `upsert: false` y guarda la URL pública resultante en:

- `businesses.logo_url`
- `products.image_url`

La ruta de Storage no se guarda por separado en esas columnas; se puede recuperar de la URL pública cuando esta pertenece al bucket y al proyecto esperados.

## 3. Hallazgo crítico: políticas activas de Storage

En las políticas activas del bucket `business-assets` se encontró que INSERT, SELECT, UPDATE y DELETE intentaban obtener el identificador del negocio mediante `storage.foldername(b.name)`.

Ese dato es incorrecto: `b.name` es el nombre del negocio, no la ruta del objeto de Storage. La comprobación debe leer `storage.objects.name`. El defecto puede impedir operaciones legítimas y no valida la carpeta real del archivo.

El borrador existente `database/security/storage-policy-fix.sql` ya contiene la corrección propuesta. Las cuatro políticas:

1. Usan `storage.foldername(objects.name)`.
2. Exigen exactamente dos segmentos de carpeta.
3. Validan que el primer segmento sea un UUID.
4. Limitan el segundo segmento a `logo` o `products`.
5. Comprueban que el negocio exista, esté activo y que el usuario tenga el rol `business_admin`.
6. Para UPDATE, aplican las condiciones tanto en `USING` como en `WITH CHECK`.

La política de lectura pública del bucket sigue dependiendo de que el bucket sea público. Las políticas RLS restringen las operaciones autenticadas de administración; no convierten las imágenes en privadas.

**Importante:** el SQL sigue siendo un borrador. No se ejecutó en el proyecto.

## 4. Hallazgo: imágenes antiguas huérfanas al reemplazar

Antes de esta corrección, el panel subía una imagen nueva y actualizaba la URL en la tabla, pero no retiraba el objeto anterior de Storage. Al reemplazar o quitar un logo o imagen de producto, el archivo anterior podía quedar almacenado sin estar referenciado por la base de datos.

Se actualizó `panel-live.js` en la rama para:

- Reconocer únicamente URLs del origen del proyecto Supabase y de la ruta pública del bucket `business-assets`.
- Validar que la ruta pertenezca al negocio seleccionado y a la carpeta esperada (`logo` o `products`).
- Validar el UUID del archivo y las extensiones permitidas antes de intentar eliminarlo.
- Retirar el objeto anterior solo después de que la actualización de la fila haya tenido éxito.
- Si falla la actualización de la fila, retirar el archivo nuevo que se acababa de subir, para evitar dejarlo huérfano.

La eliminación se hace mediante `db.storage.from('business-assets').remove(...)`, no mediante DELETE directo sobre `storage.objects`.

Si Storage rechaza la eliminación del archivo anterior, el código registra una advertencia en consola y conserva la fila ya actualizada. En ese caso puede quedar un objeto huérfano que requiere revisión; todavía no existe un proceso automático de reintento o limpieza para imágenes de negocios y productos.

## 5. Límites y riesgos pendientes

- El bucket es público: cualquier persona que conozca una URL válida puede ver la imagen. No se deben almacenar allí hojas de vida, comprobantes privados ni datos personales.
- El panel valida tipo MIME y tamaño antes de subir. No se encontró en este flujo un proceso de re-encode o inspección binaria del archivo; la lista MIME del bucket no equivale a análisis antimalware.
- Los campos `logo_url` e `image_url` también admiten URLs externas HTTP/HTTPS. Esas imágenes no pertenecen a Storage de MiEje y el panel no intenta eliminarlas.
- El panel de empleados no debe recibir permisos de escritura o eliminación de imágenes. La política revisada limita la gestión autenticada al administrador del negocio activo.
- La corrección de las políticas debe aplicarse y probarse en un entorno de ensayo antes de producción. No basta con que el código del panel esté actualizado.

## 6. Verificaciones realizadas

Comprobaciones estáticas en la rama:

- Ruta de carga formada con el ID del negocio, la carpeta y un UUID aleatorio.
- Validación en el panel de PNG/JPEG/WEBP y límite de 5 MiB.
- Uso de URL pública para mostrar las imágenes.
- Validación del origen Supabase, negocio, carpeta, UUID y extensión antes de eliminar una imagen anterior.
- Eliminación del objeto anterior después de guardar correctamente la nueva referencia.
- Eliminación del nuevo objeto cuando falla la escritura de la fila.
- SQL de las cuatro políticas usa la ruta real de `storage.objects.name`, exige dos carpetas y valida negocio activo y rol administrativo.
- La política UPDATE incluye `USING` y `WITH CHECK`.

Prueba aislada de la expresión de ruta: aceptó una ruta válida de producto y rechazó rutas con otro negocio, carpeta incorrecta o segmentos de recorrido.

No se hicieron cargas reales porque el bucket no contenía objetos y no había negocios ni productos registrados en el proyecto independiente.

## 7. Acciones no realizadas

- No se ejecutó SQL ni se aplicó una migración.
- No se desplegó código en Supabase.
- No se modificó `main` ni se publicó GitHub Pages.
- No se eliminaron objetos ni registros.
- No se modificaron las políticas activas de producción.

## 8. Pruebas obligatorias antes de producción

1. Un administrador del negocio A puede subir, reemplazar y quitar su logo.
2. Un administrador del negocio A puede subir, reemplazar y quitar imágenes de sus productos.
3. El administrador A no puede subir, reemplazar, listar ni eliminar objetos del negocio B.
4. Un empleado no puede administrar imágenes si no se le concede expresamente ese permiso.
5. La tienda pública puede visualizar las imágenes de ambos negocios.
6. Si falla el guardado de la fila, el archivo nuevo se retira y la URL anterior permanece intacta.
7. Si falla la eliminación del archivo anterior, la interfaz informa o deja un registro visible para revisión operativa.
8. Reemplazar o quitar una imagen no deja objetos huérfanos cuando Storage responde correctamente.
9. Las imágenes externas no provocan intentos de borrado dentro de Storage.
10. Los archivos privados de postulaciones nunca se sirven desde `business-assets`.

La prioridad antes de producción es revisar y probar el borrador SQL de Storage en ensayo. Después se debe realizar una prueba real de carga, visualización, reemplazo y eliminación con dos negocios de prueba.


## 9. Verificación adicional del panel y de imágenes públicas

Durante la revisión posterior se detectó que el archivo `panel-live.js` tenía un bloque duplicado fuera del cierre de su función principal. Ese bloque contenía restos de una validación anterior y repetía funciones del panel. Se retiró únicamente el contenido sobrante posterior al primer cierre completo.

Comprobaciones estáticas posteriores:

- El archivo conserva una sola función principal autoejecutable y un solo cierre.
- Existe una sola declaración de `saveProduct` y una sola función de validación de rutas de imágenes.
- La función principal contiene todas las funciones que aparecían en el bloque duplicado; no se eliminaron funciones exclusivas.
- Se mantiene la limpieza de imágenes antiguas de productos y logos, con validación de origen, negocio, carpeta y nombre de archivo.
- La rama incorpora un manejador de errores de carga para las imágenes públicas de tarjetas de negocios, tarjetas de productos y encabezados de tienda. Si una imagen no carga, se oculta y se muestra el texto accesible “Imagen no disponible”.
- Se añadieron estilos para que el espacio de la imagen conserve una presentación estable.

La verificación fue estática sobre el contenido de GitHub. No se ejecutó el panel en navegador ni se realizó una prueba de carga real en Storage. Por ello, esta corrección no se considera validada en ejecución hasta probarla en un entorno de ensayo.


## 10. Confirmación de políticas activas (consulta de solo lectura)

Se volvió a consultar el proyecto independiente después de las correcciones de código. El bucket `business-assets` continúa configurado como público, con límite de 5 MiB y tipos PNG, JPEG y WEBP.

Las cuatro políticas activas (`INSERT`, `SELECT`, `UPDATE` y `DELETE`) todavía contienen la expresión incorrecta `storage.foldername(b.name)` dentro de la subconsulta a `businesses`. Por tanto, el borrador corregido no se ha aplicado al proyecto.

La lectura pública por URL es coherente con un bucket público; según la documentación actual de Supabase, el acceso público omite RLS para servir/descargar el objeto, pero subir, actualizar y eliminar siguen sujetos a las políticas. Los archivos de candidatos deben permanecer en el bucket privado y no deben mezclarse con imágenes públicas.

Esta confirmación fue únicamente de lectura. No se modificaron políticas, buckets, archivos ni datos.
