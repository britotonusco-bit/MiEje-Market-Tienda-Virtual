# Auditoría de soporte técnico y atención al cliente

**Fecha:** 19 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Alcance:** revisión estática de la rama y consultas de solo lectura a Supabase activo `cqixlrwbqatbhzmpygiz`.

## 1. Resultado general

La plataforma todavía no tiene un sistema interno de tickets, conversaciones persistentes ni asignación de casos de soporte. El contacto técnico está planteado como un enlace externo a WhatsApp. El asistente de cada tienda es una respuesta local y básica basada en datos del catálogo; no es un chatbot conectado a un proveedor de IA ni un canal de atención de reclamos.

No se debe presentar estas funciones como un sistema de soporte completo.

## 2. Soporte técnico global

En `panel-tecnico.html` existe una sección de soporte que obtiene el número global desde la Edge Function `get-platform-public-settings`, y abre `wa.me`.

Hallazgos:
- El número de soporte se obtiene desde `platform_public_settings.support_whatsapp`.
- La función de lectura selecciona únicamente nombre, descripción, logo, imagen principal y WhatsApp de soporte; no devuelve datos privados de clientes o negocios.
- El enlace abre WhatsApp fuera de MiEje Market.
- No existe ticket, número de caso, historial de conversación, asignación de técnico, prioridad, SLA, adjuntos ni cierre formal del caso.
- Las conversaciones externas no se registran automáticamente en `audit_logs`; el historial de auditoría no puede demostrar el contenido ni la resolución de esos chats.
- El endpoint de lectura no requiere JWT porque entrega configuración pública, pero debe devolver exclusivamente campos públicos.

### Estado de despliegue

La lista de Edge Functions activas en Supabase no incluye `get-platform-public-settings`. Tampoco se encontró `platform_public_settings` en el esquema público activo. Por tanto, el soporte global preparado en la rama depende de una migración y una función que aún no están instaladas en el proyecto activo.

El número de soporte puede estar configurado en la rama, pero no se debe afirmar que el enlace está operativo en producción hasta instalar y probar su dependencia.

## 3. Atención de clientes por negocio

La página pública muestra el WhatsApp configurado por el administrador del negocio y abre un enlace externo para contactar a la tienda.

Hallazgos:
- El número del negocio se expone como contacto público de la tienda, lo que es coherente con su finalidad comercial.
- Ese número debe ser un canal autorizado del negocio, no el teléfono privado de un empleado.
- La comunicación ocurre fuera de la plataforma y no se guarda como conversación interna.
- No hay tickets separados por negocio ni una bandeja de soporte dentro del panel del administrador.
- No se encontró una tabla de soporte, tickets, mensajes, chat o contacto en el esquema público activo.

Se añadió una advertencia al formulario de configuración para indicar que el WhatsApp puede hacerse público y que se debe utilizar un número autorizado.

## 4. Asistente básico de la tienda

El asistente en `app.js` procesa la pregunta en el navegador mediante reglas de texto y consulta la información que ya está cargada en el catálogo de la tienda.

La respuesta se agrega al DOM con `textContent`; no se encontró una llamada de red, persistencia de conversación ni envío del texto a una API externa en el manejador revisado.

Límites:
- Solo responde saludos, productos, precios, horario y ubicación registrada.
- No comprende solicitudes complejas ni puede abrir reclamos.
- No consulta pedidos, pagos, datos de clientes ni historial.
- No conserva conversaciones al recargar la página.
- No debe llamarse IA conectada ni soporte humano.

Se añadió un aviso visible que explica que es una ayuda básica, no gestiona pedidos ni reclamos y que el usuario no debe introducir contraseñas, códigos, datos de pago, teléfonos o direcciones personales.

## 5. Cambios realizados en la rama

1. `app.js`: aviso de alcance y privacidad para el asistente de tienda.
2. `panel-tecnico.html`: el enlace externo de soporte ahora incluye `rel="noopener noreferrer"` y avisa que WhatsApp no queda auditado, además de aclarar que no hay tickets ni seguimiento interno.
3. `panel-negocio.html`: aviso de que el WhatsApp del negocio es público y debe ser un canal autorizado.
4. `supabase/functions/get-platform-public-settings/index.ts`: respuestas con `Cache-Control: no-store, private, max-age=0`, `Pragma: no-cache`, `X-Content-Type-Options: nosniff` y `Referrer-Policy: no-referrer`.

El endpoint público mantiene CORS abierto porque su contenido es intencionalmente público y no utiliza credenciales de sesión; no debe ampliarse para devolver datos internos.

## 6. Riesgos y trabajo pendiente

| ID | Hallazgo | Acción necesaria |
|---|---|---|
| SUP-01 | No hay tickets internos | Diseñar y aprobar un módulo de soporte antes de prometer seguimiento de casos |
| SUP-02 | WhatsApp externo no queda auditado | Informar al usuario y registrar en auditoría solo la acción de apertura si se necesita trazabilidad, nunca el contenido del chat |
| SUP-03 | Función y tabla de ajustes públicos no están activas | Revisar/aplicar migración y desplegar función tras autorización y pruebas |
| SUP-04 | Contactos de negocio son públicos | Confirmar autorización y titularidad del número antes de publicarlo |
| SUP-05 | Asistente local no es soporte real | Mantener el aviso de límites; no atribuirle capacidades de IA o gestión de reclamos |
| SUP-06 | No existe clasificación de casos | Si se construyen tickets: definir categoría, prioridad, estado, asignación, negocio, solicitante y marcas de tiempo |

## 7. Diseño mínimo recomendado para un futuro módulo de tickets

Antes de implementarlo, definir:
- Un identificador de caso no predecible y estado controlado (`open`, `in_progress`, `waiting_user`, `resolved`, `closed`).
- `business_id` obligatorio para casos de negocio y reglas RLS que impidan cruces entre tiendas.
- Solicitante vinculado a Auth; el técnico solo ve casos de plataforma o casos escalados según permisos definidos.
- Mensajes separados de metadatos del caso, con permisos por autor/rol y límites de tamaño.
- Adjuntos en bucket privado, con rutas por caso y enlaces firmados temporales.
- Auditoría de creación, asignación, cambio de estado y cierre, sin copiar el texto completo de las conversaciones a `audit_logs`.
- Protección contra spam, límites de frecuencia, validación de contenido y política de conservación.
- Un flujo de exportación/eliminación que respete las obligaciones legales y preserve los registros que deban conservarse.

No se creó el módulo de tickets en esta auditoría porque faltan decisiones funcionales sobre quién puede abrir casos, si clientes pueden iniciar tickets sin cuenta, horarios de atención, SLA, adjuntos y plazos de conservación.

## 8. Validación y límites

Se revisó el código de la rama y se consultó el catálogo de Supabase en solo lectura. La búsqueda de tablas públicas con nombres relacionados con soporte, tickets, chat, mensajes o contacto no devolvió resultados. La lista de funciones activas no incluye `get-platform-public-settings`.

No se enviaron mensajes de WhatsApp, no se crearon tickets, no se desplegaron Edge Functions, no se ejecutaron migraciones ni se modificó la base activa. Las comprobaciones son estáticas; no equivalen a una prueba funcional en navegador o staging.
