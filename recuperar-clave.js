(() => {
  const form = document.querySelector('#recoverForm');
  const message = document.querySelector('#recoverMessage');
  const button = document.querySelector('#recoverBtn');

  const neutralMessage = 'Si el correo corresponde a una cuenta registrada, recibirás instrucciones para restablecer la contraseña. Revisa también la carpeta de spam.';

  form.addEventListener('submit', async event => {
    event.preventDefault();
    button.disabled = true;
    message.textContent = 'Procesando solicitud…';
    message.className = 'message';

    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
        throw new Error('No está disponible la conexión segura.');
      }

      const client = window.supabase.createClient(
        window.MIEJE_SUPABASE_URL,
        window.MIEJE_SUPABASE_PUBLISHABLE_KEY
      );
      const email = document.querySelector('#email').value.trim();
      const redirectTo = new URL('actualizar-clave.html', window.location.href).href;
      const { error } = await client.auth.resetPasswordForEmail(email, { redirectTo });
      if (error) throw error;

      form.reset();
    } catch (error) {
      // No mostrar errores específicos de Auth: podrían revelar si una cuenta
      // existe o permitir distinguirla de otra. La respuesta visible es neutra.
      console.warn('No se pudo completar la solicitud de recuperación.');
    } finally {
      message.textContent = neutralMessage;
      message.className = 'message success';
      button.disabled = false;
    }
  });
})();