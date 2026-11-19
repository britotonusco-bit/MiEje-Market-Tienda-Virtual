# Auditoría de rendimiento y capacidad de crecimiento

**Proyecto:** MiEje Market Independiente  
**Supabase project ref:** `cqixlrwbqatbhzmpygiz`  
**Rama:** `correcciones-funcionales`  
**Fecha:** 19 de noviembre de 2026  
**Alcance:** asesor de rendimiento, estadísticas PostgreSQL, índices, consultas de interfaz y límites de carga. Todas las consultas sobre Supabase fueron de solo lectura.

## 1. Dictamen

El proyecto aún no tiene una carga comercial representativa para certificar su rendimiento bajo concurrencia. La base activa muestra prácticamente todas las tablas comerciales vacías, por lo que no sería correcto afirmar que la aplicación ya soporta miles de productos o pedidos.

El asesor de rendimiento detectó:
- 16 claves foráneas sin índices de cobertura.
- 16 índices que no registran uso en las estadísticas actuales.
- 1 advertencia por políticas RLS permisivas múltiples en `business_content_pages`.

El asesor de salud no devolvió hallazgos. Esto no sustituye pruebas de carga.

## 2. Estado de datos y estadísticas

Consulta de solo lectura al proyecto activo:
- PostgreSQL 17.11.0.003.
- `profiles`: 1 fila estimada.
- `businesses`, `business_memberships`, `products`, `orders`, `order_items`, `financial_transactions`, `refund_details`, `job_applications`, `business_expenses`, `audit_logs`, `product_costs` y `order_item_costs`: 0 filas estimadas en la consulta.
- Las tablas comerciales principales ocupan entre 8 KB y 80 KB en la medición consultada.

Las estadísticas `pg_stat_user_tables` y `pg_stat_user_indexes` son acumuladas desde el último reinicio/reset relevante y dependen del tráfico que haya ocurrido. Un índice con cero lecturas en una base casi vacía no es prueba de que sea innecesario.

## 3. Claves foráneas sin índice

El asesor encontró 16 relaciones sin índice que cubra las columnas de la clave foránea. Los grupos afectados son:
- `business_content_pages`: `created_by`, `moderated_by`, `updated_by`.
- `business_expenses`: `created_by`, `voided_by`.
- `financial_transactions`: relación compuesta con cancelación y `cancellation_request_id`.
- `job_application_upload_sessions`: `business_id` y relación con página de contenido.
- `job_applications`: relación negocio/página y `reviewed_by`.
- `order_item_costs`: relación negocio/pedido y pedido/línea.
- `product_costs`: relación negocio/producto.
- `refund_details`: relación negocio/pedido y transacción financiera.

Se preparó `database/performance/index-optimization-draft.sql` con 14 índices candidatos. La diferencia entre 16 hallazgos y 14 índices se debe a que algunos índices compuestos propuestos cubren también claves foráneas simples o compuestas cuyo conjunto de columnas es un prefijo izquierdo del mismo índice.

Estos índices pueden reducir búsquedas completas al validar/eliminar/actualizar filas referenciadas y acelerar joins de negocio. No se aplicaron. Deben probarse en staging y medirse; cada índice también consume espacio y aumenta el costo de INSERT/UPDATE/DELETE.

## 4. Índices marcados como no utilizados

El asesor enumeró 16 índices sin lecturas registradas, incluyendo índices de:
- membresías por usuario;
- productos por negocio/estado;
- pedidos por negocio/fecha;
- líneas de pedido;
- auditoría;
- solicitudes de cancelación;
- transacciones financieras;
- gastos;
- moderación de contenido;
- expiración de sesiones de carga.

**No se recomienda borrarlos ahora.** La plataforma no tiene volumen comercial y varios índices corresponden a rutas críticas que todavía no han tenido tráfico real. Antes de considerar eliminar alguno, se debe medir durante una ventana representativa después de pruebas de carga y revisar sus restricciones/consultas dependientes.

## 5. Políticas RLS y costo de consulta

El asesor marcó una advertencia en `business_content_pages`: dos políticas permisivas de SELECT para `authenticated`, `business_content_pages_admin_read` y `business_content_pages_public_read`.

PostgreSQL combina políticas permisivas con OR; varias expresiones pueden evaluarse en cada consulta. Sin embargo, fusionarlas sin revisar el comportamiento público y del administrador puede cambiar qué filas son visibles. No se modificaron las políticas. Se debe resolver en una revisión de seguridad/RLS separada y comprobar el mismo resultado con usuarios anónimos, administradores y otros miembros.

## 6. Carga, límites y paginación en la interfaz

Revisión estática de la rama:
- Página pública: carga hasta 200 negocios, 1.000 productos y 500 piezas de contenido en solicitudes amplias. No se observó paginación incremental en esos bloques.
- Panel del negocio: pedidos hasta 100, productos hasta 250, gastos hasta 250, postulaciones hasta 100, movimientos de inventario hasta 100 y auditoría hasta 100.
- Historial del cliente: la RPC revisada limita la consulta a los últimos 50 pedidos.
- Favoritos: la consulta de cuenta no muestra paginación explícita.
- El panel de empleado reutiliza la carga operativa de pedidos, limitada a 100 en la consulta observada.

Los límites evitan descargar tablas completas, pero generan un límite funcional: cuando un negocio supere esos topes, los registros más antiguos o los productos posteriores al corte no se mostrarán en esa carga. No se debe presentar ese resultado como historial completo.

**Recomendación:** implementar paginación por cursor (keyset) basada en una ordenación estable, por ejemplo `created_at DESC, id DESC`, y filtrar siempre por `business_id`. Evitar `OFFSET` grande para historiales que crezcan mucho. Para catálogos públicos, cargar por negocio/categoría y recuperar páginas conforme el cliente navega.

## 7. Consultas observadas

`pg_stat_statements` está disponible y devolvió consultas de introspección/administración del esquema entre las de mayor costo acumulado. No se identificó una muestra representativa de consultas comerciales lentas; las tablas de pedidos y productos están vacías. Por tanto:
- No se atribuyen esos tiempos a lentitud de MiEje Market.
- No se cambia una consulta sin un plan `EXPLAIN (ANALYZE, BUFFERS)` ejecutado con datos representativos en staging.
- No se ejecuta `pg_stat_statements_reset()` durante la auditoría, porque borraría estadísticas útiles.

## 8. Plan de pruebas de rendimiento

En staging, con datos sintéticos que no contengan información personal:
1. Cargar varios negocios aislados, productos, pedidos y líneas de pedido en cantidades crecientes.
2. Medir catálogo público por negocio/categoría, búsqueda, detalle y carrito.
3. Medir pedidos por estado y fecha, historial, gastos, auditoría y vacantes.
4. Probar checkout concurrente sobre el mismo producto y productos distintos; confirmar inventario correcto y ausencia de sobreventa.
5. Probar cancelaciones concurrentes y conciliación de inventario.
6. Medir consultas con `EXPLAIN (ANALYZE, BUFFERS)` y estadísticas antes/después.
7. Comparar latencia p50/p95/p99, throughput, errores y uso de conexiones bajo carga.
8. Probar paginación más allá de 1.000 productos y 100 pedidos por negocio.
9. Verificar que RLS mantenga aislamiento entre negocios durante las pruebas.
10. Repetir pruebas después de aplicar los índices candidatos y revisar el asesor de rendimiento.

No fijar objetivos de latencia ni concurrencia sin acordar antes el volumen esperado y la capacidad del plan de Supabase.

## 9. Cambios realizados en la rama

Se añadió `database/performance/index-optimization-draft.sql`, con 14 índices candidatos y una consulta de verificación comentada. El archivo está marcado expresamente como borrador para staging; no ejecutarlo en el proyecto activo durante esta auditoría.

No se eliminaron índices, no se modificaron políticas RLS, no se alteraron consultas de producción y no se ejecutó ninguna migración.

## 10. Pendientes para cerrar

- [ ] Aplicar índices candidatos en staging y revisar asesor.
- [ ] Medir rendimiento antes/después con datos representativos.
- [ ] Resolver la política RLS múltiple sin cambiar permisos.
- [ ] Implementar paginación por cursor en catálogo, pedidos, favoritos y listados administrativos.
- [ ] Verificar comportamiento de carga en dispositivos móviles y conexiones lentas.
- [ ] Definir objetivos de rendimiento y concurrencia.
- [ ] Ejecutar pruebas de carga y concurrencia de checkout/cancelación.
- [ ] Confirmar plan y límites de recursos del proyecto antes de abrir al público.

**Conclusión:** se identificaron correcciones concretas de índices y límites de carga, pero la capacidad real de crecimiento aún no está demostrada. El siguiente paso seguro es validar los índices y la paginación en staging, no optimizar a ciegas la base activa.


## 11. Primera implementación de paginación en paneles

Se actualizó `panel-live.js` en la rama:
- Productos del administrador: páginas de 50 filas, orden estable `created_at DESC, id DESC`, cursor compuesto y botones Anterior/Siguiente.
- El panel consulta costos solo para los IDs de los 50 productos visibles, en vez de descargar todos los costos del negocio.
- Pedidos del empleado: páginas de 50 filas con el mismo patrón de cursor estable.
- Se solicita una fila adicional para determinar si existe página siguiente.
- El filtro de cursor siempre se combina con `business_id`, por lo que la paginación no amplía el alcance del negocio.

Limitaciones que permanecen:
- Pedidos del administrador todavía cargan hasta 100 y dependen de la RPC financiera que entrega un conjunto independiente; no se cambió para evitar mostrar pedidos sin sus datos financieros.
- Catálogo público todavía carga topes globales (200 negocios, 1.000 productos, 500 publicaciones).
- Favoritos, postulaciones, gastos, movimientos de inventario, cancelaciones y auditoría todavía requieren paginación.
- No se ha probado el cursor con registros que compartan exactamente la misma fecha ni bajo inserciones concurrentes en navegador/staging.

La implementación está en rama y requiere pruebas de integración con Supabase antes de considerarse cerrada.


## 12. Optimización de agrupación del catálogo público

En `app.js` se sustituyó el filtrado completo de productos para cada negocio por una agrupación previa en un `Map` indexado por `business_id`. La asignación de productos a negocios pasa de recorrer repetidamente el catálogo a una pasada de agrupación y consultas directas por negocio. Esto reduce trabajo en memoria cuando aumenta el número de negocios y productos.

La carga remota todavía conserva los topes de 200 negocios, 1.000 productos y 500 publicaciones; no se considera resuelto el límite de catálogo. No se añadieron solicitudes de paginación al storefront en este cambio porque el carrito, la ficha de producto, favoritos y el asistente dependen de tener los productos de cada tienda disponibles localmente. Ese cambio requiere una estrategia de carga por tienda y persistencia de producto seleccionada para el carrito.


## 13. Paginación de pedidos del administrador

Se añadió el RPC borrador `get_business_admin_order_financials_page` y se conectó a `panel-live.js`:
- La página financiera es la fuente de orden y cursor.
- Se solicitan 51 filas para mostrar 50 y detectar si existe página siguiente.
- El cursor está compuesto por `created_at + order_id`, con orden descendente estable.
- Los datos operativos (cliente, entrega y líneas) se recuperan solo para los IDs financieros de esa página y se vuelven a filtrar por `business_id`.
- Si falta alguno de los pedidos operativos correspondientes, la interfaz muestra error y no presenta una página parcialmente cruzada.
- La función comprueba sesión, negocio activo, rol `business_admin` y que el cursor llegue completo.

El RPC es un borrador SQL adicional. Debe aplicarse primero en staging, probarse con timestamps repetidos, páginas vacías, más de 50 pedidos, cambios concurrentes y usuarios de dos negocios. La función antigua de hasta 100 registros se conserva por compatibilidad, pero el panel utiliza la nueva función paginada.


## 14. Paginación de postulaciones y cancelaciones

En `panel-live.js` se añadieron páginas de 50 registros para:
- Postulaciones laborales del negocio, incluyendo sus enlaces temporales de CV bajo demanda.
- Solicitudes de cancelación del negocio, conservando las acciones de aprobar y rechazar.

Ambos listados usan `created_at DESC, id DESC`, cursor compuesto y filtro `business_id`. Se solicita una fila adicional para detectar la página siguiente. Los controles Anterior/Siguiente mantienen el cursor de cada página; los estados vacíos también conservan la navegación hacia la página anterior.

No se ha comprobado aún el rendimiento con un volumen real de CV ni la interacción concurrente entre revisiones/cancelaciones y la navegación. Las pruebas de autorización, RLS y enlaces firmados deben ejecutarse en staging.


## 15. Paginación de gastos, inventario y favoritos

Se ampliaron los listados:
- Gastos del administrador: 50 por página, cursor `expense_date + id`, filtro de negocio. El texto de la interfaz ya no presenta 250 como si fuera el historial completo.
- Movimientos de inventario: 50 por página, cursor `created_at + id`, filtro de negocio. Los nombres de productos se consultan solo para los productos incluidos en la página, también limitados al negocio.
- Favoritos del cliente: 50 por página, cursor `created_at + id`, filtro por `user_id`. Se conserva la eliminación del favorito y al volver a cargar se regresa a la primera página.

Pendientes de rendimiento/paginación:
- Historial de pedidos del cliente: la RPC actual devuelve los últimos 50; falta crear una variante paginada.
- Eventos de auditoría: el endpoint técnico y la consulta administrativa aún tienen tope de 100.
- El listado de reembolsos conserva el RPC anterior con tope de 100.
- El catálogo público conserva límites globales; necesita carga por tienda y categoría.
- Publicaciones del negocio y listas técnicas de negocios/usuarios requieren revisar paginación de extremo a extremo.

No se ha probado en navegador ni staging. Los cambios de cuenta/favoritos dependen de que la migración de clientes esté instalada y la tabla esté expuesta por Data API.


## 16. Paginación de auditoría

Se añadió cursor compuesto `created_at + id` al listado de eventos de auditoría:
- El panel técnico envía el cursor a `technical-business-management`.
- La Edge Function valida que fecha e ID lleguen juntos, comprueba formato ISO de fecha y UUID, ordena por ambos campos y devuelve hasta 51 filas para una página de 50.
- Se conserva el límite máximo de 100 para las llamadas existentes que no usan cursor (por ejemplo, el contador/resumen y el listado de accesos).
- El panel de negocio pagina su consulta con el filtro de negocio o actor que ya tenía aplicado.
- La búsqueda de nombres de usuario se limita a los actores presentes en la página actual.

La Edge Function modificada está en la rama y todavía no está desplegada. No se ha validado en navegador ni staging; la paginación de registros de acceso específicos continúa con el límite anterior de 100.


## 17. Paginación de reembolsos pendientes

El panel administrativo cambió el listado de pedidos cancelados y pagados pendientes de registrar como reembolso para usar `get_business_admin_order_financials_page`. Conserva el filtro de cancelación aprobada y pago confirmado dentro del RPC, y pagina 50 resultados mediante `created_at + order_id`. No se trasladó la decisión financiera al navegador.

El cambio requiere que el RPC nuevo esté aplicado en staging junto con el resto del paquete de finanzas. La función antigua permanece para compatibilidad con otras llamadas.
