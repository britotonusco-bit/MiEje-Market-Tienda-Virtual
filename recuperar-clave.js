(() => {
  const form = document.querySelector('#recoverForm');
  const message = document.querySelector('#recoverMessage');
  const button = document.querySelector('#recoverBtn');
  form.addEventListener('submit', async event => {
    event.preventDefault();
    button.disabled = true;
    message.textContent = 'Enviando solicitud…';
    message.className = 'message';
    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) throw new Error('No está disponible la conexión segura.');
      const client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
      const email = document.querySelector('#email').value.trim();
      const { error } = await client.auth.resetPasswordForEmail(email, {
        redirectTo: new URL('actualizar-clave.html', window.location.href).href
      });
      if (error) throw error;
      message.textContent = 'Si el correo corresponde a una cuenta registrada, recibirás instrucciones para restablecer la contraseña. Revisa también la carpeta de spam.';
      message.className = 'message success';
      form.reset();
    } catch (error) {
      message.textContent = error.message || 'No se pudo enviar el enlace. Inténtalo más tarde.';
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
  });
})();