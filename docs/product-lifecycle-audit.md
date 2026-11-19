# Auditoría del ciclo de vida de productos

Fecha: 16 de noviembre de 2026  
Rama: `correcciones-funcionales`  
Proyecto inspeccionado: MiEje Market Independiente

## Resultado

La interfaz del administrador no presenta una acción para eliminar productos. Permite editar y activar/desactivar productos. La consulta de Supabase confirmó, sin embargo, que la política activa `products_admin_delete` permitía DELETE a usuarios autenticados con rol `business_admin` sobre su propio negocio activo.

La migración de esta rama ahora:
- elimina la política `products_admin_delete`;
- revoca el privilegio SQL DELETE sobre `public.products` para PUBLIC, anon y authenticated;
- conserva la desactivación mediante `is_active=false` como alternativa reversible.

La eliminación física no es adecuada como operación ordinaria: `order_items.product_id` usa `ON DELETE SET NULL`, por lo que borrar un producto puede romper la asociación histórica aunque se conserve el nombre y precio de la línea. La tabla `product_costs` tiene una FK compuesta con `ON DELETE RESTRICT`, que además bloquea borrar productos que tengan costo registrado.

## Separación entre negocios

Las políticas activas inspeccionadas para `products` limitan INSERT, UPDATE y DELETE al administrador del negocio asociado y requieren que el negocio esté activo. La política UPDATE contiene tanto `USING` como `WITH CHECK`, y el borrador de límites de administrador restringe las columnas actualizables y añade protección contra cambio de negocio.

El panel también filtra las lecturas y actualizaciones por `business_id`, y al editar exige que el producto exista en la lista cargada del negocio actual. Estas comprobaciones de interfaz son complementarias: la autorización real depende de RLS y privilegios de base de datos.

## Imágenes y reemplazo

El panel guarda imágenes propias en el bucket `business-assets`, bajo la carpeta `<business_id>/products/<uuid>.<ext>`. Antes de retirar una imagen anterior, valida que la URL pertenezca al proyecto Supabase actual, al bucket esperado y al negocio activo en el panel. Las URLs externas no se eliminan.

Al reemplazar una imagen, el archivo nuevo se sube antes de actualizar el producto. Si falla el guardado del producto, el panel intenta retirar el nuevo archivo. Si la eliminación del archivo anterior falla después de guardar el producto, el panel solo registra una advertencia; podría quedar un objeto huérfano que requerirá una futura tarea de conciliación.

Desactivar un producto no elimina su imagen. Esto es intencional: permite reactivarlo sin tener que volver a cargarla y no borra datos históricos.

## Estado de las pruebas

Inspección de solo lectura en Supabase:
- `products`: 0 filas.
- `product_costs`: 0 filas.
- `order_items`: 0 filas.
- RLS habilitado en `products`.
- La política DELETE y el privilegio DELETE estaban activos antes de aplicar el borrador.

No se crearon datos de prueba ni se ejecutó SQL. La corrección está preparada únicamente en la rama; todavía requiere revisión y aplicación en un entorno de ensayo. No se verificó una eliminación real, un reemplazo real de imagen ni una prueba de aislamiento con dos administradores.

## Pendientes para ensayo

1. Aplicar la migración de límites de administrador en una base de ensayo.
2. Confirmar que el administrador A puede editar/desactivar sus productos y no puede leer/editar productos del negocio B.
3. Confirmar que DELETE es rechazado incluso con una petición directa a la API.
4. Probar reemplazo de imagen, fallo de guardado y fallo de Storage.
5. Preparar una conciliación segura de objetos antiguos no referenciados, con vista previa y sin borrado automático.
