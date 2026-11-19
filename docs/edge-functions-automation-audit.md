# Auditoría de Edge Functions y procesos automáticos

**Proyecto:** MiEje Market Independiente  
**Rama de código:** `correcciones-funcionales`  
**Proyecto Supabase contrastado:** `cqixlrwbqatbhzmpygiz`  
**Fecha:** 19 de noviembre de 2026  
**Alcance:** autenticación de funciones, autorización por rol, validación de solicitudes, rate limiting, uso de secretos, despliegues, tareas programadas y registros de auditoría.  
**Método:** revisión estática de la rama, consulta de solo lectura a funciones desplegadas y metadatos SQL. No se consultaron valores de secretos, no se ejecutaron migraciones y no se desplegaron funciones.

## 1. Resumen ejecutivo

La auditoría encontró una diferencia importante entre el código de la rama y el que está desplegado en Supabase. Varias correcciones ya preparadas en GitHub no están activas en el proyecto Supabase.

Hallazgos prioritarios:

1. **Seguimiento público desactualizado:** la función desplegada `track-public-order` versión 1 devuelve el total del pedido y el texto de seguimiento sin el filtrado aplicado en la rama. La rama ya elimina el total, limita el texto y aplica cabeceras contra caché, pero todavía no implementa un límite persistente de consultas.
2. **Checkout desactualizado:** `create-public-order` versión 3 no contiene la versión de consentimiento de privacidad ni la idempotencia que sí están en la rama. La función desplegada todavía acepta `X-Forwarded-For` como alternativa de IP.
3. **Postulaciones desactualizadas:** `create-job-application` versión 2 no valida la versión de consentimiento, usa una alternativa de IP controlable por el cliente y fija una expiración de 30 minutos en lugar de leer la expiración real del token firmado. La rama ya corrige esos puntos y limita el cuerpo a 64 KB.
4. **Acceso técnico desactualizado:** `technical-business-management` versión 6 no aplica la comprobación MFA AAL2 que ya está en la rama. La rama también limita el cuerpo de solicitud a 64 KB.
5. **Limpieza automática sin desplegar:** `cleanup-job-application-data` existe en la rama, pero no aparece entre las funciones activas de Supabase. La extensión `pg_cron` no está instalada y no se encontró `cron.job`; por tanto, no hay evidencia de un programador SQL que ejecute la limpieza.
6. **Configuración pública no desplegada:** `get-platform-public-settings` existe en la rama, pero no aparece en la lista de funciones activas.
7. **Error en métodos de pago públicos:** el código desplegado de `get-public-storefront` no incluye `id` en su consulta, pero después intenta devolver `method.id`. La rama ya incluye esa columna.
8. **Auditoría incompleta:** `audit_logs` tiene cero filas en la consulta realizada. Además, el rol `service_role` conserva UPDATE, DELETE y TRUNCATE, y no se encontró una protección append-only en la configuración activa revisada.

**Dictamen:** no se debe considerar que las correcciones de la rama están funcionando en producción. Primero hay que preparar un entorno de ensayo, aplicar sus migraciones en el orden documentado, desplegar versiones coordinadas y ejecutar pruebas de seguridad. No desplegar directamente sobre el proyecto activo.

## 2. Funciones activas observadas en Supabase

| Función | Versión activa | JWT del gateway | Estado |
|---|---:|---:|---|
| `resolve-my-access` | 2 | Requerido | Activa |
| `create-public-order` | 3 | No requerido | Activa |
| `technical-business-management` | 6 | Requerido | Activa |
| `track-public-order` | 1 | No requerido | Activa |
| `get-public-storefront` | 2 | No requerido | Activa |
| `create-job-application` | 2 | No requerido | Activa |
| `cleanup-job-application-data` | — | — | No desplegada |
| `get-platform-public-settings` | — | — | No desplegada |

Las funciones públicas con `verify_jwt=false` deben validar sus propias entradas y controles de abuso. Las funciones privadas con JWT requerido deben verificar además el usuario real, el rol y el alcance de la operación. El valor de `verify_jwt` por sí solo no demuestra autorización.

## 3. Diferencias entre el código desplegado y la rama

### 3.1 Checkout — `create-public-order`

**Desplegado:** versión 3.

- No valida `privacy_consent_version`.
- No contiene la lógica de idempotencia presente en la rama.
- Acepta `cf-connecting-ip` o el primer valor de `x-forwarded-for`.
- Usa el flujo anterior de limitación y creación del pedido.

**Rama:**
- exige `privacy_consent=true` y la versión `privacy-2026-11-19-v1`;
- valida el token de sesión del cliente cuando se envía y obtiene el usuario desde Auth;
- rechaza perfiles bloqueados;
- normaliza UUID, valida cantidades y evita productos duplicados;
- utiliza idempotencia y reserva transaccional del límite;
- solo acepta `cf-connecting-ip`, falla cerrado si no existe y limita el cuerpo a 64 KB;
- devuelve respuestas con `no-store`, `nosniff` y `no-referrer`.

**Acción requerida:** desplegar únicamente después de que el staging tenga las RPC y columnas que exige el código actual. La rama no debe apuntarse a una base que solo tenga el esquema anterior.

### 3.2 Seguimiento — `track-public-order`

**Desplegado:** versión 1.

La función consulta y devuelve `orders.total` y el valor original de `delivery_tracking`. No valida el estado con una lista permitida ni limita el tamaño del cuerpo.

**Rama:**
- devuelve únicamente número de pedido, estado, fechas, nombre del negocio y referencia de seguimiento;
- omite el importe;
- limita el cuerpo a 2 KB;
- valida el formato UUID y el estado permitido;
- limpia caracteres de control y limita la referencia a 500 caracteres;
- añade cabeceras para evitar caché y filtración por Referer.

**Pendiente:** añadir un limitador persistente para consultas de seguimiento. El token UUID funciona como credencial de posesión, pero no reemplaza un límite de solicitudes. No reutilizar un limitador de checkout sin diseñar y verificar sus claves, ventana y efectos.

### 3.3 Postulaciones — `create-job-application`

**Desplegado:** versión 2.

- No exige versión de consentimiento.
- Usa `X-Forwarded-For` como alternativa de IP.
- Fija una expiración SQL de 30 minutos sin comprobar la expiración real del token de carga.
- No limita el tamaño total del cuerpo antes de parsear JSON.

**Rama:**
- exige `job-application-2026-11-19-v1` tanto al pedir la carga como al enviar la postulación;
- acepta solo `cf-connecting-ip` y falla cerrado si no está disponible;
- separa contadores para `request_upload` y `submit`;
- valida el vencimiento JWT del token de Storage y establece la sesión SQL cinco minutos después;
- limita respuestas personalizadas y el cuerpo total a 64 KB;
- verifica una firma binaria básica del CV antes de registrar la postulación;
- usa cabeceras `no-store`, `nosniff` y límite de caché.

**Pendiente:** análisis antimalware o cuarentena antes de que un administrador abra el archivo. La firma binaria básica no demuestra que un documento esté libre de contenido malicioso.

### 3.4 Panel técnico — `technical-business-management`

**Desplegado:** versión 6. La función exige JWT y obtiene el usuario mediante Auth, pero la fuente activa consultada no contiene la comprobación MFA AAL2 que sí aparece en la rama.

**Rama:**
- verifica la sesión real mediante `auth.getUser(token)`;
- exige MFA AAL2 al propietario técnico antes de ejecutar acciones;
- comprueba `profiles.is_blocked` y el rol de propietario;
- valida la membresía al registrar el acceso a paneles de negocio;
- usa RPC transaccionales para operaciones administrativas sensibles;
- limita el cuerpo JSON a 64 KB y exige un objeto JSON.

**Pendiente:** aplicar límite de solicitudes por usuario/IP y definir una política de registro de acciones sensibles. El MFA reduce el riesgo de acceso indebido, pero no reemplaza el control de frecuencia ni la auditoría.

### 3.5 Métodos de pago públicos — `get-public-storefront`

En el código desplegado, la consulta de `business_payment_methods` no incluye la columna `id`, pero la respuesta intenta devolver `method.id`. Eso puede generar identificadores vacíos en el selector de métodos de pago.

La rama ya consulta `id,business_id,method_code,display_name,public_instructions,sort_order`. También limita la lista de negocios a 200 UUID y solo devuelve métodos habilitados de negocios activos.

### 3.6 Otras funciones

- `resolve-my-access` está desplegada en versión 2 y verifica el token con `auth.getUser`, bloquea perfiles suspendidos y devuelve solo membresías activas. Se observó una diferencia entre la fuente desplegada y la rama; debe probarse el contrato de respuesta antes de actualizar el cliente.
- `get-platform-public-settings` está en la rama y en `supabase/config.toml`, pero no se encontró desplegada en el proyecto activo. Verificar primero si la interfaz la invoca y si la tabla de configuración existe en staging.

## 4. Procesos programados y limpieza

Se revisó el proyecto Supabase activo en modo de solo lectura:

- `pg_cron` no está instalado.
- `cron.job` y `cron.job_run_details` no existen.
- `cleanup-job-application-data` no aparece entre las funciones desplegadas.
- La función de limpieza de la rama requiere el secreto separado `JOB_APPLICATION_CLEANUP_SECRET` en el encabezado `x-cleanup-secret`. La clave `SUPABASE_SERVICE_ROLE_KEY` permanece como credencial interna del servidor.
- El proceso limpia sesiones temporales vencidas, objetos sin postulación asociada y filas antiguas del limitador. Conserva el CV si la postulación existe.

**Consecuencia:** no hay evidencia de que las sesiones temporales y archivos huérfanos se estén limpiando automáticamente en el proyecto activo.

**Diseño pendiente para staging:**
1. Configurar un programador privado (Supabase Cron u otro scheduler controlado).
2. Guardar el secreto de limpieza en un almacén seguro del servidor, nunca en el repositorio ni en código del navegador.
3. Ejecutar la función con un lote pequeño y revisar el resultado.
4. Reintentar lotes con errores sin eliminar filas que deban conservarse.
5. Registrar hora, resultado, contadores y errores sin incluir nombres, teléfonos, correos, tokens ni rutas completas de CV.
6. Verificar que no existan dos ejecuciones concurrentes que procesen el mismo lote.

No se debe incluir un secreto literal en una migración SQL ni en un comando cron visible en el repositorio. La configuración del scheduler debe usar un secreto almacenado de forma segura y tener permisos mínimos.

## 5. Límites de solicitudes y CORS

- Las funciones públicas revisadas usan CORS con `Access-Control-Allow-Origin: *`. CORS no sustituye autenticación ni autorización. En las funciones privadas, la protección real debe continuar siendo el JWT, la comprobación de Auth, el rol y el alcance del recurso.
- Checkout y seguimiento ya limitan el cuerpo en la rama a 64 KB y 2 KB, respectivamente.
- En esta revisión se añadieron límites de 64 KB y validación de objeto JSON a las solicitudes de `technical-business-management` y `create-job-application`.
- `get-public-storefront` limita la lista a 200 UUID, pero no se observó un limitador persistente de consultas.
- `track-public-order` no tiene limitador persistente en la rama.
- Las funciones públicas de consulta deben tener límites de frecuencia y tamaño adecuados para evitar abuso de recursos.

## 6. Auditoría de acciones

La consulta de solo lectura encontró:

- La tabla `audit_logs` existe, pero tiene cero filas.
- `authenticated` tiene permiso SELECT.
- `service_role` conserva INSERT, SELECT, UPDATE, DELETE y TRUNCATE.
- La policy SELECT permite lectura al propietario técnico, administrador del negocio asociado o actor del registro.
- No se encontró un trigger de inmutabilidad que impida modificar o borrar registros.

**Dictamen:** la tabla existe, pero no se puede considerar un historial append-only. Antes de cerrar la auditoría se debe definir qué eventos se registran, quién puede consultarlos, cuánto tiempo se conservan y cómo se impide que una operación ordinaria altere evidencia histórica. El acceso técnico a la auditoría debe resolverse mediante un endpoint controlado, no mediante lectura global general del perfil técnico.

## 7. Cambios realizados en la rama durante esta revisión

Se actualizaron:

- `supabase/functions/technical-business-management/index.ts`: lectura del cuerpo con límite de 64 KB y validación de objeto JSON.
- `supabase/functions/create-job-application/index.ts`: lectura del cuerpo con límite de 64 KB y validación de objeto JSON.

Estos cambios se guardaron en `correcciones-funcionales`. No se desplegaron ni se probaron con Deno o en staging.

## 8. Plan de validación antes de producción

1. Crear/usar un proyecto de staging aislado.
2. Aplicar las migraciones y RPC requeridas por el código de la rama en el orden del README.
3. Configurar secretos de servidor y del programador fuera del repositorio.
4. Desplegar primero las funciones privadas y probar JWT, perfil bloqueado, rol, MFA AAL2 y acceso de otro negocio.
5. Probar checkout con consentimiento ausente/incorrecto, sesión válida, sesión vencida, usuario bloqueado, clave idempotente repetida, IP ausente y rate limit excedido.
6. Probar seguimiento sin token, UUID inválido, token desconocido, pedido válido, texto de seguimiento largo y límites de frecuencia; verificar que nunca devuelva importes ni datos del cliente.
7. Probar postulaciones sin consentimiento, versión anterior, archivo excedido, formato no permitido, token vencido, negocio suspendido y carga incompleta.
8. Ejecutar una limpieza de ensayo con archivos asociados y huérfanos; comprobar que solo se eliminen los temporales elegibles.
9. Comprobar los registros de auditoría, sus permisos y la resistencia a UPDATE/DELETE.
10. Comparar las versiones activas con los commits aprobados antes de autorizar el despliegue final.

**No se debe desplegar ni ejecutar migraciones en el proyecto activo sin autorización expresa.**
