(() => {
  const panel = document.body.dataset.panel;
  let db;
  let currentUser;
  let currentProfile;
  let businessId = null;
  let businessName = '';
  let isBusinessOwner = false;
  let cachedBusinesses = [];
  const statusLabels = {
    received: 'Recibido', confirmed: 'Confirmado', preparing: 'En preparación',
    ready: 'Listo', on_the_way: 'En camino', delivered: 'Entregado', cancelled: 'Cancelado'
  };
  const nextStatus = { received: 'confirmed', confirmed: 'preparing', preparing: 'ready', ready: 'on_the_way', on_the_way: 'delivered' };
  const statusClass = { received: 'yellow', confirmed: 'blue', preparing: 'blue', ready: 'green', on_the_way: 'blue', delivered: 'green', cancelled: 'red' };

  document.addEventListener('DOMContentLoaded', boot);

  async function boot() {
    const notice = document.querySelector('#notice');
    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
        throw new Error('No está configurada la conexión con Supabase. Revisa supabase-config.js.');
      }
      db = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
      const { data: auth, error: authError } = await db.auth.getUser();
      if (authError || !auth.user) { window.location.replace('login.html'); return; }
      currentUser = auth.user;
      const { data: profile, error: profileError } = await db.from('profiles').select('id,display_name,platform_role').eq('id', currentUser.id).single();
      if (profileError || !profile) throw new Error('No se pudo verificar el perfil. Cierra sesión y vuelve a ingresar.');
      currentProfile = profile;
      document.querySelector('#userName').textContent = profile.display_name || currentUser.email || 'Usuario';
      document.querySelector('#logoutBtn').addEventListener('click', signOut);
      document.querySelector('#refreshTechnicalBtn')?.addEventListener('click', refreshTechnical);
      document.querySelector('#createBusinessForm')?.addEventListener('submit', createBusiness);
      document.querySelector('#inviteMemberForm')?.addEventListener('submit', inviteBusinessMember);
      document.querySelector('#businessSearch')?.addEventListener('input', renderBusinesses);
      document.querySelector('#businessSelect')?.addEventListener('change', event => loadSelectedBusiness(event.currentTarget.value));
      document.querySelector('#suspensionForm')?.addEventListener('submit', saveSuspension);
      document.querySelector('#memberStatusForm')?.addEventListener('submit', saveMemberStatus);
      document.querySelector('#memberBusinessSelect')?.addEventListener('change', event => loadTechnicalMembers(event.currentTarget.value));
      document.querySelector('#platformAiForm')?.addEventListener('submit', savePlatformAi);
      document.querySelector('#storeSettingsForm')?.addEventListener('submit', saveStoreSettings);
      document.querySelector('#businessContentForm')?.addEventListener('submit', saveBusinessContent);
      document.querySelector('#businessAiForm')?.addEventListener('submit', saveBusinessAi);
      document.querySelector('#blockRequestForm')?.addEventListener('submit', submitBlockRequest);
      document.querySelector('#refreshOrders')?.addEventListener('click', () => panel === 'business_admin' ? loadBusinessOrders() : loadEmployeeOrders());

      if (panel === 'technical') {
        if (profile.platform_role !== 'platform_owner') throw new Error('Esta sección es exclusiva del propietario técnico autorizado.');
        await logPanel(null, 'technical', 'panel_open');
        notice.textContent = 'Acceso validado. Los registros se consultan desde la base de datos.';
        notice.className = 'notice';
        await loadTechnical();
        await initPlatformAi();
      } else {
        const { data: memberships, error: memberError } = await db.from('business_members')
          .select('business_id,role,is_active,is_blocked,block_reason,is_business_owner,businesses(name,slug,is_active,suspension_reason,suspension_public_message)')
          .eq('user_id', currentUser.id);
        if (memberError) throw memberError;
        const available = (memberships || []).filter(m => m.businesses);
        const requested = new URLSearchParams(window.location.search).get('business');
        const match = available.find(m => m.business_id === requested) || (available.length === 1 ? available[0] : null);
        if (!match) throw new Error('No tienes un negocio asignado a esta cuenta o el negocio no coincide. Vuelve al inicio de sesión.');
        if (match.is_blocked || !match.is_active) {
          notice.textContent = `Acceso bloqueado para este usuario. Motivo: ${match.block_reason || 'El acceso fue suspendido por el servicio técnico.'}`;
          notice.className = 'notice error';
          await showSupportLink();
          document.querySelectorAll('.panel-section, #statsGrid').forEach(el => { if (!el.closest('#soporte')) el.classList.add('hidden'); });
          return;
        }
        if (match.businesses.is_active === false) {
          notice.textContent = `El negocio ${match.businesses.name} está suspendido. Motivo: ${match.businesses.suspension_reason || 'El negocio no está disponible temporalmente.'}`;
          notice.className = 'notice error';
          await showSupportLink();
          document.querySelectorAll('.panel-section, #statsGrid').forEach(el => { if (!el.closest('#soporte')) el.classList.add('hidden'); });
          return;
        }
        if (panel === 'business_admin' && match.role !== 'business_admin') throw new Error('Tu cuenta no tiene el rol administrativo requerido para este panel.');
        if (panel === 'employee' && !['employee','business_admin'].includes(match.role)) throw new Error('Tu cuenta no tiene permiso para el panel del personal.');
        businessId = match.business_id;
        businessName = match.businesses.name;
        isBusinessOwner = match.is_business_owner === true;
        document.querySelector('#businessName').textContent = businessName;
        await logPanel(businessId, panel, 'panel_open');
        notice.textContent = `Acceso validado para ${businessName}. Los permisos se aplican en la base de datos.`;
        notice.className = 'notice';
        if (panel === 'business_admin') { await loadBusinessAdmin(); await initBusinessSettings(); }
        else { await loadEmployeeOrders(); await showSupportLink(); }
      }
    } catch (error) {
      if (notice) { notice.textContent = error.message || 'No se pudo cargar el panel.'; notice.className = 'notice'; }
      document.querySelectorAll('.panel-section, #statsGrid').forEach(el => { if (el) el.classList.add('hidden'); });
      console.error('MiEje Market panel:', error);
    }
  }

  async function logPanel(id, panelName, eventType) {
    const { error } = await db.rpc('log_panel_access', { p_business_id: id, p_panel: panelName, p_event_type: eventType });
    if (error) throw new Error('No se pudo guardar el registro de acceso. Por seguridad, el panel no se abrirá: ' + error.message);
  }

  async function signOut() {
    try { await db.auth.signOut(); } finally { window.location.replace('login.html'); }
  }

  async function loadBusinessAdmin() {
    const { data: summary, error: summaryError } = await db.rpc('get_business_summary', { p_business_id: businessId });
    if (summaryError) throw summaryError;
    renderStats([
      ['Ventas de hoy', money(summary.today_sales), 'Pedidos creados hoy, sin cancelados'],
      ['Dinero recibido', money(summary.money_received), 'Pedidos marcados como pagados'],
      ['Pedidos abiertos', number(summary.open_orders), 'Pendientes de completar'],
      ['Productos con poco stock', number(summary.low_stock_products), 'Cinco unidades o menos']
    ]);
    await Promise.all([loadBusinessOrders(), loadProducts(), loadAccessEvents(businessId, '#accessContainer'), loadAuditEvents(businessId, '#auditContainer')]);
  }

  async function loadBusinessOrders() {
    const target = document.querySelector('#ordersContainer');
    target.innerHTML = '<div class="empty">Cargando pedidos…</div>';
    const { data, error } = await db.rpc('get_business_orders', { p_business_id: businessId, p_panel: 'business_admin' });
    if (error) return showError(target, error);
    renderOrders(target, data || [], true);
  }

  async function loadEmployeeOrders() {
    const target = document.querySelector('#ordersContainer');
    target.innerHTML = '<div class="empty">Cargando pedidos…</div>';
    const { data, error } = await db.rpc('get_business_orders', { p_business_id: businessId, p_panel: 'employee' });
    if (error) return showError(target, error);
    renderOrders(target, data || [], false);
  }

  async function loadProducts() {
    const target = document.querySelector('#productsContainer');
    const { data, error } = await db.from('products').select('id,name,price,stock_quantity,track_inventory,is_active').eq('business_id', businessId).order('name').limit(250);
    if (error) return showError(target, error);
    if (!data?.length) { target.innerHTML = '<div class="empty">Este negocio todavía no tiene productos registrados.</div>'; return; }
    target.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Producto</th><th>Precio</th><th>Existencias</th><th>Estado</th></tr></thead><tbody>${data.map(p => `<tr><td>${esc(p.name)}</td><td>${money(p.price)}</td><td>${p.track_inventory ? number(p.stock_quantity) : 'No controlado'}</td><td><span class="pill ${p.is_active ? 'green':'red'}">${p.is_active ? 'Activo':'Inactivo'}</span></td></tr>`).join('')}</tbody></table></div>`;
  }

  async function loadTechnical() {
    const { data: summary, error: summaryError } = await db.rpc('get_platform_summary');
    if (summaryError) throw summaryError;
    renderStats([
      ['Negocios', number(summary.total_businesses), `${number(summary.active_businesses)} activos`],
      ['Productos', number(summary.total_products), 'En todos los negocios'],
      ['Pedidos', number(summary.total_orders), `${number(summary.open_orders)} abiertos`],
      ['Ventas registradas', money(summary.sales_total), `Recibido: ${money(summary.money_received)}`],
      ['Accesos registrados', number(summary.access_events), 'Historial central'],
      ['Eventos de auditoría', number(summary.audit_events), 'Cambios importantes'],
      ['Nómina pagada', money(summary.payroll_paid), 'Registros marcados como pagados']
    ]);
    const { data: businesses, error: businessError } = await db.from('businesses')
      .select('id,name,slug,business_type,is_active,suspension_reason,suspension_public_message,created_at').order('created_at', { ascending: false });
    if (businessError) throw businessError;
    cachedBusinesses = businesses || [];
    const select = document.querySelector('#businessSelect');
    select.innerHTML = `<option value="">Todos los negocios</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}${b.is_active ? '' : ' (inactivo)'}</option>`).join('');
    const memberBusinessSelect = document.querySelector('#memberBusinessSelect');
    if (memberBusinessSelect) memberBusinessSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    const suspensionSelect = document.querySelector('#suspensionBusinessSelect');
    if (suspensionSelect) suspensionSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}${b.is_active ? '' : ' (suspendido)'}</option>`).join('');
    const inviteSelect = document.querySelector('#inviteBusinessSelect');
    if (inviteSelect) inviteSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.filter(b => b.is_active).map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    renderBusinesses();
    await loadFinance();
    await loadSelectedBusiness('');
    await loadBlockRequests();
    await loadContentModeration();
  }

  function renderBusinesses() {
    const target = document.querySelector('#businessesContainer');
    const search = (document.querySelector('#businessSearch')?.value || '').trim().toLocaleLowerCase('es');
    const filtered = cachedBusinesses.filter(b => [b.name, b.slug, b.business_type].some(v => String(v || '').toLocaleLowerCase('es').includes(search)));
    const count = document.querySelector('#businessCount');
    if (count) count.textContent = `${filtered.length} de ${cachedBusinesses.length} negocios`;
    if (!cachedBusinesses.length) { target.innerHTML = '<div class="empty">Todavía no hay negocios. Usa el formulario de arriba para crear el primero.</div>'; return; }
    if (!filtered.length) { target.innerHTML = '<div class="empty">No hay negocios que coincidan con la búsqueda.</div>'; return; }
    target.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Negocio</th><th>Tipo</th><th>Identificador</th><th>Estado / motivo</th><th>Creado</th><th>Acción</th></tr></thead><tbody>${filtered.map(b => `<tr><td><strong>${esc(b.name)}</strong></td><td>${esc(b.business_type)}</td><td>${esc(b.slug)}</td><td><span class="pill ${b.is_active ? 'green':'red'}">${b.is_active ? 'Activo':'Suspendido'}</span>${!b.is_active ? `<br><small>${esc(b.suspension_reason || 'Motivo pendiente de registrar')}</small>` : ''}</td><td>${dateTime(b.created_at)}</td><td><button class="small-button" data-business-status="${esc(b.id)}" data-active="${b.is_active ? 'false':'true'}">${b.is_active ? 'Suspender':'Reactivar'}</button></td></tr>`).join('')}</tbody></table></div>`;
    target.querySelectorAll('[data-business-status]').forEach(button => button.addEventListener('click', () => changeBusinessStatus(button.dataset.businessStatus, button.dataset.active === 'true', button)));
  }

  async function refreshTechnical() {
    const button = document.querySelector('#refreshTechnicalBtn');
    const notice = document.querySelector('#notice');
    if (!button) return;
    button.disabled = true;
    button.textContent = 'Actualizando…';
    try {
      const selectedBusiness = document.querySelector('#businessSelect')?.value || '';
      await loadTechnical();
      const select = document.querySelector('#businessSelect');
      if (select && selectedBusiness && cachedBusinesses.some(b => b.id === selectedBusiness)) {
        select.value = selectedBusiness;
        await loadSelectedBusiness(selectedBusiness);
      }
      if (notice) { notice.textContent = 'Datos actualizados desde Supabase.'; notice.className = 'notice'; }
    } catch (error) {
      if (notice) { notice.textContent = `No se pudieron actualizar los datos: ${error.message || 'Error de consulta'}`; notice.className = 'notice'; }
    } finally { button.disabled = false; button.textContent = 'Actualizar datos'; }
  }


  async function callTechnicalFunction(payload) {
    const { data: sessionData, error: sessionError } = await db.auth.getSession();
    if (sessionError || !sessionData.session?.access_token) throw new Error('La sesión expiró. Cierra sesión y vuelve a ingresar.');
    const response = await fetch(`${window.MIEJE_SUPABASE_URL}/functions/v1/technical-business-management`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': window.MIEJE_SUPABASE_PUBLISHABLE_KEY,
        'Authorization': `Bearer ${sessionData.session.access_token}`
      },
      body: JSON.stringify(payload)
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || `No se pudo completar la operación (${response.status}).`);
    return result;
  }

  async function createBusiness(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const button = form.querySelector('button[type="submit"]');
    const message = document.querySelector('#createBusinessMessage');
    const formData = new FormData(form);
    const payload = Object.fromEntries(formData.entries());
    payload.action = 'create_business';
    button.disabled = true;
    message.className = 'message';
    message.textContent = 'Creando negocio y guardando auditoría…';
    try {
      const result = await callTechnicalFunction(payload);
      message.className = 'message success';
      message.textContent = `Negocio creado: ${result.business.name}. Identificador público: ${result.business.slug}. Ahora puedes invitar a su administrador y empleados.`;
      form.reset();
      form.elements.city.value = 'Pereira, Risaralda';
      await loadTechnical();
      const memberBusinessSelect = document.querySelector('#memberBusinessSelect');
    if (memberBusinessSelect) memberBusinessSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    const suspensionSelect = document.querySelector('#suspensionBusinessSelect');
    if (suspensionSelect) suspensionSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}${b.is_active ? '' : ' (suspendido)'}</option>`).join('');
    const inviteSelect = document.querySelector('#inviteBusinessSelect');
      if (inviteSelect) inviteSelect.value = result.business.id;
      const filterSelect = document.querySelector('#businessSelect');
      if (filterSelect) filterSelect.value = result.business.id;
    } catch (error) {
      message.className = 'message error';
      message.textContent = error.message || 'No se pudo crear el negocio.';
    } finally { button.disabled = false; }
  }

  async function inviteBusinessMember(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const button = form.querySelector('button[type="submit"]');
    const message = document.querySelector('#inviteMemberMessage');
    const payload = Object.fromEntries(new FormData(form).entries());
    payload.action = 'invite_member';
    payload.is_business_owner = form.elements.is_business_owner?.checked === true;
    payload.redirect_to = new URL('aceptar-invitacion.html', window.location.href).href;
    button.disabled = true;
    message.className = 'message';
    message.textContent = 'Creando invitación y registrando la asignación…';
    try {
      const result = await callTechnicalFunction(payload);
      message.className = 'message success';
      message.textContent = `Invitación preparada para ${result.email} como ${result.role === 'business_admin' ? 'administrador' : 'empleado'} de ${result.business}. La persona debe abrir el correo y configurar su contraseña.`;
      const keepBusiness = form.elements.business_id.value;
      form.reset();
      form.elements.business_id.value = keepBusiness;
    } catch (error) {
      message.className = 'message error';
      message.textContent = error.message || 'No se pudo enviar la invitación.';
    } finally { button.disabled = false; }
  }

  async function changeBusinessStatus(id, isActive, button) {
    const business = cachedBusinesses.find(item => item.id === id);
    if (!business) return;
    const verb = isActive ? 'reactivar' : 'suspender';
    const reason = isActive ? (window.prompt(`Nota de reactivación para ${business.name}:`, 'Se revisó el caso y se autoriza la reactivación.') || '') : (window.prompt(`Motivo interno de suspensión de ${business.name}. Lo verán el propietario, administrador y personal:`, '') || '');
    if (!isActive && reason.trim().length < 5) { alert('Escribe un motivo de al menos 5 caracteres. No se realizó ningún cambio.'); return; }
    const publicMessage = isActive ? '' : (window.prompt('Mensaje distinto para los clientes:', 'Esta tienda no está disponible temporalmente. Contacta con el negocio para más información.') || 'Esta tienda no está disponible temporalmente.');
    if (!window.confirm(`¿Deseas ${verb} el negocio "${business.name}"?`)) return;
    button.disabled = true;
    try {
      const result = await callTechnicalFunction({ action: 'set_business_status', business_id: id, is_active: isActive, reason, public_message: publicMessage });
      document.querySelector('#notice').textContent = result.message;
      document.querySelector('#notice').className = 'notice';
      await loadTechnical();
    } catch (error) {
      alert(error.message || 'No se pudo cambiar el estado del negocio.');
      button.disabled = false;
    }
  }

  async function loadSelectedBusiness(id) {
    const ordersTarget = document.querySelector('#businessOrdersContainer');
    if (!id) {
      ordersTarget.innerHTML = '<div class="empty">Selecciona un negocio para consultar sus pedidos. Los accesos y la auditoría muestran todos los negocios.</div>';
      await Promise.all([loadAccessEvents(null, '#accessContainer'), loadAuditEvents(null, '#auditContainer')]);
      return;
    }
    const business = cachedBusinesses.find(b => b.id === id);
    if (!business) return;
    const { data: orders, error: ordersError } = await db.rpc('get_business_orders', { p_business_id: id, p_panel: 'business_admin' });
    if (ordersError) showError(ordersTarget, ordersError);
    else renderOrders(ordersTarget, orders || [], true);
    await Promise.all([loadAccessEvents(id, '#accessContainer'), loadAuditEvents(id, '#auditContainer')]);
  }

  async function loadTechnicalMembers(id) {
    const target=document.querySelector('#memberTargetSelect'); if(!target) return;
    target.innerHTML='<option value="">Cargando cuentas…</option>'; if(!id){target.innerHTML='<option value="">Selecciona primero un negocio</option>';return;}
    const {data,error}=await db.from('business_members').select('user_id,role,is_active,is_blocked,profiles(display_name)').eq('business_id',id).order('created_at',{ascending:false});
    if(error){target.innerHTML='<option value="">No se pudieron cargar las cuentas</option>';return;}
    target.innerHTML='<option value="">Selecciona una cuenta</option>'+(data||[]).map(m=>`<option value="${esc(m.user_id)}">${esc(m.profiles?.display_name||shortId(m.user_id))} · ${m.role==='business_admin'?'Administrador':'Empleado'}${m.is_blocked?' · Bloqueado':''}${!m.is_active?' · Inactivo':''}</option>`).join('');
  }

  async function saveMemberStatus(event) {
    event.preventDefault(); const form=event.currentTarget, message=document.querySelector('#memberStatusMessage');
    const blocked=form.elements.is_blocked.value==='true'; const reason=form.elements.reason.value.trim();
    if(blocked && reason.length<5){message.textContent='Para bloquear una cuenta debes escribir un motivo de al menos 5 caracteres.';message.className='message error';return;}
    message.textContent='Aplicando cambio y registrando auditoría…';
    try{const result=await callTechnicalFunction({action:'set_member_status',business_id:form.elements.business_id.value,user_id:form.elements.user_id.value,is_blocked:blocked,reason});message.textContent=result.message;message.className='message success';await loadTechnicalMembers(form.elements.business_id.value);await loadBlockRequests();}
    catch(error){message.textContent=error.message;message.className='message error';}
  }

  async function saveSuspension(event) {
    event.preventDefault();
    const form = event.currentTarget, message = document.querySelector('#suspensionMessage');
    const data = Object.fromEntries(new FormData(form).entries());
    data.action = 'set_business_status'; data.is_active = data.is_active === 'true';
    if (!data.is_active && String(data.reason || '').trim().length < 5) { message.textContent = 'El motivo debe tener al menos 5 caracteres.'; return; }
    message.textContent = 'Guardando estado y auditoría…';
    try { const result = await callTechnicalFunction(data); message.textContent = result.message; message.className = 'message success'; await loadTechnical(); }
    catch (error) { message.textContent = error.message; message.className = 'message error'; }
  }

  async function initPlatformAi() {
    const form = document.querySelector('#platformAiForm'); if (!form) return;
    const [aiResult, supportResult] = await Promise.all([
      db.from('platform_ai_settings').select('enabled,assistant_name,system_instructions,settings').eq('id', true).maybeSingle(),
      db.from('platform_public_settings').select('support_whatsapp').eq('id', true).maybeSingle()
    ]);
    if (aiResult.error) { document.querySelector('#platformAiMessage').textContent = 'No se pudo leer la configuración: ' + aiResult.error.message; return; }
    const data = aiResult.data;
    form.elements.support_whatsapp.value = supportResult.data?.support_whatsapp || data?.settings?.support_whatsapp || '';
    form.elements.assistant_name.value = data?.assistant_name || 'Asistente general de MiEje Market';
    form.elements.system_instructions.value = data?.system_instructions || '';
    form.elements.enabled.checked = Boolean(data?.enabled);
  }

  async function savePlatformAi(event) {
    event.preventDefault(); const form = event.currentTarget, message = document.querySelector('#platformAiMessage');
    const { data: old } = await db.from('platform_ai_settings').select('settings').eq('id', true).maybeSingle();
    const support = form.elements.support_whatsapp.value.replace(/[^0-9]/g, '').slice(0, 18);
    const payload = { id: true, enabled: form.elements.enabled.checked, assistant_name: form.elements.assistant_name.value.trim(), system_instructions: form.elements.system_instructions.value.trim(), settings: { ...(old?.settings || {}), support_whatsapp: support }, updated_by: currentUser.id, updated_at: new Date().toISOString() };
    const { error } = await db.from('platform_ai_settings').upsert(payload, { onConflict: 'id' });
    if (error) { message.textContent = `No se pudo guardar: ${error.message}`; message.className = 'message error'; return; }
    const { error: supportError } = await db.from('platform_public_settings').upsert({ id: true, support_whatsapp: support, updated_by: currentUser.id, updated_at: new Date().toISOString() }, { onConflict: 'id' });
    message.textContent = supportError ? `IA guardada, pero falló el número de soporte: ${supportError.message}` : 'Configuración general y WhatsApp de soporte guardados.'; message.className = supportError ? 'message error' : 'message success';
  }

  async function showSupportLink() {
    const link = document.querySelector('#technicalSupportLink'); if (!link) return;
    const { data } = await db.from('platform_public_settings').select('support_whatsapp').eq('id', true).maybeSingle();
    const phone = String(data?.support_whatsapp || '').replace(/[^0-9]/g, '');
    if (phone) { link.href = `https://wa.me/${phone}?text=${encodeURIComponent('Hola, necesito ayuda con mi acceso a MiEje Market.')}`; link.classList.remove('hidden'); }
    else { link.href = '#'; link.classList.add('hidden'); const msg = document.querySelector('#technicalSupportMessage'); if (msg) msg.textContent = 'El servicio técnico aún no ha configurado su número de WhatsApp.'; }
  }

  async function initBusinessSettings() {
    await showSupportLink();
    const [settingsResult, contentResult, aiResult, membersResult, applicationsResult] = await Promise.all([
      db.from('business_store_settings').select('*').eq('business_id', businessId).maybeSingle(),
      db.from('business_content_pages').select('id,content_type,title,body,is_published,moderation_status,moderation_note,created_at').eq('business_id', businessId).order('created_at', { ascending: false }).limit(50),
      db.from('business_ai_settings').select('enabled,assistant_name,instructions').eq('business_id', businessId).maybeSingle(),
      db.from('business_members').select('user_id,role,is_active,is_blocked,is_business_owner,profiles(display_name)').eq('business_id', businessId),
      db.from('job_applications').select('id,content_page_id,applicant_name,applicant_contact,applicant_message,application_data,status,created_at').eq('business_id', businessId).order('created_at', {ascending:false}).limit(100)
    ]);
    const sf = document.querySelector('#storeSettingsForm');
    if (sf && !settingsResult.error && settingsResult.data) { const x=settingsResult.data; sf.elements.whatsapp_number.value=x.whatsapp_number||''; sf.elements.payment_methods.value=(x.payment_methods||[]).map(v=>typeof v==='string'?v:v.label||'').join('\n'); sf.elements.delivery_options.value=(x.delivery_options||[]).map(v=>typeof v==='string'?v:v.label||'').join('\n'); sf.elements.contact_options.value=(x.contact_options?.notes||[]).join('\n'); }
    const af=document.querySelector('#businessAiForm'); if (af && !aiResult.error && aiResult.data) { af.elements.assistant_name.value=aiResult.data.assistant_name||'Asistente del negocio'; af.elements.instructions.value=aiResult.data.instructions||''; af.elements.enabled.checked=Boolean(aiResult.data.enabled); }
    const content=document.querySelector('#businessContentList'); if(content) { const rows=contentResult.data||[]; content.innerHTML=rows.length?tableHtml(['Tipo','Título','Estado','Fecha'],rows.map(x=>[x.content_type,x.title,x.moderation_status==='approved'?(x.is_published?'Aprobado y publicado':'Aprobado / oculto'):x.moderation_status==='rejected'?'Rechazado':'Pendiente de revisión',dateTime(x.created_at)])):'<div class="empty">Todavía no hay promociones ni formularios publicados.</div>'; if(contentResult.error) showError(content,contentResult.error); }
    const blockForm=document.querySelector('#blockRequestForm'); const ownerNote=document.querySelector('#blockRequestOwnerNote'); if(blockForm && !isBusinessOwner){blockForm.classList.add('hidden'); ownerNote?.classList.remove('hidden');} else {blockForm?.classList.remove('hidden'); ownerNote?.classList.add('hidden');}
    const target=document.querySelector('#blockTargetUser'); if(target) { const rows=(membersResult.data||[]).filter(m=>m.user_id!==currentUser.id && m.is_active); target.innerHTML='<option value="">Selecciona una cuenta</option>'+rows.map(m=>`<option value="${esc(m.user_id)}">${esc(m.profiles?.display_name||shortId(m.user_id))} · ${m.role==='business_admin'?'Administrador':'Empleado'}${m.is_blocked?' · Bloqueado':''}</option>`).join(''); if(membersResult.error) target.innerHTML='<option value="">No se pudieron cargar las cuentas</option>'; }
    const applications=document.querySelector('#jobApplicationsContainer'); if(applications){ const rows=applicationsResult.data||[]; applications.innerHTML=applicationsResult.error?`<div class="empty">No se pudieron cargar las postulaciones: ${esc(applicationsResult.error.message)}</div>`:rows.length?`<div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Postulante</th><th>Contacto</th><th>Mensaje</th><th>Estado</th><th>Acción</th></tr></thead><tbody>${rows.map(a=>`<tr><td>${dateTime(a.created_at)}</td><td>${esc(a.applicant_name)}</td><td>${esc(a.applicant_contact)}</td><td>${esc(a.applicant_message||'—')}${a.application_data&&Object.keys(a.application_data).length?`<br><small>Campos adicionales: ${esc(JSON.stringify(a.application_data))}</small>`:''}</td><td>${esc(a.status)}</td><td><select class="field" data-application-status="${esc(a.id)}"><option value="new" ${a.status==='new'?'selected':''}>Nueva</option><option value="reviewing" ${a.status==='reviewing'?'selected':''}>En revisión</option><option value="contacted" ${a.status==='contacted'?'selected':''}>Contactado</option><option value="closed" ${a.status==='closed'?'selected':''}>Cerrada</option></select></td></tr>`).join('')}</tbody></table></div>`:'<div class="empty">No hay postulaciones recibidas.</div>'; applications.querySelectorAll('[data-application-status]').forEach(select=>select.addEventListener('change',async()=>{const {error}=await db.from('job_applications').update({status:select.value}).eq('id',select.dataset.applicationStatus).eq('business_id',businessId);if(error){alert('No se pudo actualizar el estado: '+error.message);await initBusinessSettings();}})); }
  }

  async function saveStoreSettings(event) {
    event.preventDefault(); const form=event.currentTarget, message=document.querySelector('#storeSettingsMessage');
    const list = name => form.elements[name].value.split('\n').map(v=>v.trim()).filter(Boolean).map(label=>({label,enabled:true}));
    const contactNotes=form.elements.contact_options.value.split('\n').map(v=>v.trim()).filter(Boolean).slice(0,30);
    const payload={business_id:businessId,whatsapp_number:form.elements.whatsapp_number.value.replace(/[^0-9]/g,'').slice(0,18),payment_methods:list('payment_methods'),delivery_options:list('delivery_options'),contact_options:{notes:contactNotes},updated_by:currentUser.id,updated_at:new Date().toISOString()};
    const {error}=await db.from('business_store_settings').upsert(payload,{onConflict:'business_id'}); message.textContent=error?`No se pudo guardar: ${error.message}`:'Configuración de pago, entrega y contacto guardada.'; message.className=error?'message error':'message success';
  }

  async function saveBusinessContent(event) {
    event.preventDefault(); const form=event.currentTarget, message=document.querySelector('#businessContentMessage');
    const contentType=form.elements.content_type.value; const fields=form.elements.form_fields.value.split('\n').map(v=>v.trim()).filter(Boolean).slice(0,30);
    const payload={business_id:businessId,content_type:contentType,title:form.elements.title.value.trim(),body:form.elements.body.value.trim(),content:{form_fields:contentType==='job_form'?fields:[]},is_published:form.elements.is_published.checked,created_by:currentUser.id,updated_by:currentUser.id,updated_at:new Date().toISOString()};
    const {error}=await db.from('business_content_pages').insert(payload); message.textContent=error?`No se pudo guardar: ${error.message}`:'Contenido guardado y enviado a revisión técnica. No aparecerá públicamente hasta ser aprobado.'; message.className=error?'message error':'message success'; if(!error){form.reset(); await initBusinessSettings();}
  }

  async function saveBusinessAi(event) {
    event.preventDefault(); const form=event.currentTarget, message=document.querySelector('#businessAiMessage');
    const payload={business_id:businessId,enabled:form.elements.enabled.checked,assistant_name:form.elements.assistant_name.value.trim(),instructions:form.elements.instructions.value.trim(),updated_by:currentUser.id,updated_at:new Date().toISOString()};
    const {error}=await db.from('business_ai_settings').upsert(payload,{onConflict:'business_id'}); message.textContent=error?`No se pudo guardar: ${error.message}`:'Configuración de IA de este negocio guardada por separado de la IA general.'; message.className=error?'message error':'message success';
  }

  async function submitBlockRequest(event) {
    event.preventDefault(); const form=event.currentTarget, message=document.querySelector('#blockRequestMessage');
    const payload={business_id:businessId,requested_by:currentUser.id,target_user_id:form.elements.target_user_id.value,reason:form.elements.reason.value.trim()};
    const {error}=await db.from('access_block_requests').insert(payload); message.textContent=error?`No se pudo enviar la solicitud: ${error.message}`:'Solicitud enviada al servicio técnico. El acceso no se bloquea hasta que el técnico la revise.'; message.className=error?'message error':'message success'; if(!error) form.reset();
  }

  async function loadFinance() {
    const target = document.querySelector('#financeContainer');
    const [financeResult, payrollResult] = await Promise.all([
      db.from('platform_financial_records').select('business_id,record_type,description,amount,currency,occurred_at').order('occurred_at', { ascending: false }).limit(30),
      db.from('payroll_records').select('business_id,payee_name,description,amount,currency,status,paid_at,created_at').order('created_at', { ascending: false }).limit(30)
    ]);
    if (financeResult.error) return showError(target, financeResult.error);
    if (payrollResult.error) return showError(target, payrollResult.error);
    const businessMap = new Map(cachedBusinesses.map(b => [b.id, b.name]));
    const finance = financeResult.data || [];
    const payroll = payrollResult.data || [];
    target.innerHTML = `<div class="split"><div><div class="section-heading"><h3>Movimientos financieros</h3></div>${finance.length ? tableHtml(['Fecha','Negocio','Tipo','Descripción','Importe'], finance.map(r => [dateTime(r.occurred_at), r.business_id ? businessMap.get(r.business_id) || 'Negocio' : 'Plataforma', r.record_type, r.description, money(r.amount)])) : '<div class="empty">Sin movimientos financieros registrados.</div>'}</div><div><div class="section-heading"><h3>Nómina y honorarios</h3></div>${payroll.length ? tableHtml(['Fecha','Beneficiario','Descripción','Importe','Estado'], payroll.map(r => [dateTime(r.paid_at || r.created_at), r.payee_name, r.description, money(r.amount), r.status])) : '<div class="empty">Sin registros de nómina.</div>'}</div></div>`;
  }

  async function loadContentModeration() {
    const target=document.querySelector('#contentModerationContainer'); if(!target) return;
    const {data,error}=await db.from('business_content_pages').select('id,business_id,content_type,title,body,is_published,moderation_status,created_at,businesses(name)').order('created_at',{ascending:false}).limit(100);
    if(error){showError(target,error);return;} const rows=data||[]; if(!rows.length){target.innerHTML='<div class="empty">No hay publicaciones enviadas por los negocios.</div>';return;}
    target.innerHTML=`<div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Negocio</th><th>Tipo</th><th>Título y contenido</th><th>Estado</th><th>Acción</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${dateTime(r.created_at)}</td><td>${esc(r.businesses?.name||shortId(r.business_id))}</td><td>${esc(r.content_type)}</td><td><strong>${esc(r.title)}</strong><br>${esc(r.body)}</td><td>${esc(r.moderation_status||'pending')}</td><td>${r.moderation_status!=='approved'?`<button class="small-button" data-moderate-content="${esc(r.id)}" data-decision="approved">Aprobar</button>`:''} ${r.moderation_status!=='rejected'?`<button class="small-button" data-moderate-content="${esc(r.id)}" data-decision="rejected">Rechazar</button>`:'—'}</td></tr>`).join('')}</tbody></table></div>`;
    target.querySelectorAll('[data-moderate-content]').forEach(btn=>btn.addEventListener('click',async()=>{const note=window.prompt('Nota de revisión (opcional):','')||'';btn.disabled=true;try{const result=await callTechnicalFunction({action:'moderate_business_content',content_id:btn.dataset.moderateContent,decision:btn.dataset.decision,moderation_note:note});alert(result.message);await loadContentModeration();await loadAuditEvents(null,'#auditContainer');}catch(e){alert(e.message);btn.disabled=false;}}));
  }

  async function loadBlockRequests() {
    const target=document.querySelector('#blockRequestsContainer'); if(!target) return;
    const {data,error}=await db.from('access_block_requests').select('id,business_id,requested_by,target_user_id,reason,status,created_at,businesses(name)').order('created_at',{ascending:false}).limit(100);
    if(error){showError(target,error);return;} const rows=data||[]; if(!rows.length){target.innerHTML='<div class="empty">No hay solicitudes de bloqueo pendientes.</div>';return;}
    const names=await getUserNames(rows.flatMap(r=>[r.requested_by,r.target_user_id]));
    target.innerHTML=`<div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Negocio</th><th>Solicitante</th><th>Cuenta solicitada</th><th>Motivo</th><th>Estado</th><th>Acción</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${dateTime(r.created_at)}</td><td>${esc(r.businesses?.name||shortId(r.business_id))}</td><td>${esc(names.get(r.requested_by)||shortId(r.requested_by))}</td><td>${esc(names.get(r.target_user_id)||shortId(r.target_user_id))}</td><td>${esc(r.reason)}</td><td>${esc(r.status)}</td><td>${r.status==='pending'?`<button class="small-button" data-request-resolve="${esc(r.id)}" data-decision="approved">Bloquear cuenta</button> <button class="small-button" data-request-resolve="${esc(r.id)}" data-decision="rejected">Rechazar</button>`:'—'}</td></tr>`).join('')}</tbody></table></div>`;
    target.querySelectorAll('[data-request-resolve]').forEach(btn=>btn.addEventListener('click',async()=>{ const note=window.prompt('Nota del servicio técnico (opcional):','')||''; btn.disabled=true; try{const result=await callTechnicalFunction({action:'resolve_block_request',request_id:btn.dataset.requestResolve,decision:btn.dataset.decision,technician_note:note}); alert(result.message); await loadBlockRequests(); await loadTechnical();}catch(e){alert(e.message);btn.disabled=false;} }));
  }

  async function loadAccessEvents(id, selector) {
    const target = document.querySelector(selector);
    let query = db.from('access_events').select('id,business_id,user_id,panel,event_type,created_at,user_agent');
    if (id) query = query.eq('business_id', id);
    else if (panel !== 'technical') query = query.is('business_id', null);
    const { data, error } = await query.order('created_at', { ascending: false }).limit(100);
    if (error) return showError(target, error);
    const userNames = await getUserNames((data || []).map(e => e.user_id));
    if (!data?.length) { target.innerHTML = '<div class="empty">No hay registros de acceso para este filtro todavía.</div>'; return; }
    target.innerHTML = tableHtml(['Fecha y hora','Usuario','Panel','Evento','Navegador'], data.map(e => [dateTime(e.created_at), userNames.get(e.user_id) || shortId(e.user_id), panelLabel(e.panel), e.event_type === 'login_success' ? 'Inicio de sesión' : 'Entrada al panel', e.user_agent || 'No disponible']));
  }

  async function loadAuditEvents(id, selector) {
    const target = document.querySelector(selector);
    let query = db.from('audit_events').select('id,business_id,actor_user_id,action,table_name,record_id,old_data,new_data,created_at');
    if (id) query = query.eq('business_id', id);
    else if (panel !== 'technical') query = query.is('business_id', null);
    const { data, error } = await query.order('created_at', { ascending: false }).limit(100);
    if (error) return showError(target, error);
    const userNames = await getUserNames((data || []).map(e => e.actor_user_id));
    if (!data?.length) { target.innerHTML = '<div class="empty">No hay cambios de auditoría para este filtro todavía.</div>'; return; }
    target.innerHTML = tableHtml(['Fecha y hora','Usuario','Acción','Tabla','Registro','Resumen'], data.map(e => [dateTime(e.created_at), userNames.get(e.actor_user_id) || shortId(e.actor_user_id), e.action, e.table_name, e.record_id || '—', summarizeChange(e.old_data, e.new_data)]));
  }

  async function getUserNames(ids) {
    const unique = [...new Set(ids.filter(Boolean))];
    const map = new Map();
    if (!unique.length) return map;
    const { data, error } = await db.from('profiles').select('id,display_name').in('id', unique);
    if (!error) (data || []).forEach(p => map.set(p.id, p.display_name));
    return map;
  }

  function renderOrders(target, orders, admin) {
    if (!orders.length) { target.innerHTML = '<div class="empty">No hay pedidos registrados en este negocio.</div>'; return; }
    const rows = orders.map(o => {
      const items = Array.isArray(o.items) ? o.items.map(i => `${esc(i.product_name)} × ${esc(i.quantity)}`).join('<br>') : '';
      const action = nextStatus[o.status] ? `<button class="small-button" data-next="${nextStatus[o.status]}" data-order="${esc(o.id)}">Marcar: ${statusLabels[nextStatus[o.status]]}</button>` : '—';
      const base = [esc(`#${o.order_number}`), esc(o.customer_name || 'Cliente'), esc(o.customer_phone || '—'), esc(o.delivery_address || '—'), items || 'Sin detalle', `<span class="pill ${statusClass[o.status] || ''}">${statusLabels[o.status] || esc(o.status)}</span>`, dateTime(o.created_at)];
      if (admin) base.splice(5, 0, `${money(o.total)}<br><small>${esc(o.payment_status || '—')}</small>`);
      else base.push(action);
      return base;
    });
    const headers = admin ? ['Pedido','Cliente','Teléfono','Entrega','Productos','Total / pago','Estado','Creado'] : ['Pedido','Cliente','Teléfono','Entrega','Productos','Estado','Creado','Acción'];
    target.innerHTML = tableHtml(headers, rows);
    target.querySelectorAll('[data-next][data-order]').forEach(button => button.addEventListener('click', () => changeOrderStatus(button.dataset.order, button.dataset.next, button)));
  }

  async function changeOrderStatus(orderId, next, button) {
    button.disabled = true;
    const { error } = await db.from('orders').update({ status: next }).eq('id', orderId).eq('business_id', businessId);
    if (error) {
      alert(`No se pudo cambiar el estado: ${error.message}`);
      button.disabled = false;
      return;
    }
    if (panel === 'employee') await loadEmployeeOrders(); else await loadBusinessOrders();
  }

  function renderStats(items) {
    const target = document.querySelector('#statsGrid');
    target.innerHTML = items.map(([label, value, detail]) => `<article class="stat"><span>${esc(label)}</span><strong>${esc(value)}</strong><small>${esc(detail)}</small></article>`).join('');
  }
  function tableHtml(headers, rows) {
    return `<div class="table-wrap"><table><thead><tr>${headers.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.map(row => `<tr>${row.map(cell => `<td>${cell === null || cell === undefined ? '—' : cell}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
  }
  function summarizeChange(oldData, newData) {
    const data = newData || oldData;
    if (!data || typeof data !== 'object') return '—';
    const keys = Object.keys(data).filter(k => !['id','created_at','updated_at','business_id'].includes(k)).slice(0, 3);
    return esc(keys.map(k => `${k}: ${String(data[k] ?? '—').slice(0, 60)}`).join(' · ') || 'Cambio registrado');
  }
  function showError(target, error) { target.innerHTML = `<div class="empty">No se pudieron cargar estos datos: ${esc(error.message || 'Error de consulta')}</div>`; }
  function esc(value) { return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
  function money(value) { return new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 0 }).format(Number(value || 0)); }
  function number(value) { return new Intl.NumberFormat('es-CO').format(Number(value || 0)); }
  function dateTime(value) { return value ? new Intl.DateTimeFormat('es-CO', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'America/Bogota' }).format(new Date(value)) : '—'; }
  function shortId(value) { return value ? `${value.slice(0, 8)}…` : 'Sistema'; }
  function panelLabel(value) { return ({ business_admin: 'Administrativo', employee: 'Personal', technical: 'Técnico superior' })[value] || value; }
})();
