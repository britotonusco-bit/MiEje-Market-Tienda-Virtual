# Auditoría de Edge Functions y procesos automáticos

**Fecha:** 16 de noviembre de 2026  
**Proyecto revisado:** MiEje Market Independiente  
**Proyecto Supabase:** `cqixlrwbqatbhzmpygiz`  
**Rama de correcciones:** `correcciones-funcionales`

## Alcance y límites

Se revisaron las seis Edge Functions activas, sus versiones, la implementación propuesta en la rama, las RPC que invocan y los procesos de invitación, postulaciones, seguimiento de pedidos y limpieza. Las consultas a Supabase fueron de solo lectura.

No se ejecutaron migraciones, no se cambiaron permisos ni secretos, no se desplegaron Edge Functions y no se publicó el sitio. Los cambios descritos como corregidos en la rama siguen siendo borradores hasta su validación en un entorno de pruebas.

## Estado de las funciones activas

| Función | Versión activa | JWT requerido | Resultado |
|---|---:|---|---|
| `technical-business-management` | 6 | Sí | Requiere MFA AAL2 y transacciones atómicas; la versión activa no aplica AAL2 |
| `create-public-order` | 3 | No | Checkout público con validaciones y límite por IP; sin idempotencia activa |
| `track-public-order` | 1 | No | Consulta pública por token de seguimiento |
| `resolve-my-access` | 2 | Sí | Verifica sesión, perfil y membresías activas |
| `get-public-storefront` | 2 | No | Expone métodos de pago públicos; tiene un error al devolver el ID |
| `create-job-application` | 2 | No | Postulación pública con carga firmada y límite por IP |

## Hallazgos

### EF-01 — Falta exigir MFA en la función técnica activa
**Severidad: alta. Estado: corregido solo en la rama.**

La versión activa 6 valida el JWT con `auth.getUser(token)`, comprueba el perfil y exige `platform_role = platform_owner`, pero no consulta el nivel de autenticación. Por tanto, una sesión de primer factor puede llegar a las acciones técnicas si el perfil tiene ese rol.

La versión de `correcciones-funcionales` incorpora `auth.mfa.getAuthenticatorAssuranceLevel(token)` y bloquea las acciones del propietario cuando `currentLevel` no es `aal2`. La firma con JWT es compatible con la documentación vigente de Supabase.

**Pendiente:** probar inscripción, desafío, sesión AAL1, sesión AAL2 y token renovado en staging. No basta con ocultar el panel en el navegador: la comprobación debe mantenerse en el servidor.

### EF-02 — La función pública de métodos de pago devuelve un ID indefinido
**Severidad: alta para el checkout. Estado: corregido solo en la rama.**

La versión activa 2 consulta `business_payment_methods` con las columnas `business_id,method_code,display_name,public_instructions,sort_order`, pero en la respuesta intenta devolver `method.id`. Como el ID no fue seleccionado, el valor devuelto es indefinido.

Esto puede impedir que el checkout identifique el método de pago elegido y que lo envíe correctamente al proceso de creación del pedido.

La versión de la rama incluye `id` en el SELECT. La corrección debe probarse con varios negocios y varios métodos habilitados, verificando que cada ID pertenece al negocio correspondiente.

### EF-03 — El checkout activo no tiene idempotencia
**Severidad: alta para la integridad de pedidos. Estado: preparado en la rama; no activo.**

La versión activa 3 llama a `consume_checkout_rate_limit` y después a `create_public_order`. La RPC activa bloquea filas de producto, valida inventario, crea pedido, ítems, costos históricos, descuenta inventario y registra auditoría dentro de una transacción. Esto protege la integridad de una sola ejecución.

Sin embargo, no hay una clave de idempotencia en el flujo activo. Si el cliente repite el envío por doble clic, recarga o reintento de red, puede terminar creando dos pedidos y descontando inventario dos veces.

La rama prepara `get_public_order_idempotent`, `reserve_checkout_rate_limit` y `create_public_order_idempotent`, junto con una clave por intento. La consulta de funciones en el proyecto activo confirmó que esas tres RPC todavía no existen allí. Por eso no se debe desplegar la Edge Function de la rama antes de instalar y verificar el paquete SQL completo en staging.

### EF-04 — Invitaciones y cambios técnicos pueden dejar operaciones parciales en la versión activa
**Severidad: alta. Estado: mejorado en la rama, pendiente de prueba integral.**

En la versión activa 6, la creación del negocio y su registro de auditoría son dos operaciones separadas. Si el negocio se crea y la inserción de auditoría falla, la función devuelve error aunque el negocio ya exista.

El flujo activo de invitación también combina varias operaciones separadas: búsqueda o creación de usuario en Auth, actualización del perfil, inserción de membresía e inserción de auditoría. Un fallo después de crear el usuario o después de insertar la membresía puede dejar una invitación o un acceso parcialmente configurado.

La rama reemplaza varias mutaciones por RPC transaccionales que verifican el rol técnico, el bloqueo global, el negocio activo, duplicados y auditoría. La búsqueda de usuario también evita asumir que un correo no existe cuando se alcanza el límite de páginas.

**Límite que permanece:** Auth y el envío de correo no forman parte de una transacción PostgreSQL. La rama informa si el correo se envió pero falló la asignación; aún se debe probar el reintento de la misma asignación, la cuenta creada sin membresía, el correo duplicado, la invitación vencida y la confirmación de correo. Conviene conservar un estado operativo claro para poder reconciliar esos casos sin duplicar cuentas ni accesos.

La consulta de solo lectura confirmó que las RPC nuevas usadas por la rama —incluidas `create_business_membership_assignment`, `create_technical_business_transactional`, `set_technical_business_status`, `suspend_business_membership` y `reactivate_business_membership`— no existen todavía en la base activa.

### EF-05 — Validación insuficiente del contenido de hojas de vida
**Severidad: alta por privacidad y seguridad de archivos. Estado: pendiente.**

La función activa 2 limita el tamaño declarado, extensión y MIME indicado por el navegador, y el bucket privado limita el tamaño máximo. Al enviar la postulación, verifica que el objeto exista y que su tamaño no exceda el límite.

No verifica la firma binaria real del archivo ni ejecuta análisis antimalware. La extensión y el MIME enviados por el navegador no demuestran que el contenido sea realmente PDF, DOC o DOCX.

**Medidas antes de producción:** mantener el bucket privado, no ejecutar ni previsualizar automáticamente archivos recibidos, restringir descargas al administrador autorizado, inspeccionar el contenido real y agregar análisis antimalware. Definir además retención y eliminación verificable de CV.

### EF-06 — Las respuestas personalizadas de la postulación no tienen límite de tamaño
**Severidad: media. Estado: pendiente.**

La Edge Function acepta `form_responses` como objeto JSON, pero no limita el tamaño serializado ni la cantidad/profundidad de sus campos. La RPC SQL activa también valida que sea un objeto, pero no establece un máximo para ese JSON.

Debe fijarse un límite total pequeño y documentado, además de validar el número de campos, longitud de claves y valores, y tipos admitidos. También se debe rechazar un cuerpo HTTP excesivo antes de procesarlo.

### EF-07 — El seguimiento público depende de un token secreto
**Severidad: media; diseño aceptable con controles adicionales.**

`track-public-order` no requiere JWT y busca un pedido por `public_tracking_token`. Devuelve número, estado, fechas, información de entrega, total y nombre del negocio; no devuelve nombre, teléfono ni dirección del cliente.

El token funciona como credencial de acceso al seguimiento. Debe generarse con suficiente entropía, no aparecer en registros ni URLs de analítica, y no debe ser reutilizable como identificador de modificación. Conviene añadir protección de abuso y probar que no se puede consultar un pedido con el ID interno o el número de pedido en lugar del token.

### EF-08 — La resolución de acceso es una respuesta de enrutamiento, no una autorización final
**Severidad: media.**

`resolve-my-access` verifica el JWT, el perfil no bloqueado y las membresías activas asociadas a negocios activos. Devuelve si el usuario es propietario de plataforma y las membresías disponibles.

Esa respuesta sirve para decidir qué panel mostrar, pero no debe considerarse autorización suficiente para mutaciones. Cada Edge Function y RPC debe volver a comprobar el rol, la membresía, el negocio activo y el alcance del recurso. La versión activa de la función técnica carece de AAL2, como se describe en EF-01.

### EF-09 — Limpieza automática de cargas de CV todavía no está operativa
**Severidad: media-alta para retención y almacenamiento. Estado: borrador de rama.**

La función `cleanup-job-application-data` no figura entre las funciones activas. La rama agrega una función protegida por el secreto independiente `JOB_APPLICATION_CLEANUP_SECRET`; la clave `SUPABASE_SERVICE_ROLE_KEY` se conserva únicamente para el cliente administrativo interno.

El SQL de limpieza agrega `list_expired_job_application_upload_sessions`, pero esa RPC tampoco existe en la base activa. El borrador procesa lotes de hasta 100 sesiones, conserva el CV cuando ya existe una postulación y elimina el objeto huérfano antes de borrar la sesión cuando no existe postulación. Si Storage falla, conserva la fila para reintentar.

**Pendiente:** configurar el secreto independiente en staging, probar autorización, lotes, reintentos, fallos parciales, sesiones consumidas y CV asociados a postulaciones. El proceso programado debe volver a invocarse mientras haya más registros que limpiar.

### EF-10 — Configuración pública de plataforma
**Severidad: baja si los campos siguen siendo públicos. Estado: solo rama.**

`get-platform-public-settings` es una función nueva de la rama y no está desplegada. Devuelve únicamente nombre, descripción, logo, imagen principal y WhatsApp de soporte. Es razonable que no requiera JWT si esos campos son deliberadamente públicos. No debe ampliarse para devolver datos financieros, secretos, datos de usuarios o ajustes internos.

## Procesos y límites de confianza

- Las funciones públicas de catálogo, seguimiento, checkout y postulaciones usan la clave de servicio en el servidor. Nunca debe trasladarse esa clave al navegador.
- Las funciones que usan `service_role` evitan RLS en sus consultas administrativas. Por eso cada operación debe validar explícitamente identidad, rol, negocio, estado y recurso.
- Las RPC `SECURITY DEFINER` activas revisadas tienen `search_path` vacío y permisos de ejecución restringidos a `service_role`. Mantener esta restricción y no otorgar ejecución a `anon` o `authenticated`.
- Las respuestas públicas deben contener solo los campos necesarios. Mantener CORS y validación de origen como defensa complementaria; CORS no reemplaza autenticación ni autorización.
- Los errores internos deben quedar en logs protegidos, sin tokens, claves, CV, datos completos de clientes ni encabezados de autorización.

## Pruebas obligatorias antes de habilitar los cambios

1. Técnico: usuario propietario con AAL1 debe recibir 403; con AAL2 debe poder ejecutar solo acciones técnicas autorizadas.
2. Invitaciones: correo nuevo, usuario existente, búsqueda incompleta, correo no enviado, Auth creado sin membresía, membresía duplicada, negocio suspendido y reintento después de error.
3. Negocios: creación, suspensión, reactivación y auditoría deben confirmarse o revertirse como una sola operación.
4. Catálogo: cada método de pago debe devolver un ID válido y perteneciente al negocio activo correcto.
5. Checkout: doble clic, reintento de red, misma clave con contenido diferente, inventario insuficiente, método deshabilitado durante la compra y dos pedidos concurrentes.
6. Postulaciones: carga válida, archivo con extensión/MIME falsos, archivo demasiado grande, sesión expirada, sesión reutilizada, respuesta JSON excesiva y CV privado entre negocios.
7. Seguimiento: token válido, token aleatorio inválido, datos devueltos mínimos y protección ante abuso.
8. Limpieza: objeto huérfano, postulación con CV, Storage temporalmente no disponible, lote lleno y secreto incorrecto.
9. Aislamiento: administrador del negocio A, administrador B, empleado y visitante deben recibir solo los datos y acciones correspondientes.

## Orden de corrección recomendado

1. Validar MFA AAL2 en la versión candidata del panel técnico y completar las pruebas de MFA.
2. Instalar y probar en staging las RPC transaccionales de administración antes de desplegar la Edge Function técnica candidata.
3. Corregir y probar el ID de los métodos de pago.
4. Aplicar y probar el paquete SQL de idempotencia antes de sustituir el checkout activo.
5. Limitar tamaño y estructura de postulaciones, inspeccionar CV y habilitar el proceso de limpieza.
6. Ejecutar la matriz completa de aislamiento, fallos parciales y reintentos.

## Referencias Supabase

- [MFA: getAuthenticatorAssuranceLevel](https://supabase.com/docs/reference/javascript/auth-mfa-getauthenticatorassurancelevel)
- [Guía de autenticación multifactor](https://supabase.com/docs/guides/auth/auth-mfa)
- [Changelog Supabase: cambios de Data API](https://supabase.com/changelog?tags=data+apis)
- [Changelog Supabase: cambios de Edge Functions](https://supabase.com/changelog?tags=edge+functions)

**Conclusión:** la rama contiene correcciones relevantes, pero no equivale a una implementación activa. La función técnica, el checkout idempotente, las RPC de administración y la limpieza automática dependen de cambios que todavía no están instalados en el proyecto activo. No se recomienda habilitar producción hasta disponer de staging y completar las pruebas indicadas.
