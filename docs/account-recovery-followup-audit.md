# Revisión complementaria de recuperación e invitaciones

**Fecha:** 20 de noviembre de 2026  
**Rama:** `correcciones-funcionales`  
**Alcance:** revisión estática de recuperación de contraseña, aceptación de invitaciones y operaciones relacionadas. No se ejecutó SQL, no se desplegaron funciones y no se enviaron correos.

## ACC-15 — Mensaje de recuperación cuando falta la configuración local

### Hallazgo
`recuperar-clave.js` mostraba siempre el mensaje neutro de éxito, incluso cuando faltaba la librería de Supabase o la URL/clave pública no estaban configuradas. Aunque esa respuesta evita revelar si un correo existe, también ocultaba un fallo local que impide enviar cualquier solicitud.

### Corrección en la rama
El formulario ahora diferencia dos situaciones:

- Si la conexión local no pudo inicializarse, muestra un aviso de indisponibilidad y permite reintentar más tarde.
- Si la conexión se inicializó y Auth devuelve un error al procesar el correo, mantiene el mensaje neutro para no revelar si la cuenta existe.

Esto no demuestra que el correo se haya enviado. La respuesta neutra sigue significando únicamente que la solicitud se procesó sin exponer el resultado específico de Auth.

**Archivo:** `recuperar-clave.js`  
**Commit:** `a2663568138a82c96620e50c2d24ca845aec1426`

## Revisión de restablecimiento de contraseña

- El formulario exige el evento `PASSWORD_RECOVERY`; una sesión normal guardada en el navegador no basta.
- El enlace se limpia de la barra de direcciones después de recibir el evento.
- La contraseña debe tener entre 10 y 128 caracteres en la interfaz; la política real de Auth debe comprobarse en staging.
- Tras el cambio se solicita cierre global de sesiones, con fallback local si falla.
- La interfaz informa que el cierre global no pudo confirmarse cuando ocurre ese fallo.

**Pendiente:** el evento de recuperación tiene una espera máxima de diez segundos. Debe probarse con enlaces PKCE, sesión previa, red lenta, enlace vencido y enlace reutilizado. No se debe quitar la comprobación de `PASSWORD_RECOVERY` para resolver errores de compatibilidad.

## Revisión de invitaciones

El flujo actual separa la invitación de la activación de la membresía:

- La cuenta destinataria verifica el OTP de Auth.
- La Edge Function valida el JWT, correo confirmado, identidad, token individual y estado de invitación.
- La contraseña se actualiza mediante Auth Admin.
- Una reserva temporal serializa la aceptación con la revocación.
- La RPC final activa únicamente la membresía asociada a esa invitación.
- Si el cambio de contraseña se completa pero la activación falla, la membresía permanece bloqueada y el mismo flujo permite reintentar.
- Revocar una invitación conserva la cuenta Auth y otras membresías.

### Configuración hospedada obligatoria

La rama contiene plantillas separadas para **Invite User** y **Confirm signup**, ambas con OTP manual y `{{ .RedirectTo }}`. El archivo local `supabase/config.toml` no cambia por sí solo las plantillas del proyecto hospedado.

Antes de enviar invitaciones reales en staging se debe copiar cada plantilla en la sección correspondiente de Supabase Authentication → Email Templates y comprobar la URL permitida en Authentication → URL Configuration. La plantilla de invitación no debe usar `{{ .ConfirmationURL }}`, pues el flujo requiere que la persona introduzca el OTP manualmente.

La renovación con `auth.resend({ type: 'signup' })` para cuentas heredadas no confirmadas sigue dependiendo de compatibilidad real del estado de Auth; no se considera validada hasta probarla con cuentas ficticias en staging.

## Pendientes de validación

1. Recuperación con correo existente y no registrado: misma respuesta visible.
2. Falta de configuración local: mensaje de indisponibilidad, sin afirmar que se envió correo.
3. Enlaces válidos, vencidos, alterados y reutilizados.
4. Cambio de contraseña y cierre global en dos navegadores; medir la vigencia del JWT ya emitido.
5. Invitación nueva con plantilla Invite User, OTP manual y contraseña.
6. Renovación de cuenta heredada no confirmada con plantilla Confirm signup.
7. Aceptación y revocación concurrentes; comprobar que solo una operación gana.
8. Fallo después de actualizar contraseña y antes de activar membresía; comprobar reintento.
9. Perfil bloqueado, negocio suspendido, invitación revocada o vencida: nunca deben activar la membresía.

**Estado general:** revisión estática únicamente. La rama no se considera validada funcionalmente hasta completar las pruebas en un proyecto Supabase de staging aislado. No usar producción como entorno de ensayo.
