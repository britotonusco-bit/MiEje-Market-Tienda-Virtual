(() => {
  const form = document.querySelector('#updateForm');
  const message = document.querySelector('#updateMessage');
  const button = document.querySelector('#updateBtn');
  let client;
  async function initialize() {
    if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
      message.textContent = 'No está disponible la conexión segura.';
      message.className = 'message error';
      return;
    }
    client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
    const { data } = await client.auth.getSession();
    if (!data.session) {
      message.textContent = 'El enlace no es válido o ya venció. Solicita uno nuevo desde recuperación de contraseña.';
      message.className = 'message error';
    }
  }
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const password = document.querySelector('#password').value;
    const confirm = document.querySelector('#confirmPassword').value;
    if (password.length < 10) {
      message.textContent = 'La contraseña debe tener al menos 10 caracteres.';
      message.className = 'message error';
      return;
    }
    if (password !== confirm) {
      message.textContent = 'Las contraseñas no coinciden.';
      message.className = 'message error';
      return;
    }
    button.disabled = true;
    try {
      if (!client) throw new Error('No se pudo validar el enlace de recuperación.');
      const { error } = await client.auth.updateUser({ password });
      if (error) throw error;
      await client.auth.signOut();
      message.textContent = 'Contraseña actualizada. Ya puedes iniciar sesión con tu nueva contraseña y completar la verificación de dos pasos.';
      message.className = 'message success';
      form.reset();
    } catch (error) {
      message.textContent = error.message || 'No se pudo cambiar la contraseña.';
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
  });
  initialize().catch(error => {
    message.textContent = error.message || 'No se pudo validar el enlace.';
    message.className = 'message error';
  });
})();