(() => {
  const form = document.querySelector('#acceptInviteForm');
  const status = document.querySelector('#inviteStatus');
  let client;
  let ready = false;
  let invitationId = '';
  let invitationToken = '';

  const show = (text, kind = '') => {
    status.textContent = text;
    status.className = `message ${kind}`.trim();
  };

  async function init() {
    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
        throw new Error('Falta configurar la conexión con Supabase.');
      }

      const url = new URL(window.location.href);
      invitationId = url.searchParams.get('invitation_id') || '';
      invitationToken = url.searchParams.get('invitation_token') || '';
      const queryType = url.searchParams.get('type');
      const hashParams = new URLSearchParams(url.hash.startsWith('#') ? url.hash.slice(1) : url.hash);
      const hashType = hashParams.get('type');
      const tokenHash = url.searchParams.get('token_hash');

      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(invitationId)
          || !/^[A-Za-z0-9_-]{43}$/.test(invitationToken)) {
        throw new Error('Este enlace no contiene una invitación individual válida de MiEje Market. Solicita una invitación nueva.');
      }

      client = window.supabase.createClient(
        window.MIEJE_SUPABASE_URL,
        window.MIEJE_SUPABASE_PUBLISHABLE_KEY,
        { auth: { detectSessionInUrl: true, persistSession: true, autoRefreshToken: true } }
      );

      if (queryType !== 'invite' && hashType !== 'invite') {
        throw new Error('Este enlace no corresponde a una invitación de MiEje Market.');
      }

      // Si el enlace ya se verificó en esta sesión, no se vuelve a consumir
      // el OTP de un solo uso. El servidor comprobará después que la sesión
      // pertenece al usuario destinatario de esta invitación.
      const existingSession = await client.auth.getSession();
      if (existingSession.error) throw existingSession.error;
      if (!existingSession.data.session && queryType === 'invite' && tokenHash) {
        const { error } = await client.auth.verifyOtp({ token_hash: tokenHash, type: 'invite' });
        if (error) throw error;
      }

      const { data, error } = await client.auth.getSession();
      if (error || !data.session) {
        throw new Error('El enlace de Supabase no pudo verificarse o ya venció. Solicita una invitación nueva.');
      }
      if (!data.session.user?.email_confirmed_at) {
        await client.auth.signOut({ scope: 'local' });
        throw new Error('El correo todavía no aparece confirmado. Abre el enlace original recibido por correo.');
      }

      // El token individual se conserva solo en memoria durante esta página.
      // Se eliminan inmediatamente los parámetros de Auth y de la invitación.
      window.history.replaceState({}, document.title, url.pathname);
      ready = true;
      show('Correo verificado. Crea tu contraseña para activar únicamente el acceso al negocio invitado.', 'success');
    } catch (error) {
      show(error.message || 'No se pudo verificar la invitación.', 'error');
      form.querySelector('button').disabled = true;
    }
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!ready || !client) return;

    const password = form.elements.password.value;
    if (password.length < 10 || password.length > 128) {
      return show('La contraseña debe tener entre 10 y 128 caracteres.', 'error');
    }
    if (password !== form.elements.confirmPassword.value) {
      return show('Las contraseñas no coinciden.', 'error');
    }

    const button = form.querySelector('button');
    button.disabled = true;
    show('Guardando contraseña y completando la invitación…');

    try {
      const { data, error } = await client.functions.invoke('accept-business-invitation', {
        body: {
          invitation_id: invitationId,
          invitation_token: invitationToken,
          password,
        },
      });

      if (error) {
        let message = error.message || 'No se pudo completar la invitación.';
        try {
          const payload = await error.context?.clone?.().json();
          if (payload?.error) message = payload.error;
        } catch {
          // Mantener el mensaje general de la función.
        }
        throw new Error(message);
      }
      if (!data?.ok || data.status !== 'accepted') {
        throw new Error(data?.error || 'La invitación no pudo activarse.');
      }

      const { error: signOutError } = await client.auth.signOut({ scope: 'local' });
      if (signOutError) console.error('Local sign-out after invitation:', signOutError);

      show('Cuenta activada y acceso al negocio confirmado. Ya puedes iniciar sesión.', 'success');
      form.reset();
      button.textContent = 'Cuenta activada';
      ready = false;
      invitationToken = '';
      setTimeout(() => { window.location.href = 'login.html'; }, 1800);
    } catch (error) {
      show(error.message || 'No se pudo activar la cuenta. Puedes volver a intentarlo con el mismo enlace.', 'error');
      button.disabled = false;
    }
  });

  init();
})();
