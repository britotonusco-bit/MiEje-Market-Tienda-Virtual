# Auditoría del catálogo público

Fecha: 16 de noviembre de 2026  
Rama: `correcciones-funcionales`  
Proyecto inspeccionado: MiEje Market Independiente

## Visibilidad de tiendas y productos

La carga pública consulta negocios desde `public.businesses`, determina cuáles tienen estado `active` y consulta productos solo para esos negocios. La consulta de productos filtra `is_active = true`, ordena por fecha de creación y limita el resultado a 1.000 productos. Los negocios suspendidos se mantienen en el directorio para mostrar el aviso público, pero no reciben productos disponibles ni permiten pedidos.

Los productos con inventario cero pueden aparecer con el botón deshabilitado como “Agotado”. La función `addToCart` vuelve a comprobar que la tienda sea registrada y activa y que el inventario local sea mayor que cero antes de agregar el producto. La validación definitiva de stock y precio debe seguir realizándose en el servidor al crear el pedido.

## Imágenes no disponibles

El código ya contiene un listener global de error para imágenes de tarjetas, productos y cabecera de tienda. Oculta la imagen rota y agrega el mensaje accesible “Imagen no disponible”. No fue necesario duplicar esta lógica.

## Mejoras aplicadas en esta rama

1. La sección de tiendas destacadas excluye negocios suspendidos. Estos siguen apareciendo en el directorio general con su aviso público.
2. Cuando una tienda activa no tiene productos publicados, ahora se muestra un mensaje explícito en lugar de dejar una cuadrícula vacía.

## Riesgos y limitaciones observados

- Si falla la consulta del directorio, el código conserva el catálogo local de demostración. Los productos de demostración no permiten agregar pedidos, pero el visitante puede confundirlos con comercios reales si no se identifican claramente.
- Si no existen filas de negocios en Supabase, el código conserva la vista de demostración por diseño. Antes de la puesta en producción debe decidirse si se mantiene un modo demostración claramente rotulado o se muestra un catálogo vacío.
- La consulta pública de productos está limitada a 1.000 filas en una sola solicitud. Para catálogos mayores se necesita paginación.
- El navegador carga productos activos aunque tengan inventario cero para informar “Agotado”; esto es intencional.
- El cliente no es la autoridad final del inventario. El servidor debe volver a validar stock, precio, negocio activo y producto activo al confirmar el pedido.

## Verificaciones de solo lectura

En el proyecto independiente se encontraron 0 negocios y 0 productos. No se crearon datos de prueba.

Las políticas activas de productos permiten lectura pública únicamente de productos activos pertenecientes a negocios activos para `anon`. La política de lectura autenticada contempla productos activos públicamente y acceso de administración/empleados dentro de negocios activos.

No se ejecutó SQL, no se desplegaron funciones, no se cambió `main` ni se publicó GitHub Pages. La revisión del código fue estática; no equivale a una prueba de navegador o una compra real.

## Pruebas pendientes en un entorno de ensayo

1. Negocio activo con productos activos e inactivos.
2. Negocio suspendido con productos existentes.
3. Producto agotado, producto con inventario y producto sin imagen.
4. Error de red al cargar el directorio.
5. Catálogo con más de 1.000 productos y paginación.
6. Compra con cambio de inventario entre carga del catálogo y confirmación.
