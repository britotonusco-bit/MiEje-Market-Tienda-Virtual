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
    window.location.href = route.role === 'platform_owner' ? 'panel-tecnico.html' : targetFor(route);
  }
  async function resolveAccess() {
    const { data, error } = await client.functions.invoke('resolve-my-access', { body: {} });
    if (error) {
      let detail = error.message || 'No fue posible validar los permisos de la cuenta.';
      try {
        const payload = await error.context?.json?.();
        if (payload?.error) detail = payload.error;
      } catch (_) {}
      throw new Error(detail);
    }
    if (!data?.ok || !data.profile) throw new Error(data?.error || 'No fue posible validar los permisos de la cuenta.');
    return data;
  }
  function ensureMfaBox() {
    let box = document.querySelector('#ownerMfaBox');
    if (box) return box;
    box = document.createElement('section');
    box.id = 'ownerMfaBox';
    box.className = 'security-note';
    box.innerHTML = '<strong>Verificación de propietario</strong><p id="mfaInstruction">Completa la verificación para continuar.</p><div id="mfaQrWrap" hidden><img id="mfaQr" alt="Código QR para vincular la aplicación autenticadora" style="display:block;max-width:220px;width:100%;margin:12px auto;background:#fff;padding:10px;border-radius:10px"><p id="mfaSecret" style="overflow-wrap:anywhere"></p></div><label for="mfaCode">Código de seis dígitos</label><input id="mfaCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" placeholder="000000"><button id="mfaVerifyBtn" class="button primary full" type="button">Verificar código</button>';
    form.insertAdjacentElement('afterend', box);
    return box;
  }
  async function verifyOwnerMfa() {
    const { data: factorData, error: factorError } = await client.auth.mfa.listFactors();
    if (factorError) throw factorError;
    const factors = factorData?.totp || [];
    const verified = factors.find(factor => factor.status === 'verified');
    const pending = factors.find(factor => factor.status !== 'verified');
    if (!verified && pending) {
      const { error: cleanupError } = await client.auth.mfa.unenroll({ factorId: pending.id });
      if (cleanupError) throw cleanupError;
    }
    let factorId = verified?.id;
    let challengeId = null;
    const box = ensureMfaBox();
    const instruction = box.querySelector('#mfaInstruction');
    const qrWrap = box.querySelector('#mfaQrWrap');
    const verifyBtn = box.querySelector('#mfaVerifyBtn');

    if (!factorId) {
      instruction.textContent = 'Vincula una aplicación autenticadora. Escanea este código QR con Google Authenticator, Microsoft Authenticator o una aplicación TOTP compatible. Guarda también la clave de configuración en un lugar seguro.';
      const { data: enrolled, error: enrollError } = await client.auth.mfa.enroll({
        factorType: 'totp',
        friendlyName: 'MiEje Market - Propietario'
      });
      if (enrollError) throw enrollError;
      factorId = enrolled.id;
      box.dataset.factorId = factorId;
      const qr = enrolled.totp?.qr_code;
      if (qr) {
        box.querySelector('#mfaQr').src = qr;
        qrWrap.hidden = false;
      }
      box.querySelector('#mfaSecret').textContent = 'Clave manual: ' + (enrolled.totp?.secret || 'No disponible');
    } else {
      instruction.textContent = 'Abre tu aplicación autenticadora e ingresa el código actual de MiEje Market.';
      qrWrap.hidden = true;
      box.dataset.factorId = factorId;
    }

    const { data: challenge, error: challengeError } = await client.auth.mfa.challenge({ factorId });
    if (challengeError) throw challengeError;
    challengeId = challenge.id;

    box.classList.remove('hidden');
    form.classList.add('hidden');
    box.querySelector('#mfaCode').focus();
    verifyBtn.onclick = async () => {
      const code = box.querySelector('#mfaCode').value.trim();
      if (!/^\d{6}$/.test(code)) {
        instruction.textContent = 'Escribe el código de seis dígitos que aparece en la aplicación.';
        return;
      }
      verifyBtn.disabled = true;
      verifyBtn.textContent = 'Comprobando…';
      try {
        const { error: verifyError } = await client.auth.mfa.verify({ factorId, challengeId, code });
        if (verifyError) throw verifyError;
        const { data: assurance, error: assuranceError } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
        if (assuranceError) throw assuranceError;
        if (assurance?.currentLevel !== 'aal2') throw new Error('La sesión todavía no tiene el nivel de seguridad requerido. Intenta nuevamente.');
        const access = await resolveAccess();
        await go({ role: 'platform_owner' });
      } catch (error) {
        instruction.textContent = error.message || 'No se pudo verificar el código. Revisa la hora del dispositivo e inténtalo otra vez.';
        box.querySelector('#mfaCode').value = '';
        verifyBtn.disabled = false;
        verifyBtn.textContent = 'Verificar código';
      }
    };
    return new Promise(() => {});
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
      client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
      const { error: authError } = await client.auth.signInWithPassword({
        email: document.querySelector('#email').value.trim(),
        password: document.querySelector('#password').value
      });
      if (authError) throw authError;
      const access = await resolveAccess();
      const profile = access.profile;
      if (profile.platform_role === 'platform_owner' || access.is_platform_owner === true) {
        setBusy(false);
        await verifyOwnerMfa();
        return;
      }
      pendingRoutes = (access.memberships || [])
        .filter(item => item.business && item.business_id && ['business_admin', 'employee'].includes(item.role))
        .map(item => ({ business_id: item.business_id, business_name: item.business.name, role: item.role }));
      if (!pendingRoutes.length) throw new Error('Tu cuenta no tiene un negocio activo asignado. Si consideras que es un error, contacta al responsable de la plataforma.');
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