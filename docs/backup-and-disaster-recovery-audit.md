# Auditoría de copias de seguridad y recuperación ante desastres

**Estado:** revisión documental y de metadatos; disponibilidad de respaldos y restauración no comprobadas.  
**Rama:** `correcciones-funcionales`.  
**Proyecto de referencia:** `MiEje Market Independiente` (proyecto activo y saludable al consultar metadatos).  
**Producción:** sin cambios. No se descargaron respaldos, no se restauró ningún proyecto, no se ejecutó SQL ni se modificó Storage.

## ACC-25 — No hay evidencia suficiente de una copia recuperable de la plataforma completa

### 1. Resultado de la revisión

- El proyecto Supabase `MiEje Market Independiente` aparece `ACTIVE_HEALTHY` en los metadatos consultados. Este estado confirma disponibilidad del proyecto en ese momento, no que existan respaldos descargables ni que una restauración haya sido probada.
- La información de plan, la pantalla Database > Backups, los puntos de recuperación PITR y los trabajos de backup no estuvieron disponibles en la respuesta de metadatos consultada. Por tanto, no se afirma que el proyecto tenga backups diarios, PITR ni una retención específica.
- El repositorio no contiene un procedimiento de respaldo y restauración integral ya verificado.
- La auditoría previa de Storage encontró buckets comerciales públicos y documentos privados. Los objetos reales deben respaldarse aparte de la base de datos.
- No se realizó una restauración ni una descarga de objetos.

### 2. Qué cubre el respaldo de base de datos y qué no

Según la documentación oficial de Supabase, los backups de base de datos **no incluyen los archivos almacenados mediante Storage API**. La base guarda metadatos de los objetos, pero restaurar una copia antigua no recupera archivos que se hayan eliminado después de esa copia.

Esto significa que un respaldo de PostgreSQL por sí solo no basta para recuperar MiEje Market. Se necesitan dos conjuntos coordinados:

1. **Base de datos:** negocios, perfiles, membresías, productos, pedidos, líneas de pedido, pagos, reembolsos, inventario, auditoría, configuraciones y metadatos de Storage.
2. **Objetos Storage:** logos, imágenes de productos, CV y comprobantes, conservando bucket, ruta, asociación y permisos esperados.

Fuente oficial: [Supabase — Database Backups](https://supabase.com/docs/guides/platform/backups).

### 3. Backups automáticos y diferencias por plan

La documentación vigente de Supabase indica:
- Pro, Team y Enterprise reciben backups diarios automáticos.
- La retención indicada es 7 días para Pro, 14 para Team y hasta 30 para Enterprise.
- En Free, Supabase recomienda exportaciones periódicas con Supabase CLI y copias externas.
- PITR es un complemento para Pro, Team y Enterprise y requiere al menos el complemento de cómputo Small.
- Activar PITR reemplaza el esquema de backups diarios descrito en la guía; no se debe activar sin revisar coste y retención.

**No se ha confirmado cuál de estos escenarios corresponde al proyecto.** Antes de adoptar una estrategia hay que verificar el plan y los ajustes reales en el Dashboard, no inferirlos por el estado ACTIVE_HEALTHY ni por el coste de creación histórico.

Fuente oficial: [Supabase — Database Backups](https://supabase.com/docs/guides/platform/backups).

### 4. Estrategia de respaldo recomendada

#### A. Base de datos
- Si el plan no ofrece backups automáticos descargables, generar exportaciones lógicas periódicas mediante el flujo oficial de Supabase CLI.
- Guardar cada copia cifrada en un destino externo al proyecto y a la misma cuenta de acceso operativo.
- Conservar manifiesto con fecha UTC, proyecto de origen, versión PostgreSQL, versión del esquema/commit y resultado de integridad.
- No guardar contraseñas, tokens, claves API ni secretos dentro del respaldo documental.
- Mantener al menos una copia aislada con permisos de solo lectura para el proceso ordinario.

#### B. Storage
- Exportar objetos de cada bucket por separado usando mecanismos oficiales de descarga masiva o compatibilidad S3.
- Mantener un manifiesto de bucket, ruta, tamaño, tipo, fecha y hash criptográfico del archivo, sin incluir contenido privado en el manifiesto.
- Cifrar los CV y comprobantes en reposo y limitar el acceso al personal autorizado.
- Conservar los nombres/rutas originales para que las referencias de la base sigan apuntando a los objetos restaurados.
- No hacer público un bucket privado para facilitar el respaldo o la recuperación.

Fuentes oficiales:
- [Supabase — Download Objects](https://supabase.com/docs/guides/storage/management/download-objects).
- [Supabase — Migrating within Supabase](https://supabase.com/docs/guides/platform/migrating-within-supabase).

#### C. Configuración e infraestructura
Mantener una copia versionada y controlada de:
- migraciones SQL y configuración de Supabase;
- código fuente de Edge Functions;
- configuración de Auth (sin secretos);
- políticas RLS, permisos, triggers y funciones;
- lista de buckets, visibilidad, límites y MIME permitidos;
- configuración de dominios, redirects y proveedores externos;
- inventario de secretos por nombre, ubicación y responsable, nunca sus valores.

El código del repositorio no reemplaza la configuración alojada en el Dashboard. La restauración debe contemplar volver a configurar variables de entorno y credenciales.

### 5. Orden de recuperación propuesto

La recuperación debe hacerse primero en un proyecto aislado, nunca sobre el proyecto activo como ensayo.

1. Crear o seleccionar un proyecto de recuperación independiente y verificar región, versión PostgreSQL y aislamiento.
2. Restaurar la base de datos en el destino aislado, siguiendo el procedimiento oficial y sin sobrescribir el proyecto de origen.
3. Restaurar los objetos Storage y conservar rutas originales.
4. Reaplicar configuración no incluida en la copia: secretos, Auth, URLs, redirects, funciones y ajustes de buckets.
5. Revisar migraciones y versión de código para confirmar compatibilidad entre esquema y aplicación.
6. Verificar relaciones entre negocios, usuarios, membresías, productos, pedidos, pagos y archivos.
7. Probar RLS con dos negocios y roles distintos: propietario técnico, administrador, empleado y visitante.
8. Conciliar pedidos, pagos, reembolsos, inventario y movimientos financieros.
9. Solo después de la aprobación formal, definir una ventana de cambio y un procedimiento de conmutación. No redirigir tráfico automáticamente durante una prueba.

### 6. Pruebas de restauración necesarias

La prueba solo se considera satisfactoria si se restaura una copia real y se comprueba:

- que las tablas y relaciones esperadas existen;
- que los perfiles y membresías conservan su relación correcta;
- que los pedidos y líneas mantienen sus totales y referencias;
- que los movimientos de inventario y registros financieros cuadran;
- que las rutas Storage existen y corresponden al negocio correcto;
- que los CV y comprobantes permanecen privados;
- que las imágenes comerciales públicas siguen cargando;
- que los permisos entre negocio A y B siguen aislados;
- que las Edge Functions funcionan con secretos reconfigurados;
- que se puede completar un pedido de prueba sin usar pagos reales.

Registrar resultado esperado, resultado obtenido, fecha UTC, commit, versión de base de datos, evidencia sanitizada y responsable. La restauración debe repetirse periódicamente y después de cambios importantes en el esquema.

### 7. RPO y RTO

No se fijan objetivos de recuperación sin conocer el plan, la retención real y el tiempo medido de restauración.

- **RPO:** cantidad máxima de información reciente que el negocio acepta perder.
- **RTO:** tiempo máximo que acepta permanecer sin el servicio.

Estos valores deben aprobarse según el impacto de perder pedidos, pagos e inventario y medirse en un ejercicio real. La cifra de RPO anunciada por PITR no debe confundirse con una garantía de restauración completa de Storage.

### 8. Riesgos y decisiones pendientes

1. Confirmar el plan contratado del proyecto y consultar Database > Backups.
2. Verificar si hay backups diarios disponibles y su fecha más reciente.
3. Confirmar si PITR está disponible o habilitado y cuál es su retención/coste.
4. Definir ubicación externa cifrada para copias de base de datos y Storage.
5. Definir periodicidad y retención de ambas copias.
6. Establecer quién puede descargar, restaurar y autorizar una recuperación.
7. Ejecutar un simulacro en un proyecto aislado y medir RPO/RTO.
8. Definir cómo rotar credenciales y recuperar proveedores externos sin incluir secretos en Git.

### Dictamen

La disponibilidad actual del proyecto no demuestra que exista una copia recuperable. Supabase separa los backups de base de datos de los objetos Storage; por eso la continuidad de MiEje requiere respaldar ambos y comprobar la restauración en un entorno independiente.

**No se descargaron respaldos, no se configuró PITR, no se restauró ningún proyecto, no se ejecutó SQL y no se alteró el proyecto activo.**
