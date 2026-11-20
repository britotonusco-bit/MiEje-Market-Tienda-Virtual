# Procedimiento de pruebas de autenticación y seguridad en staging

**Proyecto:** MiEje Market  
**Rama de código:** `correcciones-funcionales`  
**Estado:** procedimiento preparado; ejecución pendiente de disponer de un proyecto Supabase aislado.

> Este procedimiento es exclusivamente para un proyecto de staging desechable o aislado. No usar credenciales, usuarios, datos ni claves del proyecto de producción. No ejecutar pruebas de suspensión, revocación, cambios de contraseña o MFA en producción.

## 1. Condiciones previas

Antes de comenzar, confirmar:

- [ ] Existe un proyecto Supabase independiente, creado para staging.
- [ ] Su URL y claves pertenecen inequívocamente al proyecto de staging.
- [ ] No comparte base de datos, usuarios Auth, buckets ni secretos con producción.
- [ ] La rama desplegada y las Edge Functions corresponden al commit que se va a probar.
- [ ] Las migraciones revisadas están aplicadas solo en staging.
- [ ] La plantilla de confirmación OTP está configurada en el Auth de staging.
- [ ] Las URLs de redirección de Auth apuntan al sitio de pruebas.
- [ ] Los correos de prueba llegan a buzones controlados.
- [ ] Se dispone de una copia/exportación de la configuración inicial de staging para reconstruir el entorno.
- [ ] Se registró el SHA del commit y la versión de las migraciones.

No continuar si no se puede distinguir con certeza el proyecto de staging del proyecto activo.

## 2. Cuentas de prueba

Crear manualmente en staging cuentas con direcciones de prueba controladas. No reutilizar cuentas personales ni cuentas de producción.

| Cuenta | Rol esperado | Preparación |
|---|---|---|
| STG-OWNER | platform_owner | Perfil propietario y factor TOTP habilitado |
| STG-ADMIN-A | business_admin | Membresía activa en negocio A |
| STG-EMP-A | employee | Membresía activa en negocio A |
| STG-ADMIN-B | business_admin | Membresía activa en negocio B |
| STG-EMP-SUSP | employee | Membresía suspendida en negocio A |
| STG-USER-NO-MEMBER | Sin membresías | Cuenta Auth confirmada sin asignación |
| STG-USER-BLOCKED | Perfil bloqueado | Cuenta Auth confirmada con perfil bloqueado |
| STG-INVITE-PENDING | Invitación pendiente | Cuenta Auth confirmada o no confirmada según caso |

Usar contraseñas únicas de prueba y un gestor seguro. No escribir contraseñas, OTP, recovery codes, access tokens, refresh tokens ni service role keys en el informe o capturas.

## 3. Prueba de aislamiento de roles y negocios

Para cada cuenta:

1. Iniciar sesión desde una ventana privada separada.
2. Consultar la ruta de acceso mediante la aplicación.
3. Intentar acceder a la URL de cada panel directamente.
4. Intentar solicitar datos del negocio A y del negocio B desde las herramientas de red del navegador.
5. Repetir las consultas directamente contra el Data API con la sesión de esa cuenta.
6. Registrar status HTTP, cantidad de filas devueltas y si aparece información de otro negocio.

Resultados exigidos:

- STG-ADMIN-A solo obtiene datos autorizados del negocio A.
- STG-EMP-A solo obtiene las funciones operativas autorizadas del negocio A.
- STG-ADMIN-B no obtiene información del negocio A.
- Un empleado no puede consultar importes, nómina, datos financieros o información personal que no necesita para sus tareas.
- STG-EMP-SUSP, STG-USER-BLOCKED y STG-USER-NO-MEMBER no obtienen acceso a paneles.
- Una invitación pendiente no habilita acceso antes de completar la aceptación.

No considerar suficiente que la interfaz oculte una sección: la consulta directa al Data API, RPC y Edge Function también debe ser denegada.

## 4. Prueba MFA del propietario

1. Iniciar sesión con STG-OWNER sin completar el segundo factor.
2. Confirmar que no se muestra el panel técnico ni se cargan sus datos.
3. Completar un challenge TOTP válido.
4. Confirmar AAL2 en la sesión.
5. Llamar a `technical-business-management` con una sesión AAL1 y verificar denegación.
6. Repetir con sesión AAL2 y una acción inocua de lectura.
7. Probar código incorrecto, challenge vencido y factor no verificado.
8. Probar la pérdida simulada del dispositivo usando únicamente el procedimiento de recuperación aprobado para staging.

No registrar el secreto TOTP ni códigos de recuperación en evidencias.

**Criterio:** ninguna acción técnica protegida debe depender exclusivamente de una comprobación JavaScript del navegador.

## 5. Prueba de renovación y revocación de sesiones

Usar dos navegadores o perfiles separados con la misma cuenta de staging.

1. Iniciar sesión en ambos.
2. Confirmar que ambos pueden renovar su sesión normalmente.
3. Desde el navegador A, ejecutar el cierre global.
4. En el navegador B, comprobar qué sucede al renovar el token.
5. Registrar el tiempo transcurrido y el resultado de una operación protegida con el JWT que ya estaba emitido.
6. Repetir revocando una sesión por el mecanismo administrativo disponible en staging.
7. Comprobar que la interfaz detecta la pérdida de acceso y que el servidor deniega las operaciones sensibles.

Registrar por separado:
- si el refresh token dejó de funcionar;
- si el JWT existente siguió siendo aceptado;
- cuándo dejó de ser aceptado;
- si el panel redirigió al login;
- si una Edge Function/RPC denegó la operación antes de que la interfaz se actualizara.

No confundir cierre de sesión visual con revocación inmediata del token.

## 6. Prueba de suspensión y revocación de permisos

En staging y usando cuentas de prueba:

- Bloquear el perfil STG-USER-BLOCKED.
- Suspender la membresía STG-EMP-SUSP.
- Suspender temporalmente el negocio B.
- Revocar una invitación pendiente.
- Abrir previamente el panel en una segunda sesión y dejarlo abierto durante cada cambio.

Para cada caso comprobar:
1. La siguiente llamada a `resolve-my-access`.
2. Una llamada directa a la Edge Function protegida.
3. Una consulta directa al Data API.
4. Una RPC sensible.
5. La revalidación periódica del panel.

Criterio: el servidor debe denegar las operaciones inmediatamente según la política de autorización de cada endpoint; la interfaz debe reflejar el cambio en la siguiente revalidación. Restaurar el estado inicial solo en staging y registrar quién lo hizo.

## 7. Prueba de recuperación de contraseña e invitaciones

Probar en cuentas separadas:

- Solicitud de recuperación para cuenta existente.
- Solicitud para dirección no registrada: la respuesta pública no debe revelar si existe.
- Enlace vencido.
- Enlace alterado.
- OTP ya consumido.
- OTP reutilizado.
- Cambio correcto de contraseña.
- Cierre global solicitado tras el cambio.
- Cuenta bloqueada que completa recuperación: debe seguir bloqueada.
- Membresía suspendida que completa recuperación: debe seguir suspendida.
- Invitación pendiente, expirada y revocada.
- Renovación OTP de una cuenta Auth existente no confirmada.

Criterio: cambiar la contraseña no activa perfiles, no reactiva membresías, no cambia el rol y no elimina suspensiones.

## 8. Revisión RLS y permisos directos

Ejecutar el verificador SQL de integración desde el editor SQL de staging, después de aplicar el paquete revisado. El verificador debe terminar sin excepciones.

Además, probar consultas directas como cada rol de aplicación. Inspeccionar especialmente:
- `orders` y columnas personales/financieras;
- `profiles` y `business_memberships`;
- `payments`, `refunds`, `product_costs`, `order_item_costs`;
- `payroll_records` y tablas financieras de plataforma;
- `inventory_movements`;
- `job_applications` y Storage privado;
- tablas de invitaciones y auditoría.

No dar por aprobado el paquete solo porque las tablas tengan RLS habilitado: verificar policies, grants de tabla/columna, funciones SECURITY DEFINER y privilegios EXECUTE.

El verificador de integración actual comprueba condiciones estructurales; no sustituye las pruebas de comportamiento con JWT reales de cada rol.

## 9. Formato de evidencia

Para cada caso guardar:

| Campo | Valor |
|---|---|
| ID de prueba | AUTH-STG-001, etc. |
| Commit probado | SHA completo |
| Proyecto | Solo identificador no secreto de staging |
| Cuenta/rol | Alias STG, nunca correo real |
| Acción | Operación realizada |
| Resultado esperado | Criterio de esta guía |
| Resultado observado | Status, filas, tiempo |
| Evidencia | Captura sin datos sensibles o log sanitizado |
| Estado | PASS / FAIL / BLOCKED |
| Incidencia | Ruta/función/RPC afectada |

No adjuntar tokens, contraseñas, secretos, datos personales ni cuerpos completos de pedidos.

## 10. Criterios de aprobación

La etapa se aprueba solo cuando:

- Todos los casos críticos de acceso indebido quedan en PASS.
- Ningún rol puede consultar datos de otro negocio.
- Los empleados no obtienen datos financieros o personales no necesarios.
- El propietario no evita MFA mediante una llamada directa.
- El cierre global y el comportamiento de JWT quedan medidos y documentados.
- Perfiles bloqueados, membresías suspendidas e invitaciones pendientes no recuperan acceso al cambiar contraseña.
- El verificador SQL termina correctamente.
- Las Edge Functions y RPC aplican autorización en servidor.
- No quedan fallos críticos o altos sin plan de corrección y nueva prueba.

Un resultado BLOCKED no cuenta como PASS. Un test estático o de sintaxis tampoco cuenta como prueba de integración.

## 11. Estado actual

- [x] Procedimiento documentado.
- [ ] Proyecto Supabase de staging identificado.
- [ ] Migraciones revisadas aplicadas en staging.
- [ ] Edge Functions de la rama desplegadas en staging.
- [ ] Cuentas de prueba creadas.
- [ ] Matriz de autenticación y MFA ejecutada.
- [ ] Pruebas de RLS/Data API por rol ejecutadas.
- [ ] Pruebas de revocación de sesiones ejecutadas.
- [ ] Evidencias revisadas y bloqueadores corregidos.

**La ejecución está pendiente. No se ha modificado producción ni se han aplicado migraciones en esta tarea.**
