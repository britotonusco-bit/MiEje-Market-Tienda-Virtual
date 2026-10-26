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
  async function recordLogin(route) {
    const panel = route.panel;
    const { error } = await client.rpc('log_panel_access', {
      p_business_id: route.business_id || null,
      p_panel: panel,
      p_event_type: 'login_success'
    });
    if (error) throw new Error('No se pudo guardar el registro de acceso. Por seguridad, el panel no se abrirá todavía.');
  }
  async function go(route) {
    try {
      // Las cuentas bloqueadas y los miembros de tiendas suspendidas deben llegar a la pantalla de aviso,
      // pero no registrar una entrada al panel como si el acceso estuviera autorizado.
      const blockedOrSuspended = route.is_active === false || route.is_blocked === true || route.business_active === false;
      if (!blockedOrSuspended) await recordLogin(route);
      window.location.href = route.role === 'platform_owner' ? 'panel-tecnico.html' : targetFor(route);
    } catch (error) {
      if (client) await client.auth.signOut();
      say(error.message || 'No fue posible abrir el panel.', 'error');
    }
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    say(''); choiceWrap.classList.add('hidden'); setBusy(true);
    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
        throw new Error('Falta cargar la configuración de Supabase. Revisa supabase-config.js.');
      }
      client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
      const { data: authData, error: authError } = await client.auth.signInWithPassword({
        email: document.querySelector('#email').value.trim(),
        password: document.querySelector('#password').value
      });
      if (authError) throw authError;
      const user = authData.user;
      const { data: profile, error: profileError } = await client.from('profiles')
        .select('id,display_name,platform_role').eq('id', user.id).single();
      if (profileError || !profile) throw new Error('La cuenta inició sesión, pero no se pudo validar su perfil. Contacta al responsable de la plataforma.');

      if (profile.platform_role === 'platform_owner') {
        await go({ role: 'platform_owner', panel: 'technical', business_id: null });
        return;
      }

      const { data: memberships, error: memberError } = await client.from('business_members')
        .select('business_id,role,is_active,is_blocked,block_reason,businesses(name,slug,is_active,suspension_reason,suspension_public_message)')
        .eq('user_id', user.id);
      if (memberError) throw memberError;
      pendingRoutes = (memberships || []).filter(m => m.businesses).map(m => ({
        business_id: m.business_id,
        business_name: m.businesses.name,
        role: m.role,
        is_active: m.is_active,
        is_blocked: m.is_blocked,
        block_reason: m.block_reason,
        business_active: m.businesses.is_active,
        suspension_reason: m.businesses.suspension_reason,
        panel: m.role === 'business_admin' ? 'business_admin' : 'employee'
      }));
      if (!pendingRoutes.length) throw new Error('Tu cuenta todavía no está asignada a un negocio. Solicita al administrador que te asigne un rol.');
      if (pendingRoutes.length === 1) {
        await go(pendingRoutes[0]);
        return;
      }
      choice.innerHTML = pendingRoutes.map((route, index) => { const status = route.is_blocked || route.is_active === false ? ' — acceso bloqueado' : route.business_active === false ? ' — tienda suspendida' : ''; return `<option value="${index}">${escapeHtml(route.business_name)} — ${route.role === 'business_admin' ? 'Administración' : 'Personal'}${status}</option>`; }).join('');
      choiceWrap.classList.remove('hidden');
      say('Tu cuenta tiene acceso a varios negocios. Selecciona dónde deseas trabajar.');
    } catch (error) {
      say(error.message || 'No se pudo iniciar sesión. Comprueba tus datos.', 'error');
      if (client) await client.auth.signOut();
    } finally { setBusy(false); }
  });

  continueBtn.addEventListener('click', async () => {
    const route = pendingRoutes[Number(choice.value)];
    if (!route) return say('Selecciona un negocio.', 'error');
    continueBtn.disabled = true;
    await go(route);
    continueBtn.disabled = false;
  });

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  }
})();
