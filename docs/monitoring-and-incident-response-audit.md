# Auditoría de monitoreo, errores y respuesta ante incidentes

**Proyecto:** MiEje Market Independiente  
**Supabase project ref:** `cqixlrwbqatbhzmpygiz`  
**Rama:** `correcciones-funcionales`  
**Fecha:** 19 de noviembre de 2026  
**Método:** lectura del código de la rama, inventario de Edge Functions y consultas de logs/SQL de solo lectura.

## 1. Dictamen

La plataforma cuenta con manejo básico de errores en el navegador y con mensajes de error en varias Edge Functions, pero **no hay evidencia suficiente de un sistema integral de monitoreo y alertas operativas**.

Los principales vacíos son:
- Los errores se registran principalmente mediante `console.error` / `console.warn`, sin un identificador de correlación uniforme que conecte navegador, Edge Function, RPC y evento de auditoría.
- El inventario activo tiene seis Edge Functions; las versiones desplegadas no coinciden plenamente con las correcciones de la rama.
- En la ventana consultada de logs unificados solo aparecieron `postgres_logs` y `pgbouncer_logs`; no aparecieron fuentes `edge_logs` ni `function_edge_logs`. Esto no demuestra que las funciones no tengan errores: significa que esta consulta no permitió observar su telemetría.
- `audit_logs` sigue con cero filas y no acredita un historial operativo completo.
- `pg_cron` no está instalado; no hay automatización SQL demostrada para tareas de mantenimiento.
- No se encontró en el repositorio un workflow de monitoreo, alertas o reporte automático de salud.

## 2. Estado de Supabase observado

El proyecto estaba `ACTIVE_HEALTHY`, con PostgreSQL 17.11.0.003.

Edge Functions activas:
| Función | Versión | JWT |
|---|---:|---|
| `create-job-application` | 2 | No |
| `track-public-order` | 1 | No |
| `create-public-order` | 3 | No |
| `resolve-my-access` | 2 | Sí |
| `technical-business-management` | 6 | Sí |
| `get-public-storefront` | 2 | No |

La función `cleanup-job-application-data` está en la rama, pero no aparece en el inventario desplegado.

### Logs consultados

Ventana predeterminada de las últimas 24 horas de la consulta:

| Fuente disponible | Eventos | Coincidencias con palabras error/fatal/panic | Coincidencias warning/warn |
|---|---:|---:|---:|
| `pgbouncer_logs` | 69 | 0 | 0 |
| `postgres_logs` | 14 | 0 | 0 |

No aparecieron fuentes Edge Functions en el resultado. El conteo se basa en palabras dentro de `event_message`, no en un clasificador de severidad. No equivale a una prueba de ausencia de errores. No se copiaron mensajes crudos para evitar exponer datos operativos o personales.

### Auditoría

La consulta de solo lectura devolvió cero filas en `public.audit_logs`. La tabla no puede utilizarse como evidencia de que todas las acciones críticas están siendo registradas. La rama contiene un borrador append-only, pero no está aplicado en el proyecto activo.

## 3. Hallazgos en el código

### 3.1 Navegador y paneles

`panel-live.js`:
- Presenta mensajes cuando falla la validación de sesión, acceso, carga de pedidos, reportes, gastos, comprobantes, productos e inventario.
- Usa `console.error` y `console.warn` para diagnóstico local.
- No se identificó un mecanismo uniforme para enviar errores de cliente a un colector central.
- No se identificó un ID de correlación compartido entre acción de UI, llamada a función y transacción.

Esto permite mostrar errores al usuario, pero no garantiza que el equipo técnico pueda reconstruir un incidente ocurrido en otro navegador.

### 3.2 Edge Functions

Las funciones revisadas capturan errores y devuelven respuestas HTTP apropiadas en varios flujos. Algunas escriben detalles con `console.error`, por ejemplo gestión técnica, checkout, postulaciones y limpieza.

Riesgos que deben controlarse:
- No registrar en logs nombres, teléfonos, correos, direcciones, tokens de seguimiento, JWT, secretos, CV ni cuerpos completos de solicitudes.
- Usar códigos de error internos estables y mensajes externos genéricos.
- Distinguir fallos esperados de validación (4xx), fallos de autorización (401/403), conflictos (409), límites (429) y fallos inesperados (5xx).
- Registrar el identificador de solicitud y la etapa de proceso, no datos personales.
- Evitar que un error al escribir `audit_logs` o notificaciones oculte el resultado real de una operación transaccional.

### 3.3 Diferencia entre rama y producción

Las funciones activas son versiones 2, 1, 3, 2, 6 y 2, respectivamente. Los cambios de seguridad y validación de la rama todavía no están desplegados. El monitoreo debe identificar la versión y el commit desplegados; no asumir que el código de GitHub es el que atiende las solicitudes.

## 4. Riesgos operativos prioritarios

1. **Error silencioso o difícil de rastrear:** un cliente informa que no se creó un pedido, pero no hay identificador común para seguir la operación.
2. **Falla parcial:** una operación puede escribir datos en un paso y fallar al registrar auditoría o una acción posterior si el flujo no es transaccional.
3. **Telemetría incompleta:** la consulta de logs no devolvió fuentes de Edge Functions.
4. **Sin alerta demostrada:** no hay evidencia en el repositorio de alertas ante aumento de 5xx, errores de autenticación, fallos de checkout o fallos de tareas.
5. **Auditoría vacía:** no se dispone de una línea de tiempo confiable de acciones sensibles.
6. **Mantenimiento no programado:** no está instalado `pg_cron`, y la función de limpieza de CV no está desplegada ni tiene scheduler acreditado.
7. **Despliegue no correlacionado:** las versiones activas deben vincularse a commits y pruebas aprobadas.

## 5. Controles recomendados

### Registro estructurado

Definir un formato mínimo común:
- `event_id`: UUID generado por servidor.
- `request_id`: identificador de la solicitud.
- `operation`: nombre estable de operación.
- `component`: browser, edge_function, rpc o database.
- `severity`: info, warning, error, critical.
- `result`: success, rejected, failed.
- `error_code`: código interno estable, si aplica.
- `business_id`: solo cuando sea necesario y permitido.
- `actor_id`: identificador interno mínimo, sujeto a política de acceso/retención.
- `duration_ms`: duración.
- `deployment_version` y `commit_sha`.

No incluir PII, credenciales, tokens, contenido de CV ni el cuerpo completo de solicitudes. En errores SQL, registrar el código y contexto mínimo saneado; restringir el acceso a logs.

### Alertas mínimas

Configurar alertas verificables para:
- incremento de respuestas 5xx en Edge Functions;
- fallos de checkout y aumento anormal de conflictos/duplicados;
- fallos de login, MFA o resolución de acceso;
- errores repetidos en operaciones de pago, cancelación o reembolso;
- fallos de Storage al subir o descargar archivos;
- limpieza programada fallida o sin ejecución dentro de la ventana esperada;
- ausencia de backup reciente;
- crecimiento de errores de PostgreSQL o conexiones agotadas.

Cada alerta debe indicar responsable, umbral, ventana de evaluación, canal, horario y procedimiento de escalamiento. No fijar umbrales arbitrarios sin medir una línea base.

### Identificador de correlación

Generarlo en servidor cuando no venga uno válido; propagarlo en cabeceras/respuestas y en logs de cada etapa. Nunca confiar en el valor del cliente para autorización. Un ID de correlación es solo para diagnóstico.

### Incidentes

Definir un procedimiento:
1. Detectar y clasificar severidad.
2. Identificar función, versión, commit y ventana temporal.
3. Preservar logs relevantes con acceso limitado.
4. Contener el problema sin borrar evidencia ni datos.
5. Verificar pedidos, pagos, inventario y Storage afectados.
6. Aplicar corrección primero en staging.
7. Recuperar o reconciliar operaciones idempotentemente.
8. Comunicar a negocios afectados según impacto.
9. Documentar causa raíz, acciones y prevención.

## 6. Pruebas de aceptación antes de producción

- [ ] Provocar en staging un error controlado de validación y comprobar respuesta 4xx sin filtrar detalles internos.
- [ ] Provocar un fallo inesperado y confirmar registro estructurado 5xx.
- [ ] Seguir un mismo `request_id` desde llamada cliente hasta Edge Function/RPC.
- [ ] Confirmar que logs no contienen PII, secretos, JWT ni contenido de CV.
- [ ] Confirmar que las alertas llegan al responsable.
- [ ] Probar operación fallida a mitad de proceso y verificar rollback o compensación.
- [ ] Comprobar que auditoría captura acciones sensibles sin duplicar eventos.
- [ ] Verificar versión y commit de cada función desplegada.
- [ ] Probar detección de limpieza programada fallida.
- [ ] Ensayar el procedimiento de incidente en entorno aislado.

## 7. Estado y límites

- Proyecto consultado solo en lectura.
- No se modificaron Edge Functions ni tablas.
- No se enviaron solicitudes de prueba a clientes.
- No se generaron alertas ni se cambiaron ajustes de observabilidad.
- El conteo de logs corresponde a una ventana de 24 horas y a las fuentes devueltas por el servicio.
- No se puede concluir que no existan errores históricos ni alertas configuradas fuera del repositorio/herramientas consultadas.
- La auditoría queda abierta hasta instrumentar, configurar alertas y probar el flujo en staging.
