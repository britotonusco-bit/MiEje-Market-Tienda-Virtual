# Auditoría de acceso a datos por negocio y por tipo de usuario

**Proyecto revisado:** MiEje Market Independiente  
**Proyecto Supabase:** `cqixlrwbqatbhzmpygiz`  
**Rama de referencia:** `correcciones-funcionales`  
**Fecha:** 16 de noviembre de 2026  
**Alcance:** revisión de solo lectura de RLS, permisos SQL por tabla y columna, funciones auxiliares, disparadores, políticas de Storage y borradores existentes.  
**Estado:** auditoría; no se ejecutaron migraciones ni se desplegaron funciones.

## 1. Resumen ejecutivo

La base tiene separación por negocio en varias tablas: las políticas de productos, pedidos, gastos y contenido comercial usan el identificador del negocio y las funciones privadas de membresía. La función `private.has_business_role` comprueba que el usuario autenticado tenga una membresía activa del negocio, que su perfil no esté bloqueado y que su rol coincida con los roles permitidos. `private.business_is_active` comprueba que el negocio esté activo. Las dos funciones son `SECURITY DEFINER`, están en el esquema privado y fijan `search_path` vacío.

Sin embargo, la separación todavía no cumple completamente el modelo de tres paneles solicitado. Los hallazgos más importantes son:

1. **El técnico superior tiene acceso directo a datos comerciales que deberían quedar bajo control de cada negocio**, incluidos métodos de pago, gastos y varios registros financieros. También puede actualizar columnas comerciales de la ficha del negocio mediante el acceso directo permitido actualmente.
2. **Los empleados pueden consultar todos los campos de los pedidos de su negocio**, incluidos correo electrónico, teléfono, dirección y notas de entrega. Algunos datos son necesarios para entregar pedidos, pero el correo electrónico no parece necesario para la operación normal del empleado.
3. **La política de lectura de postulaciones no comprueba que el negocio siga activo.** Un administrador cuya membresía continúe activa puede consultar los datos de postulantes aunque el negocio esté suspendido.
4. **Las cuatro políticas de administración del bucket `business-assets` contienen una referencia incorrecta a la ruta del archivo.** Usan `storage.foldername(b.name)` en vez de analizar `storage.objects.name`. Esto puede impedir que los administradores gestionen correctamente sus imágenes.
5. **La eliminación directa de productos sigue permitida** para administradores de negocio, aunque el modelo de trabajo debe preferir desactivar productos para conservar la trazabilidad.
6. **No fue posible demostrar el aislamiento entre dos negocios con pruebas reales**, porque la base revisada solo tiene un perfil y no tiene negocios, membresías, productos, pedidos ni postulaciones.

## 2. Hallazgos por rol

### 2.1 Técnico superior / propietario de plataforma

**Accesos confirmados en las políticas actuales:**

- Puede consultar perfiles de todos los usuarios mediante `profiles_select_self_or_owner`.
- Puede consultar todas las membresías mediante `memberships_select_self_admin_owner`.
- Puede consultar todos los registros de auditoría mediante `audit_logs_owner_or_business_admin_select`.
- Puede consultar métodos de pago de todos los negocios.
- Puede consultar movimientos financieros, gastos, costos de productos, costos de artículos de pedidos, detalles de reembolsos y solicitudes de cancelación.
- La política de actualización de `businesses` también incluye a `platform_owner`.
- Puede consultar pedidos y sus artículos mediante las políticas actuales.

**Evaluación:** este acceso es más amplio que la separación funcional solicitada. El técnico debe administrar negocios, cuentas, bloqueos, suspensiones y auditoría de la plataforma. No debería tener acceso rutinario a información comercial, financiera o personal de los clientes de cada tienda desde consultas generales del panel técnico.

El borrador `database/security/business-admin-boundaries.sql` ya intenta retirar al propietario técnico de parte de los datos comerciales y financieros, y limita la actualización directa de la ficha del negocio al administrador de ese negocio. No obstante, el borrador todavía debe revisarse: no elimina el acceso del propietario técnico a `product_costs` ni a `order_item_costs`, y debe verificarse el alcance de `order_cancellation_requests`, `business_expenses`, `audit_logs` y `profiles`.

La función Edge `technical-business-management` de la rama aplica verificación de usuario, comprueba el perfil no bloqueado y exige MFA AAL2 para las acciones del propietario técnico. Sus operaciones de gestión de negocios y membresías usan RPC controladas. Esta es la vía adecuada para las acciones técnicas; no justifica conceder lectura directa de datos comerciales de todos los negocios.

### 2.2 Administrador del negocio

**Accesos confirmados:**

- Puede consultar y modificar la ficha comercial de los negocios donde tiene una membresía activa con rol `business_admin`.
- Puede administrar productos y costos de productos de su negocio.
- Puede consultar pedidos, artículos, costos de artículos y movimientos financieros de su negocio.
- Puede consultar y modificar gastos de su negocio.
- Puede administrar métodos de pago de su negocio.
- Puede consultar postulaciones de empleo asociadas a su negocio.
- Puede consultar las membresías de su negocio.
- Puede gestionar contenido comercial de su negocio.
- Puede leer los archivos del bucket privado de hojas de vida cuando la ruta coincide con las reglas de Storage.

**Riesgos y ajustes pendientes:**

- La política de lectura de `job_applications` comprueba la membresía de administrador, pero no llama a `private.business_is_active`. Debe impedirse el acceso a datos de postulantes cuando el negocio esté suspendido, salvo que se defina una excepción administrativa documentada.
- Las políticas de Storage para hojas de vida sí comprueban que el negocio esté activo, por lo que puede existir una diferencia entre la lectura de los datos de la postulación y la descarga de su archivo.
- La política de lectura de `business_content_pages` incluye al propietario técnico y al administrador, pero no exige que el negocio esté activo para la lectura privada del administrador.
- La eliminación de productos debe sustituirse por desactivación o archivado reversible, manteniendo el historial de pedidos.

### 2.3 Empleados

**Accesos confirmados:**

- Pueden consultar pedidos y artículos de su negocio activo.
- Pueden actualizar las columnas autorizadas de estado y seguimiento del pedido.
- La base tiene un disparador que valida las transiciones de estado y otro que registra los cambios de estado.
- Pueden consultar productos activos del catálogo y productos de su propio negocio, incluso cuando estos no estén activos.
- Pueden consultar solicitudes de cancelación bajo la política actual.
- No tienen las políticas de administrador para consultar postulaciones, costos de productos, gastos, métodos de pago ni movimientos financieros.

**Riesgo principal:** la concesión de lectura de `orders` es común a los roles autenticados, y la política permite a administrador y empleado leer la fila completa. Los permisos de columna actuales incluyen `customer_email`, `customer_phone`, `delivery_address`, `delivery_notes`, `total` y otros campos. Para preparar y entregar pedidos, el empleado puede necesitar nombre, teléfono, dirección y notas de entrega; el correo electrónico y algunos campos financieros no son necesarios para todos los empleados.

PostgreSQL no permite que una política RLS oculte columnas distintas según el rol de una membresía cuando ambos usuarios comparten el rol SQL `authenticated`. La solución debe diseñarse con cuidado: por ejemplo, una interfaz de lectura operativa controlada para empleados y acceso administrativo separado, retirando el acceso directo amplio cuando el nuevo flujo esté listo. No basta con ocultar campos en JavaScript.

## 3. Hallazgos técnicos confirmados

### 3.1 Ficha del negocio: el técnico puede modificar datos comerciales

La política `businesses_admin_update` permite actualizar al propietario de plataforma o al administrador del negocio. Los permisos por columna actuales permiten a `authenticated` actualizar campos comerciales como nombre, categoría, descripción, ciudad, teléfono, logo, horarios, tarifa de domicilio y pedido mínimo. El campo `status` no aparece entre las columnas concedidas para actualización directa.

Esto limita cambios de estado por SQL directo, pero **no evita que el técnico modifique la configuración comercial**. El borrador de límites del negocio elimina al propietario técnico de esa política y conserva el flujo técnico mediante RPC/Edge Function para suspender o reactivar negocios.

### 3.2 Pedidos y datos personales de clientes

La política `orders_members_select` deja leer pedidos al administrador y al empleado del negocio activo. Los permisos de columna de lectura incluyen correo, teléfono, dirección y notas del cliente. El permiso de actualización directo está limitado a `status` y `delivery_tracking`, y existen disparadores para validar y auditar cambios de estado.

**Corrección recomendada:** definir los campos mínimos que necesita cada tipo de empleado y ofrecer lectura operativa limitada, evitando que el correo electrónico y los datos no necesarios queden disponibles para todos los empleados. Mantener el acceso del administrador solo hasta el alcance que realmente necesite para gestionar pedidos y atención al cliente.

### 3.3 Postulaciones y hojas de vida

- `job_applications` permite lectura al administrador del negocio, no al empleado.
- La política de lectura no comprueba que el negocio esté activo.
- El bucket `job-applications-private` está configurado como privado, con límite de 5 MB y tipos PDF, DOC y DOCX.
- La política actual de lectura del bucket comprueba negocio activo y membresía de administrador, pero no valida completamente que el objeto corresponda a una postulación concreta mediante la ruta registrada en `job_applications.resume_path`.
- El borrador `database/security/storage-policy-fix.sql` añade comprobaciones de la estructura de ruta, UUID de la postulación, nombre de archivo y coincidencia con `resume_path`. Es un borrador, no está aplicado.

**Corrección recomendada:** exigir negocio activo tanto para leer la postulación como para descargar su hoja de vida; vincular cada objeto a una postulación de ese negocio; conservar el bucket privado y los enlaces firmados de corta duración.

### 3.4 Imágenes de negocios y productos

El bucket `business-assets` es público, tiene límite de 5 MB y acepta PNG, JPEG y WEBP. La lectura pública de los objetos es coherente con un catálogo visible para clientes, pero la administración de archivos debe quedar limitada al administrador del negocio correspondiente.

Las políticas actuales `business_assets_admin_upload`, `business_assets_admin_read`, `business_assets_admin_update` y `business_assets_admin_delete` contienen la referencia incorrecta `storage.foldername(b.name)`. La ruta debe derivarse de `storage.objects.name`. El borrador `database/security/storage-policy-fix.sql` corrige esta referencia y limita las rutas a `<business_uuid>/logo/<archivo>` o `<business_uuid>/products/<archivo>`.

### 3.5 Datos financieros y métodos de pago

El propietario técnico tiene lectura directa de `financial_transactions`, `business_expenses`, `product_costs`, `order_item_costs`, `refund_details` y `business_payment_methods`. En varios casos también puede consultar solicitudes de cancelación. Esto supera el alcance de un panel técnico centrado en gestión de cuentas y negocios.

El borrador actual retira al propietario técnico de `financial_transactions` y `refund_details`, y retira su acceso a métodos de pago. Debe ampliarse y probarse para cubrir también costos de productos, costos de artículos, gastos, solicitudes de cancelación y cualquier tabla financiera adicional. La gestión técnica de plataforma debe operar mediante funciones explícitas, con datos mínimos y registro de auditoría.

### 3.6 Perfiles y membresías

- Un usuario puede leer y actualizar su propio perfil.
- El propietario técnico puede leer todos los perfiles y todas las membresías.
- Un administrador puede consultar las membresías de su negocio.
- Un empleado puede consultar su propia membresía.
- Los permisos de actualización de `profiles` solo incluyen nombre visible, teléfono y avatar; no incluyen `platform_role` ni `is_blocked`. Esto evita que un usuario eleve su rol o se quite el bloqueo mediante la actualización ordinaria del perfil.

El acceso global del técnico a perfiles incluye teléfonos y otros datos del perfil. Se recomienda limitar las columnas visibles en el panel técnico a lo necesario para identificar y administrar cuentas, sin mostrar datos personales que no sean necesarios.

### 3.7 Eliminación de productos y solicitudes de cancelación

- La política actual `products_admin_delete` permite que el administrador elimine productos directamente. Debe retirarse el borrado directo y utilizar desactivación reversible para no romper el historial.
- La política actual `cancellation_members_select` permite al propietario técnico, administrador y empleado consultar solicitudes de cancelación. El borrador propone que la bandeja de solicitudes sea exclusiva del administrador, mientras que el empleado puede iniciar una solicitud mediante una operación controlada. Se debe verificar el flujo completo antes de aplicar ese cambio.

## 4. Funciones y controles de seguridad

- `private.has_business_role`: verifica usuario autenticado, negocio, membresía activa, perfil no bloqueado y rol permitido.
- `private.business_is_active`: verifica que el negocio esté en estado activo.
- `private.is_platform_owner`: comprueba el rol técnico y que el perfil no esté bloqueado.
- Las tres funciones consultadas usan `SECURITY DEFINER` dentro del esquema `private` y fijan `search_path` vacío. Deben seguir fuera de los esquemas expuestos y conservar permisos de ejecución mínimos.
- El flujo de cambios de estado de pedidos tiene un disparador de validación y otro de auditoría.
- La Edge Function técnica de la rama comprueba el usuario con Auth y exige AAL2 para las acciones del propietario técnico.
- La función pública de postulaciones usa una clave de servicio en servidor y registra el consentimiento como booleano; la autorización y el tratamiento de datos deben seguir revisándose en la auditoría de privacidad correspondiente.

## 5. Supabase Security Advisor

La revisión actual devuelve:

- **WARN — Leaked Password Protection Disabled:** está desactivada la protección que compara contraseñas con filtraciones conocidas. Se recomienda habilitarla en Auth.
- **INFO — RLS Enabled No Policy:** tres tablas tienen RLS habilitado sin políticas: `private.checkout_rate_limits`, `public.job_application_rate_limits` y `public.job_application_upload_sessions`.

El aviso INFO no demuestra por sí solo una exposición. Las tablas de límites y sesiones deben permanecer inaccesibles por consultas directas de `anon` y `authenticated`; las operaciones necesarias deben pasar por las funciones de servidor. Antes de modificar políticas, se deben comprobar los permisos SQL efectivos y los flujos Edge que las utilizan.

Referencias:
- [Advisor: tablas con RLS sin políticas](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)
- [Protección de contraseñas y contraseñas filtradas](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)

## 6. Estado de los datos y limitaciones de la auditoría

Conteos consultados en el proyecto independiente:

| Tabla | Filas |
|---|---:|
| profiles | 1 |
| businesses | 0 |
| business_memberships | 0 |
| products | 0 |
| orders | 0 |
| job_applications | 0 |

No hay datos suficientes para realizar pruebas de aislamiento con dos negocios, ni para verificar permisos efectivos con usuarios reales de tipo administrador y empleado. Tampoco se han realizado pruebas de navegador o llamadas autenticadas con cuentas de prueba de cada rol.

Por tanto, este documento registra hallazgos de configuración y código, no certifica que los controles funcionen correctamente en escenarios reales. Las pruebas pendientes deben usar datos ficticios y cuentas controladas en un entorno de pruebas independiente.

## 7. Plan de corrección recomendado

**Prioridad crítica**
1. Corregir las cuatro políticas de Storage de `business-assets` para que comparen el UUID de negocio con la ruta de `storage.objects.name`.
2. Restringir la lectura de postulaciones al administrador de un negocio activo y vincular la lectura de hojas de vida a una postulación y ruta exactas.
3. Reducir los datos personales visibles para empleados en pedidos, especialmente el correo electrónico, mediante una interfaz de lectura limitada y permisos SQL coherentes.
4. Retirar al técnico el acceso directo a datos financieros y métodos de pago de los negocios, manteniendo operaciones técnicas específicas y auditadas.

**Prioridad alta**
5. Limitar la actualización directa de la ficha comercial al administrador del negocio; el técnico debe gestionar estados y accesos mediante operaciones técnicas controladas.
6. Retirar al técnico de la lectura de costos de productos, costos de artículos y gastos comerciales, salvo que exista una necesidad justificada y una operación específica.
7. Sustituir la eliminación directa de productos por desactivación reversible.
8. Limitar la bandeja de cancelaciones al administrador y permitir al empleado únicamente iniciar solicitudes controladas.
9. Reducir los campos personales visibles al técnico en perfiles.

**Antes de considerar terminado**
10. Verificar permisos SQL y políticas para cada tabla, vista, RPC y bucket.
11. Probar con dos negocios ficticios: administrador A, empleado A, administrador B, empleado B, propietario técnico y cliente.
12. Comprobar intentos cruzados de lectura, inserción, actualización, eliminación, descarga de CV y cambio de estado.
13. Repetir Security Advisor y pruebas automatizadas después de aplicar los cambios en un entorno autorizado.

## 8. Estado de cambios

Este documento es el único artefacto creado por esta auditoría. Se guardó en la rama `correcciones-funcionales`. No se modificó `main`, no se fusionaron solicitudes de cambio, no se ejecutaron SQL de escritura, no se desplegaron funciones y no se publicaron cambios en GitHub Pages.

**Resultado:** auditoría documental de acceso a datos completada; correcciones y pruebas funcionales pendientes.
