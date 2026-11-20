(() => {
  const otpSection = document.querySelector('#inviteOtpSection');
  const otpButton = document.querySelector('#verifyInviteOtpBtn');
  const emailInput = document.querySelector('#inviteEmail');
  const otpInput = document.querySelector('#inviteOtp');
  const form = document.querySelector('#acceptInviteForm');
  const status = document.querySelector('#inviteStatus');
  let client;
  let ready = false;
  let invitationId = '';
  let invitationToken = '';
  let authOtpType = 'invite';

  const show = (text, kind = '') => {
    status.textContent = text;
    status.className = `message ${kind}`.trim();
  };

  function revealPasswordStep() {
    ready = true;
    otpSection.hidden = true;
    form.hidden = false;
    show('Correo verificado. Crea una contraseña para activar únicamente el acceso al negocio invitado.', 'success');
    form.elements.password.focus();
  }

  async function init() {
    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
        throw new Error('Falta configurar la conexión con Supabase.');
      }

      const url = new URL(window.location.href);
      const fragment = new URLSearchParams(url.hash.startsWith('#') ? url.hash.slice(1) : url.hash);
      invitationId = fragment.get('invitation_id') || '';
      invitationToken = fragment.get('invitation_token') || '';
      authOtpType = fragment.get('auth_type') || 'invite';

      // El secreto vive solo en memoria; se quita de la barra antes de iniciar Auth.
      window.history.replaceState({}, document.title, url.pathname);

      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(invitationId)
          || !/^[A-Za-z0-9_-]{43}$/.test(invitationToken)
          || !['invite', 'email'].includes(authOtpType)) {
        throw new Error('Este enlace no contiene una invitación individual válida de MiEje Market. Solicita al propietario técnico que genere una nueva.');
      }

      client = window.supabase.createClient(
        window.MIEJE_SUPABASE_URL,
        window.MIEJE_SUPABASE_PUBLISHABLE_KEY,
        { auth: { detectSessionInUrl: false, persistSession: true, autoRefreshToken: true } }
      );

      show('Escribe el correo al que llegó la invitación y el código que aparece en ese mensaje.');
      otpButton.disabled = false;
      emailInput.focus();
    } catch (error) {
      show(error.message || 'No se pudo preparar la invitación.', 'error');
      otpButton.disabled = true;
    }
  }

  otpButton.addEventListener('click', async () => {
    if (!client || ready) return;
    const email = emailInput.value.trim().toLowerCase();
    const token = otpInput.value.trim();

    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      emailInput.focus();
      return show('Escribe un correo válido.', 'error');
    }
    if (!/^\d{6,10}$/.test(token)) {
      otpInput.focus();
      return show('Escribe el código numérico recibido por correo.', 'error');
    }

    otpButton.disabled = true;
    show('Verificando el código de invitación…');

    try {
      const { data: current, error: sessionError } = await client.auth.getSession();
      if (sessionError) throw sessionError;
      const currentUser = current.session?.user;
      const currentEmail = currentUser?.email?.trim().toLowerCase();

      if (currentUser && currentEmail === email && currentUser.email_confirmed_at) {
        // Permite reintentar si el OTP ya fue consumido y la sesión del destinatario
        // sigue activa en este mismo navegador.
        revealPasswordStep();
        return;
      }

      if (currentUser) {
        const { error: signOutError } = await client.auth.signOut({ scope: 'local' });
        if (signOutError) throw signOutError;
      }

      const { data, error } = await client.auth.verifyOtp({
        email,
        token,
        type: authOtpType,
      });
      if (error) throw error;

      const verifiedUser = data.user || data.session?.user;
      if (!data.session || !verifiedUser?.email_confirmed_at
          || verifiedUser.email?.trim().toLowerCase() !== email) {
        await client.auth.signOut({ scope: 'local' });
        throw new Error('El código no confirmó el correo indicado. Comprueba el correo y vuelve a intentarlo.');
      }

      revealPasswordStep();
    } catch (error) {
      show(error.message || 'No se pudo verificar el código. Comprueba que no haya vencido.', 'error');
      otpButton.disabled = false;
    }
  });

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
