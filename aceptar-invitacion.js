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
      const type = url.searchParams.get('type');
      if (tokenHash && type === 'invite') {
        const { error } = await client.auth.verifyOtp({ token_hash: tokenHash, type: 'invite' });
        if (error) throw error;
        url.searchParams.delete('token_hash');
        url.searchParams.delete('type');
        window.history.replaceState({}, document.title, url.pathname + url.search + url.hash);
      }
      const { data, error } = await client.auth.getSession();
      if (error || !data.session) throw new Error('El enlace no es válido o ya expiró. Solicita una nueva invitación al propietario de MiEje Market.');
      ready = true;
      show('Enlace verificado. Ahora puedes crear tu contraseña.', 'success');
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
