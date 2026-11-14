(() => {
  const form = document.querySelector('#updateForm');
  const message = document.querySelector('#updateMessage');
  const button = document.querySelector('#updateBtn');
  let client;
  let recoverySessionReady = false;
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
    // que ya estuviera guardada en el navegador no autoriza cambiar la clave.
    client.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY' && session?.user) {
        recoverySessionReady = true;
        resolveRecoveryEvent(session);
      }
    });

    const { data, error } = await client.auth.getSession();
    if (error) throw error;

    // PKCE puede intercambiar el código de la URL durante la inicialización.
    // Esperamos el evento específico de recuperación, no basta con getSession().
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
    say('Enlace de recuperación validado. Puedes crear una contraseña nueva.', 'success');
    button.disabled = false;
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!recoverySessionReady || !client) {
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

      const { error: signOutError } = await client.auth.signOut();
      if (signOutError) {
        console.warn('La contraseña se actualizó, pero no se pudo cerrar la sesión automáticamente.', signOutError);
      }
      say('Contraseña actualizada. Ya puedes iniciar sesión con tu nueva contraseña.', 'success');
      form.reset();
      recoverySessionReady = false;
    } catch (error) {
      say(error.message || 'No se pudo cambiar la contraseña.', 'error');
      button.disabled = false;
    }
  });

  initialize().catch(error => {
    say(error.message || 'No se pudo validar el enlace.', 'error');
    button.disabled = true;
  });
})();