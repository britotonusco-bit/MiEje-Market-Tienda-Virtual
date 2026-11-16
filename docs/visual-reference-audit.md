# Auditoría de referencias visuales — MiEje Market

Fecha: 16 de noviembre de 2026  
Fuente: ZIP "IMÁGENES DE REFERENCIA PARA MI EJE MARKET" (37 archivos PNG)  
Rama de trabajo: `correcciones-funcionales`

## 1. Lectura de las referencias

Las 37 imágenes no representan una única plantilla repetida. Muestran cuatro experiencias relacionadas por la marca, pero con objetivos distintos:

1. Tienda pública: descubrimiento, navegación, compra y seguimiento.
2. Panel técnico superior: control y supervisión de la plataforma.
3. Panel de administradores: operación comercial de cada negocio.
4. Panel de empleados: ejecución de tareas operativas, principalmente pedidos.

La identidad de MiEje Market debe ser coherente entre las cuatro experiencias, pero no se debe forzar una misma distribución, navegación o densidad de información en todas ellas.

## 2. Inventario de referencias del ZIP

### Tienda pública y experiencia del cliente
- `Página principal pública de MiEje Market.png`
- `1.3. Categorías comerciales.png`
- `1.4. Negocios destacados.png`
- `1.5. Productos destacados.png`
- `1.6. Catálogo general de productos.png`
- `1.7. Sección de ofertas y promociones.png`
- `1.8. Sección de empleos.png`
- `1.11. Pie de página.png`
- `3. FICHA COMPLETA DE PRODUCTOS.png`
- `4. CARRITO DE COMPRAS Y CHECKOUT.png`
- `5. SEGUIMIENTO DE PEDIDOS.png`
- `6.4. Vacantes de empleo.png`

### Panel técnico superior
- `2. Panel técnico superior.png`
- `2.2. Resumen general.png`
- `2.3. Gestión de negocios.png`
- `2.4. Gestión de usuarios y permisos.png`
- `2.6. Seguridad y auditoría.png`
- `7. PANEL TÉCNICO SUPERIOR — PROPIETARIO DE MIEJE MARKET.png`
- `7.2 PANEL TÉCNICO SUPERIOR — PROPIETARIO DE MIEJE MARKET.png`
- `7.3 PANEL TÉCNICO SUPERIOR — PROPIETARIO DE MIEJE MARKET.png`
- `7.7. Auditoría y registros del sistema.png`

### Panel de administradores de negocios
- `3. Panel de administradores de negocios.png`
- `3.1. Inicio del panel.png`
- `3.2. Personalización de la tienda.png`
- `3.3. Gestión de productos.png`
- `3.5. Gestión de pedidos.png`
- `3.7. Promociones y publicidad.png`
- `3.8. Métodos de pago.png`
- `3.9. Finanzas y reportes.png`
- `3.10. Gestión de empleados.png`
- `8. PANEL DEL ADMINISTRADOR DE CADA NEGOCIO.png`
- `8.1 Dashboard principal.png`
- `8.2 PANEL DEL ADMINISTRADOR DE CADA NEGOCIO.png`
- `8.3 PANEL DEL ADMINISTRADOR DE CADA NEGOCIO.png`
- `8.3. Gestión de productos.png`

### Panel de empleados
- `4. Panel de empleados.png`
- `4.2. Mis pedidos.png`

## 3. Diferencias detectadas frente a la implementación actual de la rama

La revisión compara las capturas de referencia con el HTML y CSS actuales. Es una inspección estática; todavía no equivale a una prueba visual en navegador.

### Tienda pública
- La referencia principal presenta una composición de comercio electrónico con acceso visible a catálogo, categorías, productos y tiendas.
- Las referencias secundarias piden secciones diferenciadas para categorías, negocios destacados, productos, ofertas y empleos, además de ficha de producto, carrito/checkout y seguimiento.
- La página actual ya contiene navegación, hero, categorías, negocios/productos, carrito y formulario de checkout/seguimiento.
- La cuadrícula de categorías actual usa cinco tarjetas fotográficas grandes (dos filas con tarjetas de distinto ancho). Debe compararse y ajustarse a la composición más compacta de las referencias de categorías.
- La revisión debe verificar que las secciones de ofertas, empleos, catálogo y ficha de producto tengan jerarquía visual propia y no queden como bloques genéricos.
- Deben conservarse los IDs, atributos `data-action`, formularios y selectores que utiliza `app.js`; el rediseño no debe romper la lógica de la tienda.

### Panel técnico superior
- Las referencias muestran una consola de supervisión con navegación lateral, resumen de métricas, gestión de negocios, gestión de usuarios, seguridad y auditoría.
- Hay referencias tanto de tema claro como de tema oscuro. No se debe decidir arbitrariamente que todas las capturas tienen que ser oscuras: la dirección final debe conservar la composición de consola y seleccionar una variante consistente.
- La página actual contiene las áreas funcionales de negocios, usuarios, finanzas/nómina, bloqueos, moderación, IA, soporte y auditoría.
- Actualmente usa la misma base visual verde/oscura compartida con los otros paneles. Hace falta diferenciar su jerarquía de consola técnica sin cambiar sus permisos ni convertirlo en administrador comercial de cada tienda.

### Panel de administradores
- Las referencias muestran un dashboard comercial con resumen, navegación lateral, tablas y pantallas dedicadas a personalización, productos, pedidos, promociones, métodos de pago, finanzas y empleados.
- La página actual incluye buena parte de estas áreas, pero la estructura se presenta como una secuencia larga de secciones dentro de una plantilla común. Hay que ordenar la navegación, los encabezados, las tarjetas de resumen y los espacios de trabajo para acercarse a las capturas.
- `panel-negocio.html` es el panel operativo real. `panel-admin.html` no debe usarse como sustituto: continúa siendo un prototipo desconectado.
- Todos los administradores, aunque pertenezcan a negocios distintos, deben cargar exactamente la misma plantilla, estilos, botones y componentes. Solo cambian los datos y las acciones permitidas para su negocio.

### Panel de empleados
- Las referencias muestran un espacio operativo dedicado a pedidos, con tabla/listado legible, estados visibles y una experiencia adaptable.
- La página actual es mucho más reducida: cola de pedidos, explicación del seguimiento y soporte. Debe revisarse la distribución del listado, filtros/estados que ya estén soportados y adaptación móvil, sin agregar acciones que el rol no tenga autorizadas.
- Todos los empleados deben cargar la misma plantilla y componentes, con datos limitados a su negocio y permisos de empleado.

## 4. Reglas obligatorias para el rediseño

- Mantener una identidad de marca compartida entre tienda y paneles, sin copiar literalmente interfaces ajenas.
- Respetar el propósito y la composición de cada grupo de referencias.
- Administradores: una sola plantilla compartida para todas las cuentas de ese rol.
- Empleados: una sola plantilla compartida para todas las cuentas de ese rol.
- Las cuentas nuevas creadas desde el panel técnico deben recibir automáticamente la interfaz que corresponde a su rol, sin generar páginas o temas individuales.
- El contenido y las acciones visibles deben respetar el negocio asignado y el rol; el diseño común no implica permisos comunes.
- El panel técnico administra plataforma, negocios, cuentas, accesos, seguridad y auditoría. No debe apropiarse de la configuración comercial cotidiana ni mostrar datos comerciales de otros negocios sin autorización.
- Preservar IDs, nombres de formularios, atributos de datos, eventos, puntos de montaje dinámicos y contratos JavaScript existentes.
- No cambiar consultas, autenticación, RLS, RPC, Edge Functions ni datos como parte de un ajuste puramente visual.
- Respetar accesibilidad: contraste, foco visible, navegación por teclado, etiquetas, estados y preferencia de movimiento reducido.
- Validar escritorio, tablet y móvil antes de dar el diseño por terminado.

## 5. Plan de implementación

1. Tienda pública: ajustar estructura visual por secciones y responsive, manteniendo intactos los contratos de `app.js`.
2. Panel técnico: establecer una identidad de consola propia y alinear resumen, negocios, usuarios y auditoría con sus referencias.
3. Panel administrador: crear la composición de dashboard y espacios de gestión según las referencias; mantener una sola plantilla para todos los administradores.
4. Panel empleados: dar prioridad a la cola de pedidos y estados, con diseño adaptable y sin herramientas administrativas.
5. Revisar los estados vacíos, carga, error, tablas largas, formularios, modales y contenido dinámico.
6. Comparar capturas reales de navegador con las referencias y documentar cada diferencia pendiente.

## 6. Estado y límites de esta auditoría

- ZIP abierto y 37 imágenes inventariadas y revisadas en una hoja de contacto.
- HTML y CSS de la rama `correcciones-funcionales` inspeccionados estáticamente.
- Las diferencias anteriores son hallazgos de estructura y composición, no resultados de pruebas de navegador.
- No se han realizado capturas del sitio funcionando ni pruebas responsive reales.
- No se ha publicado la rama ni se ha modificado `main`.
- No se ha modificado Supabase ni se han aplicado migraciones.
