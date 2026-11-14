# Auditoría de permisos del servidor — MiEje Market

**Fecha:** 14 de noviembre de 2026  
**Rama revisada:** `correcciones-funcionales`  
**Proyecto Supabase inspeccionado:** MiEje Market Independiente (`cqixlrwbqatbhzmpygiz`)  
**Alcance:** perfiles bloqueados, membresías suspendidas, negocios suspendidos, pedidos, productos, inventario y datos financieros.

## Resultado ejecutivo

La autorización de las operaciones sensibles está respaldada por RLS, privilegios de columnas, funciones SQL y validaciones en Edge Functions. La función `private.has_business_role` exige que la membresía pertenezca al usuario autenticado, esté activa, tenga uno de los roles permitidos y que el perfil no esté bloqueado. `private.business_is_active` comprueba que el negocio esté activo.

Sin embargo, **la base de datos inspeccionada todavía concede al propietario técnico acceso directo a datos comerciales y operativos de los negocios**. Esto contradice la separación funcional acordada: el panel técnico administra negocios, usuarios y accesos, pero no debe consultar ni modificar directamente los datos comerciales de cada tienda.

La corrección correspondiente ya está preparada en `database/security/business-admin-boundaries.sql`, pero el estado observado en Supabase demuestra que todavía no está aplicada. Por tanto, la separación no puede considerarse terminada en producción.

## Controles verificados

### 1. Perfil bloqueado y membresía suspendida

- `private.has_business_role(p_business_id, p_roles)` verifica `auth.uid()`, `business_memberships.status = 'active'`, rol permitido y `profiles.is_blocked = false`.
- `private.is_platform_owner()` también exige que el perfil propietario no esté bloqueado.
- `resolve-my-access` rechaza perfiles ausentes o bloqueados y solo devuelve membresías activas de negocios activos.
- `technical-business-management` valida el token con `auth.getUser`, consulta el perfil en servidor y rechaza perfiles bloqueados. Las acciones técnicas exigen el rol `platform_owner`; el propietario también debe tener AAL2.
- La suspensión de una membresía es específica del negocio. No debe cerrar globalmente la sesión ni revocar otras membresías válidas.

**Resultado:** los helpers y las funciones de acceso aplican la distinción entre bloqueo global y suspensión por negocio.

### 2. Pedidos

- RLS limita la lectura de pedidos a miembros activos del negocio y al propietario técnico.
- El permiso SQL de actualización de `orders` para `authenticated` se limita a las columnas `status` y `delivery_tracking`; no concede actualización directa de importes, datos del cliente ni estado de pago.
- El trigger `private.enforce_order_status_transition()` exige usuario autenticado, rol activo del negocio o propietario técnico, y valida la transición de estado. Para cancelar exige una solicitud aprobada por el mismo usuario.
- La función pública de checkout valida el negocio activo, el método de pago perteneciente a ese negocio, el perfil del cliente autenticado y el inventario. La creación se realiza en funciones SQL idempotentes y transaccionales.

**Observación:** el trigger actual todavía permite al propietario técnico modificar estados de pedidos. El borrador de límites de administrador sustituye ese comportamiento y reserva la operación a administradores y empleados activos del negocio.

### 3. Productos e inventario

- RLS exige rol `business_admin` para insertar, modificar o eliminar productos.
- Los empleados tienen lectura operativa, pero no reciben permisos de escritura sobre productos.
- Los productos públicos requieren estar activos y pertenecer a un negocio activo.
- El checkout bloquea las filas de producto y descuenta inventario dentro de la transacción de creación del pedido.

**Observación:** la política actual de lectura autenticada permite al propietario técnico consultar productos de todos los negocios. El borrador elimina ese acceso directo. El propietario técnico conserva la gestión técnica mediante funciones autorizadas.

### 4. Finanzas y costos

- Las funciones `register_business_expense`, `pay_business_expense` y `void_business_expense` validan sesión, negocio activo y rol administrador del negocio.
- La política de actualización de gastos está acompañada por el trigger `private.guard_business_expense_update()`, que impide editar libremente los registros y limita las operaciones admitidas.
- El acceso de escritura a gastos no se concede a empleados.
- Los privilegios de columnas de `profiles` solo permiten al usuario actualizar `avatar_url`, `display_name` y `phone`; no puede cambiar su propio rol ni su estado de bloqueo.

**Hallazgo pendiente de corregir:** las políticas actuales todavía incluyen al propietario técnico en la lectura de `business_expenses`, `financial_transactions`, `refund_details`, `product_costs` y `order_item_costs`. También tiene lectura sobre métodos de pago y solicitudes de cancelación. El borrador de límites elimina estos accesos globales directos.

### 5. Negocios y configuración comercial

- Los permisos de columna actuales de `businesses` no incluyen `status` para actualización autenticada, por lo que el administrador comercial no puede suspender o cerrar directamente el negocio mediante esa columna.
- No obstante, la política actual `businesses_admin_update` todavía incluye al propietario técnico y permite que este modifique directamente campos comerciales del negocio.
- Las políticas actuales de `business_payment_methods` también incluyen al propietario técnico.

**Hallazgo pendiente:** aplicar la política del borrador para que solo el administrador activo del negocio modifique su ficha comercial y sus métodos de pago. La gestión técnica del estado del negocio debe permanecer en la Edge Function técnica.

## Corrección preparada y pendiente

Archivo existente en la rama: `database/security/business-admin-boundaries.sql`.

El borrador contiene, entre otras medidas:

1. Retirar el bypass del propietario técnico en las políticas de negocios, productos, pedidos, costos, gastos, pagos, contenido y reembolsos.
2. Limitar la configuración comercial y los métodos de pago al administrador activo de cada negocio.
3. Limitar pedidos y sus líneas a miembros activos del negocio.
4. Retirar el bypass técnico del trigger de transición de estado de pedidos.
5. Mantener la gestión técnica mediante Edge Functions que validan identidad, rol y MFA.

**No se ejecutó el SQL ni se modificó el proyecto Supabase.** Antes de aplicar el borrador hay que revisar la migración completa, comprobar grants y dependencias, ejecutar pruebas con cuentas de propietario, administrador, empleado y cliente, y verificar que las funciones técnicas sigan pudiendo administrar negocios y accesos sin acceso directo al contenido comercial.

## Pruebas pendientes antes de declarar la seguridad terminada

- Perfil bloqueado: no puede leer ni modificar datos privados de ningún negocio.
- Membresía suspendida en A: pierde acceso a A, pero conserva una membresía activa en B.
- Negocio suspendido: sus miembros no pueden leer ni modificar pedidos, productos, inventario ni finanzas operativas.
- Empleado: puede consultar y gestionar solo las operaciones permitidas; no puede modificar catálogo, costos, pagos o configuración financiera.
- Administrador A: no puede consultar ni modificar datos de B.
- Propietario técnico: puede administrar negocios, usuarios, membresías, auditoría y moderación desde la función técnica, pero no consultar pedidos, catálogo, costos, pagos o finanzas privadas mediante el Data API.
- Cliente: no puede consultar pedidos ni datos de otros clientes.
- Checkout público: sigue creando pedidos solo para negocios activos, recalcula importes en servidor y descuenta inventario una sola vez.
- Transiciones de pedidos y cancelaciones: solo se realizan con el rol correcto y la solicitud aprobada correspondiente.

## Estado

- Auditoría de código y políticas actuales: **realizada**.
- Hallazgo principal: **bypass de lectura y configuración comercial del propietario técnico todavía presente en la base de datos observada**.
- Borrador de corrección: **ya existe en la rama**.
- Migración aplicada en Supabase: **no**.
- Pruebas de extremo a extremo con usuarios de cada rol: **pendientes**.
- Despliegue de Edge Functions o publicación: **no realizado**.
