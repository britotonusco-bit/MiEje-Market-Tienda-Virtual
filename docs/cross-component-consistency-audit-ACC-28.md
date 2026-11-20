# ACC-28 — Auditoría de consistencia transversal del código

**Rama inspeccionada:** `correcciones-funcionales`  
**HEAD inspeccionado:** `f55797dc331449f3aab29b4cf7f2d0a232bc6550`  
**Tipo de revisión:** estática, lectura de archivos y comparación de contratos entre frontend y Edge Functions.  
**Alcance:** tienda pública, autenticación, configuración Supabase, panel técnico, panel de negocio, panel de empleados, panel prototipo heredado y funciones Edge relacionadas.  
**No realizado:** pruebas de navegador, ejecución Deno, SQL, llamadas de escritura a Supabase, despliegues ni pruebas con usuarios reales.

## Resultado ejecutivo

La estructura principal de los tres paneles conectados coincide con el modelo de roles documentado. La tienda pública también envía los campos principales que espera `create-public-order`, y la carga de métodos de pago respeta el límite de 200 negocios por solicitud.

Sin embargo, se identifican dos inconsistencias funcionales que conviene corregir antes de dar por cerrada la integración, además de dos riesgos de mantenimiento y presentación.

## Hallazgos

### ACC28-01 — Catálogo público conserva negocios de demostración junto a negocios reales
**Prioridad: alta**

En `app.js`, `loadRegisteredBusinesses()` retorna sin reemplazar el arreglo local cuando la consulta de negocios no devuelve filas. Si la consulta falla, el bloque `catch` también conserva los datos locales. Cuando sí existen negocios registrados, combina los negocios reales con los negocios locales que no tengan el mismo identificador.

El arreglo local inicial contiene tiendas y productos de ejemplo. Las tarjetas de negocio no los identifican claramente como demostraciones, aunque los productos pueden mostrar el botón “Demostración”. Esto puede hacer que visitantes confundan negocios ficticios con comercios activos y genera una vista aparentemente válida cuando la conexión o el catálogo real están vacíos.

**Corrección recomendada:** separar explícitamente el modo de demostración del catálogo real. En producción, mostrar únicamente negocios obtenidos correctamente desde Supabase; si la consulta falla, mostrar un estado de error o indisponibilidad, no datos ficticios. Si se necesita conservar el modo demo para desarrollo, activarlo mediante una configuración explícita que no quede habilitada por defecto.

**Archivos:** `app.js`, función `loadRegisteredBusinesses()` y arreglo inicial `businesses`.

### ACC28-02 — Etiquetas de seguimiento no coinciden con los estados emitidos por el servidor
**Prioridad: alta**

La Edge Function `track-public-order` acepta y devuelve los estados `received`, `confirmed`, `preparing`, `ready`, `on_the_way`, `delivered` y `cancelled`.

En `app.js`, el mapa de etiquetas del formulario de seguimiento todavía utiliza `pending` para el estado inicial y `out_for_delivery` para el estado en camino. No contempla `received` ni `on_the_way`. Como resultado, esos estados pueden mostrarse con su identificador técnico en vez de una etiqueta legible en español.

El panel conectado sí define el flujo con `received` y `on_the_way`, por lo que el desacuerdo está en la presentación pública del seguimiento.

**Corrección recomendada:** unificar el mapa público con el contrato vigente del servidor y el panel: `received: "Recibido"` y `on_the_way: "En camino"`. Añadir una comprobación de contrato para evitar que el mapa vuelva a quedarse desactualizado.

**Archivos:** `app.js`, manejador de `#trackingForm`; `supabase/functions/track-public-order/index.ts`; `panel-live.js`, mapa `statusLabels`.

### ACC28-03 — Existe un panel administrativo heredado que no pertenece al esquema de tres paneles
**Prioridad: media**

El repositorio conserva `panel-admin.html`, `panel-admin.js` y `panel-admin.css`. La página se identifica expresamente como prototipo visual, no utiliza Supabase ni autenticación y contiene datos ficticios y acciones que solo muestran mensajes de demostración. Además, su concepto de “Administrador general” y su navegación global pueden confundirse con el panel técnico superior, el cual sí está conectado y tiene responsabilidades más limitadas.

No se observó que las páginas principales enlacen este prototipo como acceso operativo; aun así, el archivo es accesible directamente por URL.

**Corrección recomendada:** conservarlo solo si se necesita como referencia interna y dejarlo fuera de cualquier navegación o documentación de acceso real. Antes del lanzamiento, retirarlo del sitio publicado o trasladarlo a una ubicación de prototipos no desplegada. No convertirlo en un cuarto panel.

**Archivos:** `panel-admin.html`, `panel-admin.js`, `panel-admin.css`.

### ACC28-04 — Versiones del SDK Supabase no están fijadas de forma uniforme
**Prioridad: media**

Las páginas HTML cargan `@supabase/supabase-js@2` desde jsDelivr, sin fijar una versión menor concreta. En las Edge Functions, la mayoría de funciones inspeccionadas importa `@supabase/supabase-js@2.75.0`, mientras `resolve-my-access` importa `2.119.0`.

Esto no demuestra por sí solo un fallo actual, pero introduce diferencias de comportamiento y reproducibilidad entre el cliente y las funciones del servidor, además de permitir que la versión del navegador cambie sin un commit del proyecto.

**Corrección recomendada:** elegir una versión estable compatible y fijarla explícitamente en todas las páginas cliente. Documentar y revisar por separado la versión de servidor antes de actualizarla; no actualizar dependencias automáticamente durante una corrección funcional.

**Archivos:** HTML de tienda y paneles; funciones Edge en `supabase/functions/`.

## Contratos revisados y coherentes en la inspección

- `index.html` carga la biblioteca Supabase, `supabase-config.js`, `app.js` y `visual-motion.js`.
- `login.html` carga la configuración antes de `login.js`; el inicio de sesión invoca `resolve-my-access`.
- `login.js` dirige `platform_owner` al panel técnico, `business_admin` al panel de negocio y `employee` al panel de personal.
- `panel-tecnico.html`, `panel-negocio.html` y `panel-personal.html` declaran los valores esperados en `body[data-panel]` y comparten `panel-live.js`.
- `panel-live.js` vuelve a consultar `resolve-my-access` al iniciar y registra controles por presencia de elementos, lo que permite compartir parte del código entre las páginas.
- `app.js` envía a `create-public-order` los campos de consentimiento, versión, clave de idempotencia, negocio, forma de pago y líneas del pedido que la función valida.
- `app.js` divide las consultas de formas de pago en lotes de hasta 200 negocios, igual al máximo que acepta `get-public-storefront`.
- La solicitud de postulación desde `app.js` envía la versión de consentimiento y los datos de carga que valida `create-job-application`.
- `supabase/config.toml` marca como públicas las funciones de tienda/seguimiento y exige JWT en las funciones privadas revisadas; la función de limpieza se describe como invocación privada protegida por secreto independiente.

## Límites y asuntos que siguen bloqueados

1. Esta revisión no demuestra que las funciones Edge de la rama estén desplegadas en el proyecto activo.
2. Las migraciones y políticas SQL de la rama siguen siendo borradores hasta validarse y aplicarse en un entorno staging aislado.
3. No se ha ejecutado una prueba real de compra, seguimiento, favoritos, postulaciones, carga de archivos ni acciones de panel.
4. No se verificó el comportamiento en navegador ni la compatibilidad de las versiones SDK mediante pruebas de ejecución.
5. La consistencia de permisos debe confirmarse con la matriz ACC-27 en staging; la inspección estática no sustituye pruebas de RLS, Auth, MFA o aislamiento entre negocios.

## Orden recomendado de corrección

1. Corregir ACC28-02 para que el seguimiento traduzca exactamente los estados vigentes.
2. Corregir ACC28-01 para que el catálogo público nunca presente negocios ficticios como reales.
3. Resolver la publicación/ubicación del prototipo ACC28-03 antes del lanzamiento.
4. Fijar y documentar las versiones SDK en ACC28-04.
5. Ejecutar la matriz ACC-27 únicamente cuando staging esté aislado, preparado y autorizado.

**Estado ACC-28:** auditoría estática documentada; no equivale a aprobación funcional ni a pruebas integrales superadas.
