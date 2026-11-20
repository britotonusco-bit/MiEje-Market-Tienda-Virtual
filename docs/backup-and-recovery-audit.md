# Auditoría de copias de seguridad y recuperación

**Proyecto:** MiEje Market Independiente  
**Supabase project ref:** `cqixlrwbqatbhzmpygiz`  
**Rama de código:** `correcciones-funcionales`  
**Fecha de revisión:** 19 de noviembre de 2026  
**Alcance:** base de datos, Storage, Auth, Edge Functions, configuración y recuperación ante errores.  
**Método:** inspección de repositorio y consultas de solo lectura. No se crearon backups, no se restauró ningún proyecto y no se modificó Supabase.

## 1. Dictamen

**La estrategia de recuperación de MiEje Market todavía no está lista para producción.**

La organización Supabase consultada utiliza el plan **Free**. Según la documentación vigente de Supabase, los backups automáticos diarios de base de datos están incluidos en planes Pro, Team y Enterprise; para proyectos Free, Supabase recomienda exportar periódicamente con Supabase CLI y guardar copias fuera de Supabase.

No se obtuvo un inventario de backups descargables ni una prueba de restauración. Por ello, no se puede afirmar que exista una copia recuperable reciente del proyecto activo.

Además, los backups de base de datos **no incluyen los objetos de Storage**. Se deben respaldar por separado los archivos de buckets, y también conservar el código/configuración de Edge Functions y los secretos en un almacén seguro.

Fuentes oficiales:
- https://supabase.com/docs/guides/platform/backups
- https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore
- https://supabase.com/docs/guides/storage/management/delete-objects

## 2. Estado observado

| Componente | Estado comprobado | Implicación |
|---|---|---|
| Plan Supabase | Free | No asumir backups diarios automáticos. Preparar exportaciones manuales periódicas. |
| Proyecto | `ACTIVE_HEALTHY`, Postgres 17 | La base respondió a consultas de solo lectura. Esto no acredita recuperación. |
| Migraciones registradas | 12 | La base activa aún no incluye todos los módulos de la rama. |
| Branches Supabase | Ninguna | No hay branch de desarrollo de base de datos registrado en el proyecto. |
| `pg_cron` | Extensión disponible, no instalada | No hay scheduler SQL configurado por esa extensión. |
| Objetos Storage observados | 0 en `business-assets` y `job-applications-private` | No se validó un proceso externo de copia de archivos. |
| Backups exportados fuera de Supabase | No acreditados | Falta evidencia de exportación y almacenamiento externo. |
| Restauración de prueba | No acreditada | No se conoce el tiempo real ni la integridad de una recuperación. |
| Automatización GitHub Actions | No se encontró carpeta `.github` en la raíz consultada | No hay evidencia de workflow de backup/despliegue en esta rama. |
| Scripts de backup | La búsqueda del repositorio no devolvió resultados | No hay un procedimiento automatizado versionado identificado. |

Los conteos de Storage son una fotografía del momento de consulta, no una garantía futura.

## 3. Qué cubre cada respaldo

### 3.1 Base de datos PostgreSQL

La exportación debe contemplar, según compatibilidad y permisos:
- esquema y funciones propias;
- datos de tablas de negocio;
- roles y grants que puedan exportarse de forma segura;
- políticas RLS, triggers, índices y constraints;
- registro de migraciones.

No se deben copiar indiscriminadamente esquemas internos administrados por Supabase. Para exportaciones compatibles con Supabase, utilizar `supabase db dump` siguiendo la documentación oficial.

Ejemplo orientativo para un entorno local seguro, con la cadena de conexión obtenida directamente desde el Dashboard y sin guardarla en Git:

```bash
supabase db dump --db-url "$DB_URL" -f schema.sql
supabase db dump --db-url "$DB_URL" -f data.sql --use-copy --data-only
```

La exportación de roles, cuando sea necesaria, debe tratarse separadamente y los secretos/contraseñas deben restablecerse según la guía oficial. No almacenar la cadena de conexión, contraseñas ni tokens en el repositorio.

### 3.2 Supabase Storage

Los archivos de `business-assets`, CV y futuros comprobantes no quedan respaldados por un dump PostgreSQL. La base conserva metadatos, no el contenido binario de los objetos.

Se necesita un proceso independiente que:
1. Liste objetos por bucket y pagine hasta completar el inventario.
2. Descargue los archivos mediante Storage API.
3. Mantenga la ruta relativa y registre tamaño, tipo MIME, fecha y checksum.
4. Cifre la copia externa y limite quién puede acceder.
5. Verifique periódicamente que los archivos descargados se pueden leer y que los checksums coinciden.

No borrar ni mover objetos de producción como parte de una prueba de backup.

### 3.3 Auth, Edge Functions y configuración

- Las cuentas Auth, sesiones, configuración de proveedores, plantillas de correo y URLs permitidas requieren una revisión/exportación específica; no asumir que un dump de tablas públicas las cubre.
- El código de las Edge Functions está en GitHub en esta rama, pero debe conservarse junto con la versión desplegada y el commit exacto.
- `supabase/config.toml` documenta parte de la configuración de funciones; no contiene los valores secretos.
- Guardar secretos y credenciales en un gestor seguro, con acceso restringido y rotación. Nunca incluir `service_role`, contraseñas DB, claves de acceso o `JOB_APPLICATION_CLEANUP_SECRET` en GitHub.
- Mantener inventario de proveedores de correo, Auth Redirect URLs, claves públicas, webhooks, dominios y servicios externos.

## 4. Recuperación y riesgo de restauración

Una restauración de backup puede sobrescribir el estado actual de la base y causar indisponibilidad durante el proceso. No debe ensayarse sobre el proyecto activo.

Procedimiento seguro:
1. Crear un proyecto de recuperación aislado, con acceso restringido.
2. Restaurar allí el dump de base de datos.
3. Recuperar por separado los archivos Storage desde la copia externa.
4. Configurar secretos nuevos; no copiar secretos de producción sin rotación y revisión.
5. Desplegar las Edge Functions desde un commit identificado.
6. Verificar tablas, constraints, índices, RLS, grants, triggers, funciones y migraciones.
7. Ejecutar pruebas de aislamiento entre negocios y roles.
8. Comparar conteos, checksums y relaciones de archivos.
9. Documentar duración, errores y datos no recuperados.
10. Solo después de aprobar el ensayo, redactar un procedimiento de recuperación para producción.

La restauración de un backup antiguo puede no recuperar archivos de Storage borrados después de esa copia. También puede dejar Auth, funciones o secretos fuera de sincronía si no se respaldan por separado.

## 5. Objetivos de recuperación todavía no aprobados

No se deben inventar compromisos de disponibilidad. Antes de producción, el responsable del servicio debe aprobar:

- **RPO (Recovery Point Objective):** cuánta información reciente se acepta perder.
- **RTO (Recovery Time Objective):** cuánto tiempo máximo se acepta estar fuera de servicio.
- Frecuencia de exportación de base de datos.
- Frecuencia de copia de Storage.
- Retención y cifrado de copias.
- Ubicación externa y responsables de acceso.
- Frecuencia de ensayos de restauración.
- Procedimiento de comunicación a negocios y clientes ante un incidente.

En el plan Free, si se depende únicamente de exportaciones manuales, el RPO real será el tiempo transcurrido desde la última exportación válida; no debe prometerse recuperación al minuto.

## 6. Controles que deben implementarse

1. Exportación periódica de base de datos a almacenamiento externo cifrado.
2. Copia separada de todos los buckets Storage, con checksums.
3. Inventario versionado de funciones desplegadas y configuración no secreta.
4. Custodia segura y recuperación controlada de secretos.
5. Alertas de exportación fallida y de copias demasiado antiguas.
6. Prueba de restauración aislada con checklist y evidencia.
7. Política de retención de backups, incluyendo eliminación segura al vencer el plazo.
8. Protección contra borrado accidental del proyecto y separación de permisos administrativos.
9. Registro de fecha, versión de esquema, commit de código y resultado de cada backup.
10. Prueba de consistencia entre pedidos, líneas, pagos, inventario y objetos Storage restaurados.

## 7. Condiciones para cerrar esta auditoría

- [ ] Exportación real de base de datos generada y validada.
- [ ] Copia externa de Storage generada y verificada por checksum.
- [ ] Secretos y configuración externa inventariados sin exponer sus valores.
- [ ] Restauración completa en proyecto aislado.
- [ ] Pruebas funcionales y RLS posteriores a restauración.
- [ ] RPO/RTO aprobados.
- [ ] Responsable, frecuencia y retención definidos.
- [ ] Evidencia de ejecución y alertas documentada.

## 8. Límites de esta revisión

No se generó ni descargó una copia, no se consultaron contraseñas ni valores secretos, no se modificaron buckets, no se ejecutó una restauración, no se pausó el proyecto y no se desplegó nada. La revisión acredita configuración/estado consultado y brechas detectadas; no acredita que exista una copia recuperable.


## 9. Verificación complementaria — 20 de noviembre de 2026

Se repitieron comprobaciones de solo lectura sobre el proyecto y el repositorio para confirmar si había cambiado el estado desde la revisión inicial.

| Componente | Verificación del 20 nov 2026 | Resultado |
|---|---|---|
| Organización Supabase | Consulta de metadatos de organización | Plan `free` confirmado. |
| Proyecto | Metadatos de proyecto | `ACTIVE_HEALTHY`, Postgres 17.11. |
| Historial de migraciones | Listado de migraciones registradas | 12 migraciones; la última sigue siendo `20261112202907_secure_public_job_application`. |
| Branches de base de datos | Listado de branches Supabase | Ninguna. |
| `pg_cron` | Catálogo de extensiones | Disponible como extensión, pero `installed_version` es NULL; no está instalada. |
| Storage | Consulta agregada de buckets y objetos | `business-assets`: público, límite 5 MiB, 0 objetos. `job-applications-private`: privado, límite 5 MiB, 0 objetos. |
| Código de backup | Árbol completo de la rama | No se identificó script específico de backup. |
| GitHub Actions | Árbol completo de la rama | No se encontró `.github/workflows/`. |

### Límite para comprobar los backups administrados por Supabase

Las herramientas conectadas disponibles en esta revisión permiten consultar metadatos del proyecto, migraciones, extensiones, tablas y ejecutar SQL de lectura, pero no exponen un listado de backups administrados ni sus fechas de recuperación. Por tanto, **no se verificó directamente la pantalla Database → Backups ni se descargó un backup**. La ausencia de un listado en esta revisión no demuestra por sí sola que Supabase no tenga una copia interna; el plan Free sí confirma que no debemos depender de los backups diarios automáticos incluidos en Pro/Team/Enterprise.

La documentación oficial actual indica que los proyectos Free deben exportar regularmente con Supabase CLI y conservar copias externas. También confirma que los backups de base de datos no incluyen los objetos de Storage. La restauración desde el Dashboard deja el proyecto inaccesible durante el proceso, por lo que no se debe usar el proyecto activo como entorno de ensayo.

Referencia oficial consultada: https://supabase.com/docs/guides/platform/backups

### Dictamen actualizado

La evidencia disponible sigue sin acreditar una copia externa reciente ni una restauración probada. El inventario actual de Storage tiene cero objetos en los dos buckets observados, pero esto no elimina la necesidad de un proceso de copia para cuando se carguen imágenes, hojas de vida o comprobantes.

No se activó `pg_cron`, no se creó una rama Supabase, no se ejecutó exportación, no se accedió a contraseñas ni secretos y no se restauró ni pausó el proyecto.
