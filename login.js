(() => {
  const form = document.querySelector('#loginForm');
  const message = document.querySelector('#loginMessage');
  const button = document.querySelector('#loginBtn');
  const choiceWrap = document.querySelector('#businessChoice');
  const choice = document.querySelector('#businessSelect');
  const continueBtn = document.querySelector('#continueBtn');
  let client;
  let pendingRoutes = [];

  function say(text, kind = '') {
    message.textContent = text;
    message.className = `message ${kind}`.trim();
  }

  function setBusy(busy) {
    button.disabled = busy;
    button.textContent = busy ? 'Verificando…' : 'Ingresar';
  }

  function targetFor(route) {
    const panel = route.role === 'business_admin' ? 'panel-negocio.html' : 'panel-personal.html';
    return `${panel}?business=${encodeURIComponent(route.business_id)}`;
  }

  async function go(route) {
    window.location.href = route.role === 'platform_owner'
      ? 'panel-tecnico.html'
      : targetFor(route);
  }

  async function resolveAccess() {
    const { data, error } = await client.functions.invoke('resolve-my-access', { body: {} });
    if (error) {
      let detail = error.message || 'No fue posible validar los permisos de la cuenta.';
      try {
        const response = error.context;
        if (response && typeof response.json === 'function') {
          const payload = await response.json();
          if (payload?.error) detail = payload.error;
        }
      } catch (_) {}
      throw new Error(detail);
    }
    if (!data?.ok || !data.profile) {
      throw new Error(data?.error || 'No fue posible validar los permisos de la cuenta.');
    }
    return data;
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    say('');
    choiceWrap.classList.add('hidden');
    setBusy(true);

    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
        throw new Error('Falta cargar la configuración de Supabase. Revisa supabase-config.js.');
      }

      client = window.supabase.createClient(
        window.MIEJE_SUPABASE_URL,
        window.MIEJE_SUPABASE_PUBLISHABLE_KEY
      );

      const { error: authError } = await client.auth.signInWithPassword({
        email: document.querySelector('#email').value.trim(),
        password: document.querySelector('#password').value
      });
      if (authError) throw authError;

      const access = await resolveAccess();
      const profile = access.profile;

      if (profile.platform_role === 'platform_owner' || access.is_platform_owner === true) {
        await go({ role: 'platform_owner' });
        return;
      }

      pendingRoutes = (access.memberships || [])
        .filter(item => item.business && item.business_id && ['business_admin', 'employee'].includes(item.role))
        .map(item => ({
          business_id: item.business_id,
          business_name: item.business.name,
          role: item.role
        }));

      if (!pendingRoutes.length) {
        throw new Error('Tu cuenta no tiene un negocio activo asignado. Si consideras que es un error, contacta al responsable de la plataforma.');
      }

      if (pendingRoutes.length === 1) {
        await go(pendingRoutes[0]);
        return;
      }

      choice.innerHTML = pendingRoutes.map((route, index) =>
        `<option value="${index}">${escapeHtml(route.business_name)} — ${route.role === 'business_admin' ? 'Administración' : 'Personal'}</option>`
      ).join('');
      choiceWrap.classList.remove('hidden');
      say('Tu cuenta tiene acceso a varios negocios. Selecciona dónde deseas trabajar.');
    } catch (error) {
      say(error.message || 'No se pudo iniciar sesión. Comprueba tus datos.', 'error');
      if (client) await client.auth.signOut();
    } finally {
      setBusy(false);
    }
  });

  continueBtn.addEventListener('click', async () => {
    const route = pendingRoutes[Number(choice.value)];
    if (!route) return say('Selecciona un negocio.', 'error');
    continueBtn.disabled = true;
    await go(route);
    continueBtn.disabled = false;
  });

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, char => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[char]));
  }
})();
