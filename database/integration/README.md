# Paquete de integración — MiEje Market Independiente

**Estado: preparado para staging; NO aprobado para producción.**  
**Proyecto objetivo:** Supabase independiente `cqixlrwbqatbhzmpygiz` (`sa-east-1`).  
**Rama:** `correcciones-funcionales`.

Este paquete ordena los borradores existentes y define cómo probarlos. No aplica cambios por sí mismo. No ejecutar estos archivos en producción ni desde SQL Editor del proyecto live sin aprobación explícita.

## 1. Antes de empezar

1. Crear un proyecto Supabase de ensayo separado. No usar el proyecto original ni el proyecto independiente con datos reales como entorno de pruebas.
2. Confirmar el ref y región del proyecto de ensayo. Comprobar que no sea `ibnwejpbntvoujdawkwh` ni el proyecto de producción `cqixlrwbqatbhzmpygiz`.
3. Guardar una copia/backup recuperable del esquema y datos del entorno de ensayo.
4. Cargar únicamente datos ficticios: dos negocios activos (A y B), uno suspendido, administrador A, empleado A, administrador B, cliente A, cliente B y propietario técnico con MFA.
5. Ejecutar primero `00-preflight.sql` y guardar sus resultados.
6. Si alguna dependencia base falta, detenerse y corregirla antes de seguir. No improvisar cambios en producción.

## 2. Orden de aplicación en staging

Cada archivo es una unidad independiente. Ejecutar uno a uno, revisar el resultado y detenerse si hay un error.

| Orden | Archivo | Motivo/dependencia |
|---:|---|---|
| 1 | `database/platform/platform-public-settings-draft.sql` | Crea la tabla de configuración pública global que necesita la función de ajustes de plataforma. |
| 2 | `database/security/business-admin-boundaries.sql` | Endurece RLS, grants, límites por negocio, perfiles, membresías y trigger de último administrador. Debe quedar antes de las pruebas de roles y de los flujos posteriores. |
| 3 | `database/platform/platform-finance-payroll-draft.sql` | Crea el libro interno de movimientos de la plataforma y obligaciones de nómina; acceso exclusivo del servidor técnico con MFA. No ejecuta transferencias. |
| 4 | `database/ai/ai-settings-draft.sql` | Crea la configuración de IA separada por negocio y la configuración global privada; requiere helpers de autorización y usa Edge Function con AAL2 para la IA global. |
| 5 | `database/security/access-block-requests-draft.sql` | Crea solicitudes de bloqueo por negocio y una RPC transaccional que solo puede ejecutar la Edge Function técnica; requiere helpers, membresías y auditoría base. |
| 6 | `database/security/storage-policy-fix.sql` | Repara políticas de Storage; requiere buckets ya creados y helpers de autorización disponibles. |
| 7 | `database/customers/customer-account-migration.sql` | Crea `orders.customer_user_id` y favoritos; es dependencia de checkout e historial. |
| 8 | `database/orders/checkout-idempotency-draft.sql` | Depende de la columna anterior, de `create_public_order`, de los helpers/rate-limit existentes y de `extensions.digest`. Este archivo repite parte de la estructura de clientes con `IF NOT EXISTS`; la migración de clientes es la fuente de verdad y debe ejecutarse primero. |
| 9 | `database/orders/order-financial-access-draft.sql` | Depende de `orders.customer_user_id`, del esquema de checkout y de las tablas financieras existentes. Restringe columnas y crea RPCs de finanzas/historial. |
| 10 | `database/orders/cancellation-flow-draft.sql` | Depende del esquema de pedidos, las membresías/helpers y del trigger de transición instalado por la migración de límites de negocio. |
| 11 | `database/orders/refund-flow-draft.sql` | Depende de cancelaciones aprobadas y de las tablas `financial_transactions`, `refund_details` y auditoría. |

### Endurecimiento MFA del propietario: etapa separada y condicionada

`database/security/owner-mfa-rls.sql` NO forma parte de la primera pasada SQL. Solo aplicarla después de que:
- la interfaz MFA esté publicada en el entorno de ensayo;
- `technical-business-management` desplegada en ese entorno exija AAL2 antes de cada acción sensible;
- el inicio de sesión del propietario, el TOTP y la recuperación estén probados;
- se haya confirmado que no existe una vía de acceso técnico que dependa de un JWT AAL1.

Aplicarla antes de cumplir estas condiciones puede bloquear el acceso del propietario sin que el flujo MFA esté disponible.

## 3. Funciones Edge y configuración

Después de aplicar las migraciones necesarias en staging, desplegar desde esta misma revisión de código, no desde `main`:
- `technical-business-management` (MFA/AAL2);
- `resolve-my-access`;
- `create-public-order` (idempotencia y clave publishable);
- `get-public-storefront`;
- `track-public-order`;
- `create-job-application`;
- `get-platform-public-settings`.

Usar `supabase/config.toml` de esta rama para los valores `verify_jwt`. Antes de desplegar, comprobar secrets del proyecto de ensayo. Nunca copiar ni mostrar service-role keys. No enviar invitaciones ni correos a usuarios reales.

La URL de invitación no se debe probar contra GitHub Pages de producción: `main` aún usa el proyecto Supabase antiguo. Preparar un sitio de ensayo con `supabase-config.js` apuntando al proyecto de ensayo y permitir su URL exacta en Auth Redirect URLs.

## 4. Verificación después de SQL

Ejecutar `verify-integration-package.sql`. Debe terminar sin excepciones. Guardar la salida junto con los resultados de las pruebas manuales. Si falla, detener despliegue y corregir el archivo responsable en la rama.

`verify-order-financial-access.sql` es una comprobación adicional específica de grants financieros; ejecutarla después de `order-financial-access-draft.sql`.

## 5. Pruebas funcionales obligatorias

Usar `docs/security-role-test-matrix.md` como matriz principal. Prioridad mínima:

1. **Aislamiento y catálogo público:** admin A y empleado A no leen ni alteran datos de B; admin B no lee A; técnico no obtiene datos comerciales globales desde Data API. Un visitante anónimo puede consultar únicamente las columnas públicas de negocios activos/suspendidos, productos activos de negocios activos y publicaciones aprobadas; ninguna política anónima debe depender de helpers privados.
2. **Finanzas de plataforma y nómina:** solo el propietario técnico con MFA consulta y registra movimientos; los movimientos son inmutables; la nómina pasa una sola vez de pendiente a pagada o cancelada; al marcarla pagada se crea el gasto financiero y la auditoría en una sola transacción. Registrar un pago no ejecuta transferencias.
3. **Membresías, bloqueos e IA:** no se puede retirar, suspender o degradar al último administrador activo; dos operaciones concurrentes no dejan el negocio sin admin. Solo el administrador activo puede solicitar el bloqueo de otro miembro de su negocio; el técnico con MFA puede aprobar o rechazar, y la aprobación suspende solo esa membresía y deja auditoría. El administrador A solo configura la IA de A; el propietario con AAL2 administra la configuración global; empleados y clientes no pueden modificar ninguna configuración.
4. **Checkout:** invitado y cliente; método deshabilitado; producto inactivo; inventario insuficiente; clave repetida; misma clave con payload distinto; dos compras concurrentes por la última unidad.
5. **Historial/favoritos:** cliente A no accede a los datos de B; favorito de producto inactivo se rechaza; eliminar favorito propio funciona; eliminar cuenta conserva pedidos y limpia la relación.
6. **Finanzas de pedidos:** empleado no lee importes ni confirma pagos; admin solo ve su negocio; pagos duplicados y reembolsos duplicados se rechazan.
7. **Cancelación:** solicitud por empleado/admin, decisión solo admin, inventario se restaura exactamente una vez; pedido entregado no se cancela.
8. **Storage:** admin A carga/lee sus archivos; admin B no puede leer, reemplazar ni borrar archivos de A; visitante no lee documentos privados.
9. **Vacantes:** consentimiento, rate limit, expiración/reutilización de sesión, tamaño/tipo, acceso a postulaciones y URLs firmadas.
10. **MFA y acceso:** propietario AAL2; AAL1 rechazado en acciones técnicas; admin/empleado sin permisos técnicos; invitación y recuperación con correos de ensayo.
11. **Regresión UI:** página pública, login, tres paneles, pedidos, pagos, cuenta e invitaciones sin errores de consola ni respuestas 4xx/5xx inesperadas.

No se considera aprobado si solo pasan consultas SQL. Cada prueba debe registrar rol, negocio, acción, resultado esperado, resultado real y evidencia sin datos personales.

## 6. Criterios de salida para integrar

- Todos los SQL aplicados sin errores en staging.
- Verificador post-migración y verificador financiero aprobados.
- `platform-finance-payroll-draft.sql` añade movimientos financieros y nómina de plataforma; las tablas quedan reservadas a `service_role` y la Edge Function técnica valida propietario y MFA.
- Matriz de roles A/B sin cruces de datos.
- Checkout concurrente y reintentos sin pedidos ni descuentos duplicados.
- Cancelación y reembolso probados con inventario/finanzas ficticios.
- Funciones Edge desplegadas desde el mismo commit probado.
- Auth Redirect URLs, correos y MFA probados en sitio de ensayo.
- Cero errores críticos abiertos.
- Revisión final de diferencias contra `main` y contra el proyecto Supabase objetivo.

Solo entonces preparar el PR de integración. La fusión/publicación y cualquier SQL en producción requieren autorización explícita aparte.

## 7. Archivos del paquete

- `00-preflight.sql`: inventario de dependencias y estado previo, solo lectura.
- `verify-integration-package.sql`: comprobaciones posteriores, solo lectura.
- `verify-order-financial-access.sql`: verificador financiero de pedidos existente.
- `verify-integration-package.sql`: comprueba también tablas, RLS y grants del libro financiero y nómina.
- `docs/security-role-test-matrix.md`: matriz detallada de permisos y pruebas.

## Bloqueos confirmados en la auditoría de pedidos — 14/11/2026

- La Edge Function activa `create-public-order` es versión 3 y no implementa la clave idempotente que ya envía `app.js`. Antes de producción deben aplicarse las migraciones de clientes y checkout idempotente, y desplegarse la Edge Function de esta rama. Hasta entonces, un reintento tras perder la respuesta puede generar pedidos duplicados.
- La función activa de transición de estado y las políticas activas de `orders`/`order_items` conservan un bypass de `platform_owner`. La migración `business-admin-boundaries.sql` contiene la sustitución por membresías activas; el verificador ahora comprueba que no reaparezca el bypass.
- El panel ahora captura y muestra `delivery_tracking` al pasar un pedido a `out_for_delivery`. Esta modificación requiere que la rama se publique junto con las migraciones de permisos; no cambia el sitio publicado.
- La función activa `track-public-order` es versión 1. La versión de la rama agrega `Cache-Control: no-store, private`.
- La base activa no contiene datos de negocio/productos/pedidos para una prueba de compra y entrega real. Las pruebas de concurrencia, aislamiento A/B, cancelación y restitución de inventario siguen pendientes en un entorno de ensayo.

**No desplegar parcialmente:** el código idempotente de la Edge Function depende de las RPC y tablas creadas por las migraciones del paquete. No desplegar esa función antes de aplicar y verificar sus dependencias en un entorno de pruebas.

### RPC que todavía no están instaladas

La consulta read-only confirmó que faltan las RPC de idempotencia, historial de clientes, finanzas del administrador, confirmación de pago recibido, solicitud/decisión de cancelaciones y registro de reembolsos. Los paneles ya llaman a estos procedimientos, pero las funciones no existen en el proyecto activo. Aplicar el orden de migraciones de este documento y ejecutar el verificador antes de considerar operativos esos botones o módulos.

En particular, no confundir las tablas existentes (`orders`, `order_items`, `order_cancellation_requests`) con el flujo completo: sin sus RPC y triggers correspondientes, la interfaz no puede completar esas operaciones de forma segura.
