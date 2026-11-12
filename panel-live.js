(() => {
  const panel = document.body.dataset.panel;
  let db;
  let currentUser;
  let currentProfile;
  let businessId = null;
  let businessName = '';
  let isBusinessOwner = false;
  let cachedBusinesses = [];
  let cachedProducts = [];
  const statusLabels = {
    pending: 'Recibido', confirmed: 'Confirmado', preparing: 'En preparación',
    ready: 'Listo', out_for_delivery: 'En camino', delivered: 'Entregado', cancelled: 'Cancelado'
  };
  const nextStatus = { pending: 'confirmed', confirmed: 'preparing', preparing: 'ready', ready: 'out_for_delivery', out_for_delivery: 'delivered' };
  const statusClass = { pending: 'yellow', confirmed: 'blue', preparing: 'blue', ready: 'green', out_for_delivery: 'blue', delivered: 'green', cancelled: 'red' };

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
      const { data: access, error: accessError } = await db.functions.invoke('resolve-my-access', { body: {} });
      if (accessError || !access?.ok || !access.profile) throw new Error(access?.error || 'No se pudo verificar tu acceso. Cierra sesión y vuelve a ingresar.');
      currentProfile = access.profile;
      const profile = access.profile;
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
      document.querySelector('#productForm')?.addEventListener('submit', saveProduct);
      document.querySelector('#businessContentForm')?.addEventListener('submit', saveBusinessContent);
      document.querySelector('#businessAiForm')?.addEventListener('submit', saveBusinessAi);
      document.querySelector('#blockRequestForm')?.addEventListener('submit', submitBlockRequest);
      document.querySelector('#refreshOrders')?.addEventListener('click', () => panel === 'business_admin' ? loadBusinessOrders() : loadEmployeeOrders());

      if (panel === 'technical') {
        if (!access.is_platform_owner || profile.platform_role !== 'platform_owner') throw new Error('Esta sección es exclusiva del propietario técnico autorizado.');
        await logPanel(null, 'technical', 'panel_open');
        notice.textContent = 'Acceso validado. Consultando datos disponibles del proyecto independiente.';
        notice.className = 'notice';
        await loadTechnical();
      } else {
        const available = access.memberships || [];
        const requested = new URLSearchParams(window.location.search).get('business');
        const match = available.find(m => m.business_id === requested) || (available.length === 1 ? available[0] : null);
        if (!match) throw new Error('No tienes un negocio activo asignado a esta cuenta o el negocio no coincide. Vuelve al inicio de sesión.');
        if (panel === 'business_admin' && match.role !== 'business_admin') throw new Error('Tu cuenta no tiene el rol administrativo requerido para este panel.');
        if (panel === 'employee' && match.role !== 'employee') throw new Error('Tu cuenta no tiene permiso para el panel del personal.');
        businessId = match.business_id;
        businessName = match.business.name;
        isBusinessOwner = match.role === 'business_admin';
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
    const result = await callTechnicalFunction({ action: 'log_login', business_id: id, panel: panelName });
    if (!result?.ok) throw new Error('No se pudo registrar el acceso.');
  }

  async function signOut() {
    try { await db.auth.signOut(); } finally { window.location.replace('login.html'); }
  }

  async function loadBusinessAdmin() {
    const [ordersResult, productsResult] = await Promise.all([
      db.from('orders').select('id,total,payment_status,status,created_at').eq('business_id', businessId),
      db.from('products').select('id,inventory,is_active').eq('business_id', businessId)
    ]);
    if (ordersResult.error) throw ordersResult.error;
    if (productsResult.error) throw productsResult.error;
    const orders = ordersResult.data || [], products = productsResult.data || [];
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bogota' });
    const todayOrders = orders.filter(o => new Date(o.created_at).toLocaleDateString('en-CA', { timeZone: 'America/Bogota' }) === today && o.status !== 'cancelled');
    const received = orders.filter(o => o.payment_status === 'paid').reduce((sum,o) => sum + Number(o.total || 0), 0);
    renderStats([
      ['Ventas de hoy', money(todayOrders.reduce((sum,o) => sum + Number(o.total || 0), 0)), 'Pedidos creados hoy, sin cancelados'],
      ['Dinero recibido', money(received), 'Pedidos marcados como pagados'],
      ['Pedidos abiertos', number(orders.filter(o => !['delivered','cancelled'].includes(o.status)).length), 'Pendientes de completar'],
      ['Productos con poco stock', number(products.filter(p => p.is_active && Number(p.inventory || 0) <= 5).length), 'Cinco unidades o menos']
    ]);
    await Promise.all([loadBusinessOrders(), loadProducts(), loadAccessEvents(businessId, '#accessContainer'), loadAuditEvents(businessId, '#auditContainer')]);
  }

  async function saveProduct(event) {
    event.preventDefault();
    const form = event.currentTarget, message = document.querySelector('#productMessage');
    const name = form.elements.name.value.trim();
    const price = Number(form.elements.price.value);
    const inventory = Number(form.elements.inventory.value);
    if (!name || !Number.isFinite(price) || price < 0 || !Number.isInteger(inventory) || inventory < 0) {
      message.textContent = 'Revisa el nombre, el precio y las existencias. El precio debe ser igual o mayor que cero y las existencias un número entero.';
      message.className = 'message error';
      return;
    }
    const payload = {
      business_id: businessId,
      name,
      category: form.elements.category.value.trim() || null,
      description: form.elements.description.value.trim() || null,
      price,
      inventory,
      image_url: form.elements.image_url.value.trim() || null,
      is_active: form.elements.is_active.checked,
      updated_at: new Date().toISOString()
    };
    const id = form.elements.id.value;
    message.textContent = 'Guardando producto…';
    message.className = 'message';
    const result = id
      ? await db.from('products').update(payload).eq('id', id).eq('business_id', businessId)
      : await db.from('products').insert(payload);
    if (result.error) {
      message.textContent = 'No se pudo guardar el producto: ' + result.error.message;
      message.className = 'message error';
      return;
    }
    form.reset();
    form.elements.id.value = '';
    message.textContent = id ? 'Producto actualizado.' : 'Producto creado.';
    message.className = 'message success';
    await loadProducts();
  }

  function editProduct(id) {
    const product = cachedProducts.find(item => item.id === id);
    const form = document.querySelector('#productForm');
    if (!product || !form) return;
    form.elements.id.value = product.id;
    form.elements.name.value = product.name || '';
    form.elements.category.value = product.category || '';
    form.elements.description.value = product.description || '';
    form.elements.price.value = product.price ?? 0;
    form.elements.inventory.value = product.inventory ?? 0;
    form.elements.image_url.value = product.image_url || '';
    form.elements.is_active.checked = Boolean(product.is_active);
    const message = document.querySelector('#productMessage');
    message.textContent = 'Editando: ' + product.name;
    message.className = 'message';
    form.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  async function toggleProductStatus(id, button) {
    const product = cachedProducts.find(item => item.id === id);
    if (!product) return;
    const action = product.is_active ? 'desactivar' : 'activar';
    if (!window.confirm(`¿Deseas ${action} el producto "${product.name}"? No se eliminará del historial de pedidos.`)) return;
    button.disabled = true;
    const { error } = await db.from('products').update({ is_active: !product.is_active, updated_at: new Date().toISOString() }).eq('id', id).eq('business_id', businessId);
    if (error) {
      alert('No se pudo cambiar el estado del producto: ' + error.message);
      button.disabled = false;
      return;
    }
    await loadProducts();
  }

  async function loadBusinessOrders() {
    const target = document.querySelector('#ordersContainer');
    target.innerHTML = '<div class="empty">Cargando pedidos…</div>';
    const { data, error } = await db.from('orders').select('id,order_number,customer_name,customer_phone,delivery_address,payment_status,status,total,created_at,order_items(product_name,quantity)').eq('business_id', businessId).order('created_at', { ascending: false }).limit(100);
    if (error) return showError(target, error);
    renderOrders(target, (data || []).map(o => ({ ...o, items: o.order_items || [] })), true);
  }

  async function loadEmployeeOrders() {
    const target = document.querySelector('#ordersContainer');
    target.innerHTML = '<div class="empty">Cargando pedidos…</div>';
    const { data, error } = await db.from('orders').select('id,order_number,customer_name,customer_phone,delivery_address,status,created_at,order_items(product_name,quantity)').eq('business_id', businessId).order('created_at', { ascending: false }).limit(100);
    if (error) return showError(target, error);
    renderOrders(target, (data || []).map(o => ({ ...o, items: o.order_items || [] })), false);
  }

  async function loadProducts() {
    const target = document.querySelector('#productsContainer');
    const { data, error } = await db.from('products').select('id,name,category,description,price,inventory,image_url,is_active').eq('business_id', businessId).order('name').limit(250);
    if (error) return showError(target, error);
    cachedProducts = data || [];
    if (!cachedProducts.length) { target.innerHTML = '<div class="empty">Este negocio todavía no tiene productos registrados. Puedes crear el primero en el formulario.</div>'; return; }
    target.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Producto</th><th>Categoría</th><th>Precio</th><th>Existencias</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>${cachedProducts.map(p => `<tr><td><strong>${esc(p.name)}</strong>${p.image_url ? `<br><a href="${esc(p.image_url)}" target="_blank" rel="noopener">Ver imagen</a>` : ''}<br><small>${esc(p.description || '')}</small></td><td>${esc(p.category || '—')}</td><td>${money(p.price)}</td><td>${number(p.inventory)}</td><td><span class="pill ${p.is_active ? 'green':'red'}">${p.is_active ? 'Activo':'Inactivo'}</span></td><td><button class="small-button" data-edit-product="${esc(p.id)}">Editar</button> <button class="small-button" data-toggle-product="${esc(p.id)}">${p.is_active ? 'Desactivar':'Activar'}</button></td></tr>`).join('')}</tbody></table></div>`;
    target.querySelectorAll('[data-edit-product]').forEach(button => button.addEventListener('click', () => editProduct(button.dataset.editProduct)));
    target.querySelectorAll('[data-toggle-product]').forEach(button => button.addEventListener('click', () => toggleProductStatus(button.dataset.toggleProduct, button)));
  }

  async function loadTechnical() {
    const result = await callTechnicalFunction({ action: 'list_businesses' });
    cachedBusinesses = result.businesses || [];
    const [productsResult, ordersResult, auditResult] = await Promise.all([
      db.from('products').select('id', { count: 'exact', head: true }),
      db.from('orders').select('id,status,total', { count: 'exact' }),
      db.from('audit_logs').select('id', { count: 'exact', head: true })
    ]);
    if (productsResult.error) throw productsResult.error;
    if (ordersResult.error) throw ordersResult.error;
    if (auditResult.error) throw auditResult.error;
    const activeOrders = ordersResult.data || [];
    renderStats([
      ['Negocios', number(cachedBusinesses.length), `${number(cachedBusinesses.filter(b => b.status === 'active').length)} activos`],
      ['Productos', number(productsResult.count || 0), 'En todos los negocios'],
      ['Pedidos', number(ordersResult.count || activeOrders.length), `${number(activeOrders.filter(o => !['delivered','cancelled'].includes(o.status)).length)} abiertos`],
      ['Ventas registradas', money(activeOrders.reduce((sum,o) => sum + Number(o.total || 0), 0)), 'Total de pedidos consultables'],
      ['Eventos de auditoría', number(auditResult.count || 0), 'Registros en audit_logs']
    ]);
    const options = `<option value="">Todos los negocios</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}${b.status === 'active' ? '' : ' (inactivo)'}</option>`).join('');
    const select = document.querySelector('#businessSelect'); if (select) select.innerHTML = options;
    const memberSelect = document.querySelector('#memberBusinessSelect'); if (memberSelect) memberSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    const suspensionSelect = document.querySelector('#suspensionBusinessSelect'); if (suspensionSelect) suspensionSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}${b.status === 'active' ? '' : ' (suspendido)'}</option>`).join('');
    const inviteSelect = document.querySelector('#inviteBusinessSelect'); if (inviteSelect) inviteSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.filter(b => b.status === 'active').map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    renderBusinesses();
    await loadSelectedBusiness('');
    await loadAuditEvents(null, '#auditContainer');
    const finance = document.querySelector('#financeContainer'); if (finance) finance.innerHTML = '<div class="empty">El módulo financiero global y nómina aún no está conectado al esquema independiente.</div>';
    const blocks = document.querySelector('#blockRequestsContainer'); if (blocks) blocks.innerHTML = '<div class="empty">Las solicitudes de bloqueo no están disponibles en este proyecto todavía.</div>';
    const moderation = document.querySelector('#contentModerationContainer'); if (moderation) moderation.innerHTML = '<div class="empty">La moderación de publicaciones aún no está conectada al esquema independiente.</div>';
    const platformAi = document.getElementById('ia-general');
    if (platformAi) platformAi.innerHTML = '<div class="section-heading"><div><h2>IA general</h2></div></div><div class="empty">La configuración de IA general aún no está conectada al esquema independiente.</div>';
  }

  function renderBusinesses() {
    const target = document.querySelector('#businessesContainer');
    const search = (document.querySelector('#businessSearch')?.value || '').trim().toLocaleLowerCase('es');
    const filtered = cachedBusinesses.filter(b => [b.name, b.slug, b.business_type, b.category].some(v => String(v || '').toLocaleLowerCase('es').includes(search)));
    const count = document.querySelector('#businessCount');
    if (count) count.textContent = `${filtered.length} de ${cachedBusinesses.length} negocios`;
    if (!cachedBusinesses.length) { target.innerHTML = '<div class="empty">Todavía no hay negocios. Usa el formulario de arriba para crear el primero.</div>'; return; }
    if (!filtered.length) { target.innerHTML = '<div class="empty">No hay negocios que coincidan con la búsqueda.</div>'; return; }
    target.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Negocio</th><th>Tipo</th><th>Identificador</th><th>Estado / motivo</th><th>Creado</th><th>Acción</th></tr></thead><tbody>${filtered.map(b => { const active = b.status === 'active'; return `<tr><td><strong>${esc(b.name)}</strong></td><td>${esc(b.business_type || b.category || '—')}</td><td>${esc(b.slug)}</td><td><span class="pill ${active ? 'green':'red'}">${active ? 'Activo':'Suspendido'}</span>${!active ? `<br><small>${esc(b.suspension_reason || 'Motivo pendiente de registrar')}</small>` : ''}</td><td>${dateTime(b.created_at)}</td><td><button class="small-button" data-business-status="${esc(b.id)}" data-active="${active ? 'false':'true'}">${active ? 'Suspender':'Reactivar'}</button></td></tr>`; }).join('')}</tbody></table></div>`;
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
    const reason = isActive ? (window.prompt(`Nota de reactivación para ${business.name}:`, 'Se revisó el caso y se autoriza la reactivación.') || '') : (window.prompt(`Motivo interno de suspensión de ${business.name}:`, '') || '');
    if (!isActive && reason.trim().length < 5) { alert('Escribe un motivo de al menos 5 caracteres. No se realizó ningún cambio.'); return; }
    const publicMessage = isActive ? '' : (window.prompt('Mensaje distinto para los clientes:', 'Esta tienda no está disponible temporalmente.') || 'Esta tienda no está disponible temporalmente.');
    if (!window.confirm(`¿Deseas ${verb} el negocio "${business.name}"?`)) return;
    button.disabled = true;
    try {
      const result = await callTechnicalFunction({ action: 'set_business_status', business_id: id, status: isActive ? 'active' : 'suspended', reason, public_message: publicMessage });
      document.querySelector('#notice').textContent = result.message || `Negocio ${isActive ? 'reactivado' : 'suspendido'}.`;
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
      if (ordersTarget) ordersTarget.innerHTML = '<div class="empty">Selecciona un negocio para consultar sus pedidos.</div>';
      return;
    }
    const business = cachedBusinesses.find(b => b.id === id);
    if (!business) return;
    const { data, error } = await db.from('orders').select('id,order_number,customer_name,customer_phone,delivery_address,payment_status,status,total,created_at,order_items(product_name,quantity)').eq('business_id', id).order('created_at', { ascending: false }).limit(100);
    if (error) showError(ordersTarget, error);
    else renderOrders(ordersTarget, (data || []).map(o => ({ ...o, items: o.order_items || [] })), true);
  }

  async function loadTechnicalMembers(id) {
    const target = document.querySelector('#memberTargetSelect'); if (!target) return;
    target.innerHTML = '<option value="">Cargando cuentas…</option>';
    if (!id) { target.innerHTML = '<option value="">Selecciona primero un negocio</option>'; return; }
    try {
      const result = await callTechnicalFunction({ action: 'list_business_members', business_id: id });
      const rows = result.members || [];
      target.innerHTML = '<option value="">Selecciona una cuenta</option>' + rows.map(m => `<option value="${esc(m.id)}">${esc(m.profiles?.display_name || shortId(m.user_id))} · ${m.role === 'business_admin' ? 'Administrador' : 'Empleado'}${m.status !== 'active' ? ' · Suspendido' : ''}</option>`).join('');
    } catch (error) { target.innerHTML = '<option value="">No se pudieron cargar las cuentas</option>'; }
  }

  async function saveMemberStatus(event) {
    event.preventDefault();
    const form = event.currentTarget, message = document.querySelector('#memberStatusMessage');
    const blocked = form.elements.is_blocked.value === 'true';
    const reason = form.elements.reason.value.trim();
    if (!blocked) {
      message.textContent = 'La función segura del servidor todavía no permite reactivar una membresía suspendida. No se realizó ningún cambio.';
      message.className = 'message error';
      return;
    }
    if (reason.length < 5) {
      message.textContent = 'Para bloquear una cuenta debes escribir un motivo de al menos 5 caracteres.';
      message.className = 'message error';
      return;
    }
    message.textContent = 'Aplicando suspensión y registrando auditoría…';
    try {
      const result = await callTechnicalFunction({ action: 'block_member', membership_id: form.elements.user_id.value, reason });
      message.textContent = result.message || 'Acceso suspendido y registrado en auditoría.';
      message.className = 'message success';
      await loadTechnicalMembers(form.elements.business_id.value);
    } catch (error) {
      message.textContent = error.message || 'No se pudo suspender la membresía.';
      message.className = 'message error';
    }
  }

  async function saveSuspension(event) {
    event.preventDefault();
    const form = event.currentTarget, message = document.querySelector('#suspensionMessage');
    const data = Object.fromEntries(new FormData(form).entries());
    const active = data.is_active === 'true';
    data.action = 'set_business_status';
    data.status = active ? 'active' : 'suspended';
    delete data.is_active;
    if (!active && String(data.reason || '').trim().length < 5) { message.textContent = 'El motivo debe tener al menos 5 caracteres.'; return; }
    message.textContent = 'Guardando estado y auditoría…';
    try { const result = await callTechnicalFunction(data); message.textContent = result.message || 'Estado actualizado.'; message.className = 'message success'; await loadTechnical(); }
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
    const link = document.querySelector('#technicalSupportLink');
    if (!link) return;
    link.href = '#';
    link.classList.add('hidden');
    const message = document.querySelector('#technicalSupportMessage');
    if (message) message.textContent = 'El número de soporte de la plataforma aún no está configurado en el proyecto independiente.';
  }

  async function initBusinessSettings() {
    await showSupportLink();
    const [businessResult, methodsResult] = await Promise.all([
      db.from('businesses').select('name,tagline,description,city,contact_phone,whatsapp_support,logo_url,delivery_fee,minimum_order_amount').eq('id', businessId).single(),
      db.from('business_payment_methods').select('method_code,display_name,is_enabled,sort_order').eq('business_id', businessId).order('sort_order')
    ]);
    const form = document.querySelector('#storeSettingsForm');
    if (businessResult.error) {
      const message = document.querySelector('#storeSettingsMessage');
      if (message) { message.textContent = 'No se pudieron cargar los datos del negocio: ' + businessResult.error.message; message.className = 'message error'; }
    } else if (form) {
      const b = businessResult.data;
      for (const key of ['name','tagline','description','city','contact_phone','whatsapp_support','logo_url','delivery_fee','minimum_order_amount']) {
        if (form.elements[key]) form.elements[key].value = b[key] ?? (['delivery_fee','minimum_order_amount'].includes(key) ? 0 : '');
      }
    }
    const paymentField = form?.elements.payment_methods;
    if (paymentField && !methodsResult.error) paymentField.value = (methodsResult.data || []).filter(m => m.is_enabled).sort((a,b) => a.sort_order-b.sort_order).map(m => m.display_name).join('\n');
    if (methodsResult.error) {
      const message = document.querySelector('#storeSettingsMessage');
      if (message) { message.textContent = 'No se pudieron cargar los métodos de pago: ' + methodsResult.error.message; message.className = 'message error'; }
    }
    const pending = [
      ['contenido-tienda', 'Promociones y formularios de empleo', 'Las tablas de promociones, páginas de contenido y postulaciones todavía no existen en el esquema independiente. Esta sección queda pendiente para evitar guardar datos en una tabla inexistente.'],
      ['ia-negocio', 'IA exclusiva del negocio', 'La configuración de IA por negocio aún no está implementada en la base independiente.'],
      ['solicitudes-bloqueo', 'Solicitudes de bloqueo', 'Las solicitudes de bloqueo desde el panel del negocio todavía no están implementadas en el servidor.']
    ];
    for (const [id, heading, message] of pending) {
      const section = document.getElementById(id);
      if (section) section.innerHTML = `<div class="section-heading"><div><h2>${heading}</h2></div></div><div class="empty">${message}</div>`;
    }
  }

  async function saveStoreSettings(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#storeSettingsMessage');
    const value = name => String(form.elements[name]?.value || '').trim();
    const name = value('name');
    const city = value('city');
    if (!name || !city) {
      message.textContent = 'El nombre del negocio y la ciudad son obligatorios.';
      message.className = 'message error';
      return;
    }
    const toAmount = name => {
      const n = Number(form.elements[name]?.value || 0);
      return Number.isFinite(n) && n >= 0 ? n : null;
    };
    const deliveryFee = toAmount('delivery_fee');
    const minimumOrder = toAmount('minimum_order_amount');
    if (deliveryFee === null || minimumOrder === null) {
      message.textContent = 'El costo de domicilio y el pedido mínimo deben ser valores iguales o mayores que cero.';
      message.className = 'message error';
      return;
    }
    const businessPayload = {
      name,
      tagline: value('tagline') || null,
      description: value('description') || null,
      city,
      contact_phone: value('contact_phone') || null,
      whatsapp_support: value('whatsapp_support').replace(/[^0-9+]/g, '').slice(0, 50) || null,
      logo_url: value('logo_url') || null,
      delivery_fee: deliveryFee,
      minimum_order_amount: minimumOrder,
      updated_at: new Date().toISOString()
    };
    message.textContent = 'Guardando datos del negocio…';
    message.className = 'message';
    const { error: businessError } = await db.from('businesses').update(businessPayload).eq('id', businessId);
    if (businessError) {
      message.textContent = 'No se pudieron guardar los datos del negocio: ' + businessError.message;
      message.className = 'message error';
      return;
    }
    try {
      const labels = [...new Set(value('payment_methods').split('\n').map(v => v.trim()).filter(v => v.length >= 2 && v.length <= 100))];
      const methodCodeFor = label => {
        const normalized = label.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
        if (normalized.includes('efectivo') || normalized.includes('contra entrega')) return 'cash';
        if (normalized.includes('transfer') || normalized.includes('nequi') || normalized.includes('bancolombia') || normalized.includes('daviplata')) return 'transfer';
        if (normalized.includes('tarjeta') || normalized.includes('card')) return 'card';
        return 'other';
      };
      const methods = labels.map((displayName, sortOrder) => ({ displayName, methodCode: methodCodeFor(displayName), sortOrder }));
      const { data: existing, error: readError } = await db.from('business_payment_methods')
        .select('id,method_code,display_name,is_enabled,sort_order')
        .eq('business_id', businessId);
      if (readError) throw readError;
      const byCode = new Map();
      (existing || []).forEach(row => {
        if (!byCode.has(row.method_code)) byCode.set(row.method_code, []);
        byCode.get(row.method_code).push(row);
      });
      const retained = new Set();
      for (const method of methods) {
        const old = byCode.get(method.methodCode)?.shift();
        if (old) {
          const { error } = await db.from('business_payment_methods').update({
            display_name: method.displayName, is_enabled: true, sort_order: method.sortOrder, updated_at: new Date().toISOString()
          }).eq('id', old.id).eq('business_id', businessId);
          if (error) throw error;
          retained.add(old.id);
        } else {
          const { error } = await db.from('business_payment_methods').insert({
            business_id: businessId, method_code: method.methodCode, display_name: method.displayName,
            is_enabled: true, sort_order: method.sortOrder
          });
          if (error) throw error;
        }
      }
      for (const old of (existing || [])) {
        if (!retained.has(old.id) && old.is_enabled) {
          const { error } = await db.from('business_payment_methods').update({ is_enabled: false, updated_at: new Date().toISOString() }).eq('id', old.id).eq('business_id', businessId);
          if (error) throw error;
        }
      }
      message.textContent = 'Datos del negocio y métodos de pago guardados correctamente.';
      message.className = 'message success';
      businessName = name;
      const heading = document.querySelector('#businessName'); if (heading) heading.textContent = name;
    } catch (error) {
      message.textContent = 'Los datos generales se guardaron, pero hubo un problema al actualizar los métodos de pago: ' + (error.message || 'Error desconocido');
      message.className = 'message error';
    }
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
    let query = db.from('audit_logs').select('id,business_id,actor_id,action,details,created_at').eq('action', 'panel.login').order('created_at', { ascending: false }).limit(100);
    if (id) query = query.eq('business_id', id);
    const { data, error } = await query;
    if (error) return showError(target, error);
    const rows = data || [];
    const names = await getUserNames(rows.map(e => e.actor_id));
    if (!rows.length) { target.innerHTML = '<div class="empty">No hay registros de acceso para este filtro todavía.</div>'; return; }
    target.innerHTML = tableHtml(['Fecha y hora','Usuario','Panel','Evento'], rows.map(e => [dateTime(e.created_at), names.get(e.actor_id) || shortId(e.actor_id), esc(e.details?.panel || '—'), 'Inicio de sesión']));
  }

  async function loadAuditEvents(id, selector) {
    const target = document.querySelector(selector);
    let query = db.from('audit_logs').select('id,business_id,actor_id,action,entity_type,entity_id,details,created_at').order('created_at', { ascending: false }).limit(100);
    if (id) query = query.eq('business_id', id);
    else if (panel !== 'technical') query = query.eq('actor_id', currentUser.id);
    const { data, error } = await query;
    if (error) return showError(target, error);
    const rows = data || [];
    const names = await getUserNames(rows.map(e => e.actor_id));
    if (!rows.length) { target.innerHTML = '<div class="empty">No hay registros de auditoría para este filtro todavía.</div>'; return; }
    target.innerHTML = tableHtml(['Fecha y hora','Usuario','Acción','Entidad','Registro','Detalle'], rows.map(e => [dateTime(e.created_at), names.get(e.actor_id) || shortId(e.actor_id), esc(e.action), esc(e.entity_type), e.entity_id || '—', esc(JSON.stringify(e.details || {}))]));
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
