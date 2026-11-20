# Auditoría de RPC, Edge Functions y políticas RLS

**Fecha:** 20 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Alcance:** revisión estática de los borradores SQL y verificadores. No se ejecutó SQL, no se desplegaron Edge Functions y no se modificó Supabase activo.

## ACC-18 — El helper de propiedad de pedidos no respetaba el bloqueo global

### Hallazgo
La política `order_items_customer_select_own` utiliza `private.customer_owns_order(uuid)` para permitir que un cliente autenticado lea las líneas de sus propios pedidos. La función comprobaba la coincidencia entre `orders.customer_user_id` y `auth.uid()`, pero no consultaba `profiles.is_blocked`.

El RPC `get_customer_order_history()` sí rechazaba perfiles bloqueados. Por tanto, ambos caminos de lectura tenían controles distintos: una cuenta globalmente bloqueada podía no obtener el historial por RPC, pero todavía podía superar la política de lectura de líneas si conservaba una sesión autenticada.

### Corrección en la rama
Se modificó `private.customer_owns_order(uuid)` para unir `public.profiles` y exigir `p.is_blocked = false`, además de verificar que el pedido pertenece al usuario autenticado.

Se reforzó `database/orders/verify-order-financial-access.sql` para comprobar que la definición instalada del helper incluye ese control.

**Archivos:**
- `database/orders/order-financial-access-draft.sql`
- `database/orders/verify-order-financial-access.sql`

**Commits:**
- Corrección del helper: `eba34bd33c71a2dfe415b4ee66f83d358833714a`
- Verificador: `3613495e56c3fee923c6f819d39fb35d041d5a8e`

## ACC-19 — El verificador no exigía que el helper general de roles excluyera perfiles bloqueados

### Hallazgo
Los borradores de RLS y varias funciones usan `private.has_business_role(uuid,text[])` como control común de membresía. Su definición no está incluida entre los archivos SQL de esta rama; el paquete presupone que existe previamente en el esquema.

El verificador comprobaba que el helper exigiera `business_memberships.status = 'active'`, pero no exigía que rechazara perfiles con `profiles.is_blocked = true`. Esto dejaba sin una condición verificable un control transversal importante.

### Corrección en la rama
Se reforzó `database/integration/verify-integration-package.sql` para exigir que la definición instalada de `private.has_business_role(uuid,text[])` compruebe también que el perfil no esté bloqueado globalmente. Si no cumple, el verificador debe fallar.

**Importante:** esto no modifica la definición instalada de `has_business_role`. Como esa función no está incluida en los borradores del repositorio, su definición real debe inspeccionarse en staging y corregirse allí, si hace falta, antes de aprobar el paquete.

**Commit del verificador:** `3a1c65c74cbaae3c8677d07d6a3a28443de83dac`

## Controles revisados

- Las RPC técnicas de membresías y negocios se declaran `SECURITY INVOKER`, fijan `search_path = ''` y se conceden a `service_role`, no a `anon` ni a `authenticated`. La Edge Function valida la identidad, el perfil y MFA del propietario antes de invocarlas.
- Las RPC de invitación están restringidas a `service_role`; la tabla de invitaciones no concede lectura ni escritura a los roles cliente.
- Las RPC financieras y de cancelación usan `SECURITY DEFINER` cuando necesitan leer o actualizar datos retirados del acceso directo. Las funciones consultadas fijan `search_path = ''`, obtienen el actor con `auth.uid()`, validan rol/negocio y revocan ejecución a `PUBLIC` y `anon`.
- El helper `private.is_platform_owner_mfa()` exige perfil propietario no bloqueado y claim JWT `aal2`; se usa para proteger las políticas del propietario.
- Los permisos por columna retiran del Data API los importes y estados financieros para empleados; las finanzas del administrador se entregan por RPC con autorización de negocio.

## Límites y pruebas pendientes

1. La inspección es estática. No confirma permisos efectivos en PostgreSQL ni el estado real de las políticas activas.
2. Debe obtenerse en staging la definición de `private.has_business_role` y `private.business_is_active`, revisar su propietario, `prosecdef`, `search_path`, ACL y comportamiento con perfiles bloqueados.
3. Verificar que ninguna función `SECURITY DEFINER` tenga EXECUTE para `PUBLIC` o `anon`, y que las funciones privadas solo sean ejecutables por los roles necesarios.
4. Probar llamadas directas con JWT de anon, cliente, empleado, administrador de otro negocio, administrador del negocio y propietario con AAL1/AAL2.
5. Probar cuenta bloqueada con una sesión todavía válida: lectura de perfil, pedidos, líneas, favoritos, RPC financieras, RPC de cancelación, inventario y Edge Functions.
6. Probar RLS con IDs conocidos de otro negocio y con parámetros manipulados.
7. Confirmar que `service_role` no se expone en navegador ni se usa desde código cliente.
8. Ejecutar los verificadores SQL solo en staging después de aplicar allí los borradores aprobados.

## Conclusión

Se corrigió un camino de lectura de líneas de pedidos que no respetaba el bloqueo global y se reforzó el verificador del helper común de roles. La autorización efectiva aún no puede aprobarse: falta inspeccionar las definiciones instaladas de los helpers y ejecutar pruebas de Data API/RLS en un proyecto de staging aislado. La base activa permanece sin cambios.
