(() => {
  const form = document.querySelector('#updateForm');
  const message = document.querySelector('#updateMessage');
  const button = document.querySelector('#updateBtn');
  let client;
  let recoverySessionReady = false;
  let passwordUpdated = false;
  let resolveRecoveryEvent;
  const recoveryEvent = new Promise(resolve => { resolveRecoveryEvent = resolve; });

  button.disabled = true;

  function say(text, kind = '') {
    message.textContent = text;
    message.className = ('message ' + kind).trim();
  }

  async function initialize() {
    if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
      throw new Error('No está disponible la conexión segura.');
    }

    client = window.supabase.createClient(
      window.MIEJE_SUPABASE_URL,
      window.MIEJE_SUPABASE_PUBLISHABLE_KEY
    );

    // Escuchar PASSWORD_RECOVERY antes de esperar la sesión. Una sesión normal
    // guardada en el navegador no autoriza por sí sola a cambiar la contraseña.
    client.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY' && session?.user) {
        recoverySessionReady = true;
        resolveRecoveryEvent(session);
      }
    });

    const { error } = await client.auth.getSession();
    if (error) throw error;

    // PKCE puede intercambiar el código durante la inicialización. No basta
    // con encontrar una sesión previa: exigimos el evento de recuperación.
    const recoverySession = await Promise.race([
      recoveryEvent,
      new Promise(resolve => window.setTimeout(() => resolve(null), 10000))
    ]);

    if (!recoverySession) {
      say('El enlace no es válido, ya venció o no corresponde a una recuperación de contraseña. Solicita uno nuevo.', 'error');
      button.disabled = true;
      return;
    }

    recoverySessionReady = true;
    // Retira el código o token de la URL después de que Auth lo haya validado.
    const cleanUrl = new URL(window.location.href);
    cleanUrl.search = '';
    cleanUrl.hash = '';
    window.history.replaceState({}, document.title, cleanUrl.pathname);
    say('Enlace de recuperación validado. Puedes crear una contraseña nueva.', 'success');
    button.disabled = false;
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!recoverySessionReady || !client || passwordUpdated) {
      say('Primero debes abrir un enlace de recuperación válido enviado a tu correo.', 'error');
      return;
    }

    const password = document.querySelector('#password').value;
    const confirm = document.querySelector('#confirmPassword').value;
    if (password.length < 10) {
      say('La contraseña debe tener al menos 10 caracteres.', 'error');
      return;
    }
    if (password !== confirm) {
      say('Las contraseñas no coinciden.', 'error');
      return;
    }

    button.disabled = true;
    try {
      const { error } = await client.auth.updateUser({ password });
      if (error) throw error;
      passwordUpdated = true;
      recoverySessionReady = false;

      // La recuperación de contraseña debe invalidar los refresh tokens de
      // todos los dispositivos, no solo borrar la sesión de este navegador.
      const { error: globalSignOutError } = await client.auth.signOut({ scope: 'global' });
      if (globalSignOutError) {
        console.warn('La contraseña se actualizó, pero no se confirmó el cierre global de sesiones.');
        // Como mínimo, retirar la sesión local aunque falle la revocación global.
        const { error: localSignOutError } = await client.auth.signOut({ scope: 'local' });
        if (localSignOutError) {
          console.warn('No se pudo cerrar la sesión local después de actualizar la contraseña.');
        }
        say('La contraseña se actualizó. No pudimos confirmar el cierre de las demás sesiones; vuelve a iniciar sesión y contacta al soporte si no reconoces algún acceso.', 'success');
      } else {
        say('Contraseña actualizada. Se solicitó el cierre de las sesiones de tu cuenta en los demás dispositivos. Inicia sesión nuevamente.', 'success');
      }
      form.reset();
    } catch (error) {
      if (passwordUpdated) {
        say('La contraseña se actualizó, pero hubo un problema al cerrar la sesión. Cierra esta ventana y vuelve a iniciar sesión.', 'error');
      } else {
        say(error.message || 'No se pudo cambiar la contraseña.', 'error');
        button.disabled = false;
      }
    }
  });

  initialize().catch(error => {
    say(error.message || 'No se pudo validar el enlace.', 'error');
    button.disabled = true;
  });
})();