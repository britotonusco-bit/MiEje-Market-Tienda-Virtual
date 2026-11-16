# Auditoría estática de funciones SQL y dependencias — MiEje Market

**Fecha:** 16 de noviembre de 2026  
**Rama revisada:** `correcciones-funcionales`  
**Proyecto objetivo:** MiEje Market Independiente (`cqixlrwbqatbhzmpygiz`)  
**Estado:** revisión estática de borradores; no ejecutada en base de datos.

## 1. Resultado

Se revisaron las funciones SQL de los módulos de membresías, permisos de negocio, inventario, checkout, pedidos, finanzas, IA, bloqueos, postulaciones y comprobantes.

Los patrones principales de seguridad están correctamente planteados en los borradores:

- Las funciones `SECURITY DEFINER` revisadas fijan un `search_path` vacío (`SET search_path = ''` o `SET search_path TO ''`) y califican los objetos con su esquema.
- Las RPC que requieren identidad de cliente o miembro comprueban `auth.uid()` y validan la membresía y el negocio activo.
- Las RPC técnicas que reciben `p_actor_id` están limitadas a `service_role`. La Edge Function obtiene el usuario mediante `auth.getUser(token)`, comprueba el rol desde `profiles` y exige AAL2 para el propietario técnico antes de llamar a esas RPC. El identificador enviado a las RPC se deriva de `user.id`, no de `body`.
- Las funciones internas de trigger y las RPC técnicas revocan la ejecución a `PUBLIC`, `anon` y/o `authenticated` según el contrato previsto.
- Las funciones de cancelación accesibles a `authenticated` comprueban la identidad real con `auth.uid()` y validan el rol activo del negocio.

Esto es una revisión de código. No demuestra que los permisos efectivos, las firmas o las dependencias compilen y funcionen en PostgreSQL; esa confirmación requiere un entorno de ensayo.

## 2. Correcciones realizadas en la rama

### 2.1 Normalización de estados de pedido

Antes, los pasos 2 y 11 repetían:
- la conversión de estados históricos `pending` y `out_for_delivery`;
- la actualización de la restricción `orders_status_check`;
- la sustitución de `private.enforce_order_status_transition()`.

Además, el paso 2 actualizaba pedidos históricos sin desactivar temporalmente el trigger existente. Si el trigger anterior rechazaba esa transición, la migración podía fallar.

**Corrección:**
- `database/security/business-admin-boundaries.sql` ahora desactiva el trigger `orders_enforce_status_transition` solo durante la conversión histórica, lo reactiva inmediatamente y agrupa la conversión, la restricción y el valor por defecto en una transacción.
- `database/inventory/checkout-inventory-lock-order-draft.sql` ya no repite la normalización ni la función de transición. Se limita a sustituir el checkout y etiquetar los movimientos de inventario de venta.

La función de transición queda definida en un solo lugar: el paso 2. El paso 11 conserva su propia transacción para el reemplazo del checkout.

### 2.2 Dependencia del módulo de gastos

El encabezado de `database/finance/business-expense-audit-draft.sql` apuntaba a `business-expense-receipts-draft.sql`, nombre inexistente.

Se corrigió para referenciar el archivo real: `database/finance/expense-receipts-storage-draft.sql`.

## 3. Revisión de identidad y permisos de RPC

| Grupo | Patrón revisado | Resultado estático |
|---|---|---|
| Membresías técnicas | `SECURITY INVOKER`, `search_path` vacío, ejecución solo para `service_role`, validación de actor propietario no bloqueado | Correcto en el borrador; depende de que Edge valide la sesión y MFA |
| Finanzas y nómina de plataforma | `SECURITY INVOKER`, actor validado contra `profiles`, ejecución solo para `service_role` | Correcto en el borrador; no exponer la clave de servicio al navegador |
| Configuración global | RPC técnica con actor validado y permisos de ejecución restringidos | Correcto en el borrador |
| Métodos de pago | `SECURITY DEFINER`, `search_path` vacío, `auth.uid()`, rol de administrador y negocio activo | Correcto en el borrador |
| Ajustes de inventario | `SECURITY DEFINER`, `search_path` vacío, sesión autenticada y autorización por negocio | Correcto en el borrador; falta prueba de concurrencia |
| Checkout e idempotencia | Funciones privilegiadas restringidas a `service_role`; el navegador no debe invocarlas directamente | Correcto en el borrador; depende del contrato de la Edge Function |
| Historial y finanzas de pedidos | Funciones con `auth.uid()` y comprobación de propiedad/membresía | Correcto en el borrador; falta probar aislamiento A/B |
| Cancelaciones | Funciones para miembros autenticados con `auth.uid()`; la decisión exige administrador activo | Correcto en el borrador |
| Reembolsos y gastos | Funciones con `SECURITY DEFINER`, `search_path` vacío y validación de usuario/rol | Correcto en el borrador |
| Postulaciones y limpieza | Funciones privilegiadas limitadas a `service_role`; limpieza sin acceso desde el navegador | Correcto en el borrador; falta probar el proceso completo de Storage |
| Funciones internas | Funciones privadas de trigger con ejecución directa revocada | Correcto en el borrador |

### Límite importante de las RPC técnicas

Las RPC técnicas reciben `p_actor_id` porque se ejecutan con la credencial de servidor, donde `auth.uid()` no representa necesariamente al usuario final. Por eso no deben recibir llamadas directas del navegador ni aceptar un actor elegido por el cliente.

En la Edge Function revisada:
1. se extrae el token del encabezado `Authorization`;
2. se valida con `auth.getUser(token)`;
3. se consulta el perfil del mismo `user.id`;
4. se exige rol `platform_owner` y AAL2 para acciones técnicas;
5. se pasa `user.id` como `p_actor_id`.

Este flujo debe mantenerse. Cualquier futura acción técnica debe seguir el mismo patrón y no confiar en un identificador incluido en el JSON de entrada.

## 4. Data API, GRANT y RLS

Supabase documentó que las tablas nuevas de `public` requieren permisos explícitos para quedar accesibles por Data API después del cambio anunciado para el 30 de octubre de 2026. Los GRANT y RLS cumplen funciones distintas: el GRANT permite acceder al objeto y RLS limita las filas.

En los borradores revisados se encontraron GRANT explícitos para las tablas y RPC que los consumen los paneles, las funciones Edge o los clientes. La revisión de integración ya advierte que no se debe conceder acceso a `anon` o `authenticated` solo para resolver un error de exposición. Debe comprobarse en staging la exposición real de cada objeto, junto con sus grants y políticas.

Referencia oficial: https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically

## 5. Dependencias consolidadas

La secuencia de integración mantiene el siguiente orden esencial:

1. Configuración pública global.
2. Límites RLS, grants y estados canónicos del negocio.
3. RPC transaccionales de membresías.
4. Finanzas/nómina de plataforma, configuración IA, solicitudes de bloqueo y políticas de Storage.
5. Cuenta de cliente y favoritos.
6. Movimientos de inventario.
7. Métodos de pago atómicos.
8. Checkout con bloqueo de inventario.
9. Idempotencia de checkout.
10. Acceso financiero e historial de pedidos.
11. Cancelaciones y reembolsos.
12. Comprobantes de gastos y RPC de gastos.
13. Limpieza de postulaciones.

El orden detallado y las dependencias específicas permanecen en `database/integration/README.md`. MFA del propietario continúa como etapa separada y condicionada a que la interfaz y la Edge Function AAL2 estén probadas.

## 6. Verificaciones realizadas y pendientes

**Verificado estáticamente en GitHub:**
- La normalización de estados ya no aparece en el paso 11.
- La función `private.enforce_order_status_transition()` queda definida en el paso 2.
- El paso 2 desactiva y reactiva el trigger alrededor de la conversión histórica.
- La referencia del archivo de comprobantes coincide con el nombre real.
- Las RPC técnicas de membresías revocan ejecución a roles públicos y la conceden a `service_role`.
- La Edge Function deriva `p_actor_id` de la sesión validada y exige AAL2 al propietario técnico.

**Pendiente en un entorno de ensayo:**
- Ejecutar cada migración por separado y comprobar que compila.
- Ejecutar `verify-integration-package.sql` y `verify-order-financial-access.sql`.
- Ejecutar Supabase Security Advisors y revisar la exposición de Data API.
- Probar aislamiento entre dos negocios, roles de cliente/empleado/administrador/técnico y acciones no autorizadas.
- Probar dos compras simultáneas de la última unidad, reintentos idempotentes, cancelación, restitución de inventario y reembolso.
- Probar MFA AAL2 y todos los flujos Edge con cuentas ficticias.
- Verificar que los archivos privados de CV y comprobantes no puedan descargarse desde otro negocio.

No se ejecutó SQL, no se desplegó ninguna Edge Function y no se cambió el proyecto Supabase activo.

## 7. Archivos modificados

- `database/security/business-admin-boundaries.sql`
- `database/inventory/checkout-inventory-lock-order-draft.sql`
- `database/finance/business-expense-audit-draft.sql`

**Dictamen:** se corrigieron la duplicación de la transición de pedidos y la referencia incorrecta de dependencia. La revisión estática de funciones no muestra una concesión pública evidente en las RPC privilegiadas examinadas; no obstante, el paquete sigue siendo un conjunto de borradores y no debe pasar a producción sin compilación y pruebas integrales en staging.
