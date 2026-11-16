# Auditoría de consentimiento y tratamiento de datos — 16 nov 2026

## Alcance

Revisión de solo lectura de los flujos de registro de clientes, checkout, postulaciones a vacantes, avisos legales y funciones de Supabase en la rama `correcciones-funcionales`.

Se revisaron `cuenta.html`, `cuenta.js`, `index.html`, `app.js`, `supabase/functions/create-public-order/index.ts`, `supabase/functions/create-job-application/index.ts` y la estructura previamente auditada de `job_applications`.

No se modificaron los formularios, las tablas, las políticas, los usuarios ni los datos. No se ejecutó SQL de escritura ni se desplegó ninguna función.

## Resultado ejecutivo

Los avisos legales existen, pero aún son textos de prototipo con datos obligatorios del responsable sin completar. Además, los flujos reales ya procesan pedidos y postulaciones, por lo que algunas frases del aviso de privacidad están desactualizadas.

Se encontraron dos problemas de implementación especialmente importantes:

1. **Checkout:** el formulario obliga visualmente a marcar una casilla de autorización, pero el código no incluye esa aceptación en el payload que se envía a `create-public-order`. La Edge Function tampoco exige ni registra la autorización. Por tanto, el consentimiento se queda en el navegador y no existe evidencia verificable de que el cliente lo haya otorgado.
2. **Registro de clientes:** el formulario permite crear una cuenta sin mostrar un aviso ni una casilla de autorización asociada al tratamiento de datos personales. El registro envía nombre y correo a Supabase Auth sin una aceptación registrada de la política o de sus finalidades.

La postulación a vacantes tiene una casilla obligatoria y la Edge Function rechaza `privacy_consent !== true`, pero el registro de postulaciones conserva únicamente el booleano. No se observó evidencia persistente de fecha/hora, versión del aviso ni texto aceptado.

## Hallazgos por flujo

### 1. Registro e inicio de sesión de clientes

**Observado**
- `cuenta.html` presenta nombre, correo y contraseña, pero no muestra un enlace al aviso de privacidad junto al registro ni una casilla de autorización.
- `cuenta.js` ejecuta `client.auth.signUp()` con `display_name` y correo de redirección. No envía versión de política ni un dato de aceptación.
- El trigger de Auth crea el perfil, pero no registra consentimiento de privacidad.

**Riesgo**
- La persona puede crear una cuenta sin que el flujo deje constancia de que recibió información clara sobre el responsable, finalidades, derechos y canal de atención.
- No debe suponerse que aceptar términos de uso equivale automáticamente a autorizar cualquier finalidad de tratamiento.

**Corrección necesaria**
- Mostrar el aviso de privacidad y tratamiento de datos antes del registro.
- Solicitar aceptación expresa cuando corresponda, sin casilla premarcada.
- Separar finalidades necesarias para administrar la cuenta de finalidades opcionales, como publicidad o comunicaciones promocionales.
- Guardar evidencia verificable: usuario, fecha/hora del servidor, versión exacta del aviso, finalidades aceptadas y canal/origen del consentimiento. No guardar contraseñas ni tokens.
- Definir qué sucede cuando la persona no acepta: no crear la cuenta si la autorización es necesaria para esa operación; permitir únicamente las funciones que no requieran ese tratamiento cuando sea viable.

### 2. Checkout y creación de pedidos

**Observado**
- `index.html` muestra una casilla `privacyConsent` requerida en el formulario de checkout y enlaza visualmente la Política de privacidad.
- El manejador de `#checkoutForm` construye `checkoutPayload` con negocio, nombre, teléfono, dirección, método de pago y productos, pero no incluye `privacyConsent`, versión de política ni finalidades.
- `create-public-order/index.ts` valida los datos del pedido y crea el pedido mediante RPC; no exige ni registra una autorización de privacidad.
- La política de privacidad aún afirma que el formulario de pedido no guarda ni transmite los datos y que la casilla solo muestra una vista previa. Esa descripción ya no coincide con el flujo de pedidos implementado en esta rama.
- El texto legal mantiene campos `[COMPLETAR]` para responsable, identificación, domicilio y correo de privacidad.

**Riesgo**
- La casilla del navegador no ofrece prueba de autorización en el servidor y se puede omitir llamando directamente a la función.
- La política describe incorrectamente el tratamiento real: el checkout sí transmite datos y registra pedidos.
- No queda evidencia de la versión del aviso que se mostró al cliente cuando realizó el pedido.

**Corrección necesaria**
- Actualizar la política para describir el flujo real y los destinatarios que realmente reciben datos.
- Enviar la aceptación y versión del aviso junto con la solicitud de pedido.
- Validar la aceptación en servidor, no solo en HTML/JavaScript.
- Registrar la evidencia de forma atómica con el pedido, o en una tabla de consentimientos con referencia al pedido y una transacción que impida crear el pedido si falla el registro requerido.
- No usar la autorización de pedido para habilitar publicidad. La promoción debe ser opcional, separada y revocable.
- Antes de producción, definir si el negocio vendedor y MiEje Market actúan como responsables independientes, encargados u otras figuras según el flujo contractual y real. No afirmar una distribución legal de roles sin revisión jurídica.

### 3. Postulaciones a vacantes y hojas de vida

**Observado**
- El formulario generado en `app.js` incluye una casilla obligatoria: “Autorizo el tratamiento de mis datos para gestionar esta postulación”.
- La casilla no enlaza directamente el aviso de privacidad ni muestra quién recibirá la postulación, cuánto tiempo se conservará la hoja de vida o cómo ejercer derechos.
- `create-job-application/index.ts` exige que `privacy_consent === true` antes de enviar la postulación.
- La función transmite el booleano a `submit_public_job_application`.
- La auditoría previa de la tabla `job_applications` encontró `privacy_consent boolean`, sin `consent_at` ni versión de política. No se ha demostrado una evidencia temporal/versionada del consentimiento.
- La hoja de vida se almacena en el bucket privado `job-applications-private`; el flujo de carga y el de envío son etapas distintas.

**Riesgo**
- La persona no recibe suficiente información contextual justo antes de entregar datos de contacto, respuestas y hoja de vida.
- Un booleano por sí solo no permite reconstruir qué texto y qué versión se aceptaron ni cuándo.
- La carga del archivo puede ocurrir antes de que la postulación se envíe; el aviso debe informar este flujo y su caducidad/limpieza.

**Corrección necesaria**
- Incluir un enlace visible al aviso de privacidad para postulantes.
- Informar el nombre del negocio que publica la vacante, el destinatario de la postulación, las finalidades, los datos recogidos, el tratamiento de la hoja de vida, el periodo/criterio de conservación y el canal para ejercer derechos.
- Registrar fecha/hora del servidor, versión del aviso, finalidades y referencia de postulación junto con la autorización.
- Mantener el consentimiento limitado a la gestión de esa postulación. Cualquier conservación para futuras vacantes o contacto promocional debe ser opcional, separada y con plazo definido.
- Verificar que el negocio solo pueda consultar postulaciones de sus vacantes y que el equipo técnico no acceda a hojas de vida salvo necesidad operativa y autorización documentada.
- Mantener la limpieza de cargas incompletas y objetos huérfanos sin borrar postulaciones válidas.

### 4. Avisos legales publicados

**Observado**
- `app.js` contiene Política de privacidad, Tratamiento de datos personales y Términos y condiciones.
- Los avisos contienen campos de identidad y contacto del responsable marcados `[COMPLETAR]`.
- La Política de privacidad dice que MiEje Market está en fase de prototipo y que el formulario no guarda ni transmite datos. Esa afirmación no coincide con el checkout y postulaciones implementados.
- El apartado de compartir información deja pendiente explicar si los datos se comparten con proveedores, servicios de pago, logística o comercios participantes.
- El apartado de cookies dice que no hay panel de consentimiento y deja la evaluación de analítica/publicidad para antes de añadir esas tecnologías.
- El aviso de tratamiento de datos explica autorización previa, derechos y finalidades de forma general, pero mantiene datos del responsable sin completar.
- Los textos no muestran una fecha de vigencia/versionado operativo que se registre junto a cada aceptación.

**Riesgo**
- No se debe presentar como política final un documento que todavía contiene campos pendientes y declaraciones incompatibles con la operación.
- La persona no puede saber con claridad quién responde por sus datos ni a qué canal acudir.
- La información general no permite identificar el flujo concreto para clientes, postulantes, comercios y proveedores.

**Corrección necesaria**
- Completar nombre/razón social, identificación cuando aplique, domicilio y canal de privacidad del responsable real.
- Definir el mapa de datos: qué recoge MiEje Market, qué recibe cada comercio, qué procesadores/proveedores intervienen, para qué, dónde se almacena y quién puede acceder.
- Diferenciar clientes, postulantes, administradores/empleados de negocios y visitantes.
- Publicar versión y fecha de vigencia; conservar las versiones anteriores para interpretar consentimientos históricos.
- Sustituir toda frase que diga que no se guardan/transmiten datos si el flujo correspondiente ya está activo.
- Revisar las finalidades y los mecanismos con asesoría jurídica colombiana antes de activar producción.

### 5. Publicidad, cookies y finalidades opcionales

**Observado**
- El aviso distingue correctamente que la autorización para tratamiento no debe confundirse con publicidad opcional.
- No se encontró en los formularios revisados una casilla de marketing, ni debe añadirse una casilla premarcada.
- La política declara que el prototipo no tiene panel de cookies, pero no se hizo un análisis de red completo de scripts de terceros en esta auditoría.

**Pendiente**
- Inventariar cookies, almacenamiento local, analítica, píxeles y servicios de terceros efectivamente cargados.
- Clasificar tecnologías necesarias y no necesarias con asesoría legal y técnica.
- Si se incorporan finalidades promocionales, usar autorización separada, opcional y con mecanismo sencillo para retirar la aceptación.
- No afirmar que no se usan cookies/seguimiento hasta completar la revisión técnica del navegador y de las solicitudes de red.

## Modelo recomendado de evidencia de autorización

La implementación futura debe conservar, como mínimo:
- identificador de la persona cuando exista cuenta; en compras de invitado, referencia segura del pedido;
- finalidad concreta y separada;
- versión inmutable del aviso y/o identificador/hash del texto mostrado;
- fecha/hora generada en servidor;
- acción afirmativa y origen del consentimiento;
- referencia a pedido, cuenta o postulación;
- registro de revocación cuando aplique.

No debe almacenarse información innecesaria, contraseñas, JWT, claves API ni documentos completos dentro de la tabla de consentimientos.

## Prioridad de corrección

1. **Crítica antes de activar checkout real:** corregir el vacío entre casilla de privacidad, payload, validación de servidor y evidencia del consentimiento.
2. **Crítica antes de aceptar registros reales:** completar aviso de privacidad y autorización del registro de clientes.
3. **Alta antes de abrir postulaciones reales:** versionar y fechar el consentimiento de postulantes y enlazar el aviso específico.
4. **Alta antes de producción:** completar identidad/contacto del responsable y mapa de destinatarios/proveedores.
5. **Media:** inventario técnico de cookies y tecnologías de seguimiento; revisar antes de incorporar herramientas de analítica o publicidad.

## Matriz de pruebas pendiente

- Registro sin aceptación: debe rechazar la operación cuando la autorización sea requerida.
- Registro con aceptación: debe guardar versión y fecha de servidor.
- Alterar el payload desde fuera del navegador: no debe permitir omitir la validación.
- Checkout sin consentimiento: la Edge Function debe rechazarlo aunque se llame directamente.
- Checkout con consentimiento: el pedido y la evidencia deben persistir juntos o fallar juntos.
- Reintento idempotente: no debe duplicar pedido ni evidencia de autorización.
- Postulación sin consentimiento: la función ya valida el booleano; falta probar que también se guarden fecha y versión.
- Postulación con CV y sin CV: comprobar que ambos caminos registren la misma evidencia de consentimiento.
- Cambio de versión de política: nuevas aceptaciones deben referenciar la versión nueva; las antiguas deben seguir identificando el texto aceptado.
- Retiro de una finalidad opcional: debe detener esa finalidad sin afectar la gestión del pedido o postulación ya solicitados.
- Acceso a hojas de vida: comprobar aislamiento entre negocios y ausencia de acceso público.

## Estado

- **Revisado:** formularios de registro, checkout y postulaciones; payloads y validaciones de las Edge Functions; avisos legales en `app.js`; estructura de consentimiento de postulaciones conocida por auditoría previa.
- **Hallazgos documentados:** falta de consentimiento verificable en registro y checkout; evidencia incompleta en postulaciones; avisos legales con placeholders y texto desactualizado.
- **Corregido en código:** nada en esta auditoría.
- **Pendiente de implementación:** formularios, payloads, validación servidor, tabla/estructura de evidencias, versionado de avisos y actualización de textos.
- **Pruebas:** no ejecutadas. No se declara ningún flujo aprobado.

## Límites de seguridad y publicación

Este documento se crea únicamente en `correcciones-funcionales`. No se cambió código funcional ni datos, no se ejecutó SQL de escritura, no se desplegaron funciones, no se modificó Auth/Storage, no se fusionó ningún PR, no se modificó `main` y no se publicó GitHub Pages.
