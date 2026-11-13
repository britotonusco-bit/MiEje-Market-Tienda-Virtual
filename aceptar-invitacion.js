(() => {
  const form = document.querySelector('#acceptInviteForm');
  const status = document.querySelector('#inviteStatus');
  let client;
  let ready = false;
  const show = (text, kind = '') => { status.textContent = text; status.className = `message ${kind}`.trim(); };

  async function init() {
    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) throw new Error('Falta configurar la conexión con Supabase.');
      client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY, { auth: { detectSessionInUrl: true, persistSession: true, autoRefreshToken: true } });
      const url = new URL(window.location.href);
      const tokenHash = url.searchParams.get('token_hash');
      const queryType = url.searchParams.get('type');
      const hashParams = new URLSearchParams(url.hash.startsWith('#') ? url.hash.slice(1) : url.hash);
      const hashType = hashParams.get('type');

      // No aceptar una sesión que ya estuviera guardada en el navegador:
      // la página solo debe activarse desde un enlace identificado como invitación.
      if (queryType !== 'invite' && hashType !== 'invite') {
        throw new Error('Este enlace no corresponde a una invitación de MiEje Market. Abre el enlace original recibido por correo o solicita uno nuevo.');
      }

      if (tokenHash && queryType === 'invite') {
        const { error } = await client.auth.verifyOtp({ token_hash: tokenHash, type: 'invite' });
        if (error) throw error;
      }

      const { data, error } = await client.auth.getSession();
      if (error || !data.session) throw new Error('El enlace de invitación no es válido o ya expiró. Solicita una nueva invitación al propietario de MiEje Market.');

      // Supabase ya intercambió/verificó el enlace. Retira códigos y tokens de la barra
      // de direcciones para que no queden expuestos al copiar o compartir la URL.
      window.history.replaceState({}, document.title, url.pathname);
      ready = true;
      show('Invitación verificada. Ahora puedes crear tu contraseña.', 'success');
    } catch (error) {
      show(error.message || 'No se pudo verificar la invitación.', 'error');
      form.querySelector('button').disabled = true;
    }
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!ready) return;
    const password = form.elements.password.value;
    if (password.length < 10) return show('La contraseña debe tener al menos 10 caracteres.', 'error');
    if (password !== form.elements.confirmPassword.value) return show('Las contraseñas no coinciden.', 'error');
    const button = form.querySelector('button');
    button.disabled = true;
    show('Guardando contraseña…');
    try {
      const { error } = await client.auth.updateUser({ password });
      if (error) throw error;
      await client.auth.signOut();
      show('Cuenta activada. Ya puedes iniciar sesión con tu correo y la contraseña que acabas de crear.', 'success');
      form.reset();
      button.textContent = 'Cuenta activada';
      setTimeout(() => { window.location.href = 'login.html'; }, 1800);
    } catch (error) {
      show(error.message || 'No se pudo activar la cuenta.', 'error');
      button.disabled = false;
    }
  });
  init();
})();
