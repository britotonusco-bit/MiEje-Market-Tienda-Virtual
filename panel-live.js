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
      const emailNode = document.querySelector('#userEmail');
      if (emailNode) emailNode.textContent = currentUser.email || '';
      const panelNode = document.querySelector('#profilePanel');
      if (panelNode) panelNode.textContent = panel === 'technical' ? 'Panel técnico superior' : (panel === 'business_admin' ? 'Panel de administrador' : 'Panel de empleados');
      const roleNode = document.querySelector('#profileRole');
      if (roleNode) roleNode.textContent = panel === 'technical' ? 'Propietario de la plataforma' : (panel === 'business_admin' ? 'Administrador del negocio' : 'Empleado del negocio');
      const statusNode = document.querySelector('#profileStatus');
      if (statusNode) statusNode.textContent = profile.account_status === 'active' ? 'Cuenta activa' : 'Cuenta suspendida';
      const titleNode = document.querySelector('#profileBusinessTitle');
      if (titleNode) titleNode.textContent = panel === 'technical' ? 'Control general de MiEje Market' : '';
      const avatarNode = document.querySelector('#profileAvatar');
      if (avatarNode && profile.avatar_url) {
        avatarNode.textContent = '';
        avatarNode.style.backgroundImage = 'url("' + String(profile.avatar_url).replace(/["\\\\]/g, '') + '")';
        avatarNode.style.backgroundSize = 'cover';
        avatarNode.style.backgroundPosition = 'center';
      }
      document.querySelector('#logoutBtn').addEventListener('click', signOut);
      document.querySelector('#refreshTechnicalBtn')?.addEventListener('click', refreshTechnical);
      document.querySelector('#createBusinessForm')?.addEventListener('submit', createBusiness);
      document.querySelector('#inviteMemberForm')?.addEventListener('submit', inviteBusinessMember);
      document.querySelector('#businessSearch')?.addEventListener('input', renderBusinesses);
      document.querySelector('#businessSelect')?.addEventListener('change', event => loadSelectedBusiness(event.currentTarget.value));
      document.querySelector('#suspensionForm')?.addEventListener('submit', saveSuspension);
      document.querySelector('#memberStatusForm')?.addEventListener('submit', saveMemberStatus);
      document.querySelector('#assignmentBusinessSelect')?.addEventListener('change', event => loadTechnicalMembers(event.currentTarget.value, '#assignmentMemberSelect'));
      document.querySelector('#assignmentMemberSelect')?.addEventListener('change', fillMemberAssignment);
      document.querySelector('#memberAssignmentForm')?.addEventListener('submit', saveMemberAssignment);
      document.querySelector('#memberBusinessSelect')?.addEventListener('change', event => loadTechnicalMembers(event.currentTarget.value, '#memberTargetSelect'));
      document.querySelector('#platformAiForm')?.addEventListener('submit', savePlatformAi);
      document.querySelector('#platformFinanceForm')?.addEventListener('submit', createPlatformFinancialRecord);
      document.querySelector('#payrollForm')?.addEventListener('submit', createPayrollRecord);
      document.querySelector('#storeSettingsForm')?.addEventListener('submit', saveStoreSettings);
      document.querySelector('#productForm')?.addEventListener('submit', saveProduct);
      document.querySelector('#profitReportForm')?.addEventListener('submit', loadProfitReport);
      document.querySelector('#businessContentForm')?.addEventListener('submit', saveBusinessContent);
      document.querySelector('#businessAiForm')?.addEventListener('submit', saveBusinessAi);
      document.querySelector('#blockRequestForm')?.addEventListener('submit', submitBlockRequest);
      document.querySelector('#refreshOrders')?.addEventListener('click', () => panel === 'business_admin' ? loadBusinessOrders() : loadEmployeeOrders());
      document.querySelector('#refreshCancellations')?.addEventListener('click', loadCancellationRequests);
      document.querySelector('#refreshRefunds')?.addEventListener('click', loadRefundableOrders);

      if (panel === 'technical') {
        if (!access.is_platform_owner || profile.platform_role !== 'platform_owner') throw new Error('Esta sección es exclusiva del propietario técnico autorizado.');
        const { data: assurance, error: assuranceError } = await db.auth.mfa.getAuthenticatorAssuranceLevel();
        if (assuranceError || assurance?.currentLevel !== 'aal2') {
          await db.auth.signOut();
          window.location.replace('login.html');
          return;
        }
        await logPanel(null, 'technical', 'panel_open');
         await showSupportLink();
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
        if (roleNode) roleNode.textContent = match.role_label || (match.role === 'business_admin' ? 'Administrador del negocio' : 'Empleado del negocio');
        if (titleNode) titleNode.textContent = match.job_title || '';

        document.querySelector('#businessName').textContent = businessName;
        await logPanel(businessId, panel, 'panel_open');
        notice.textContent = `Acceso validado para ${businessName}. Los permisos se aplican en la base de datos.`;
        notice.className = 'notice';
        if (panel === 'business_admin') { await loadBusinessAdmin(); await initBusinessSettings(); await initBusinessAi(); await loadBlockTargetUsers(); }
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
      db.rpc('get_business_admin_order_financials', {
        p_business_id: businessId,
        p_refundable_only: false,
        p_limit: 10000
      }),
      db.from('products').select('id,inventory,is_active').eq('business_id', businessId)
    ]);
    if (ordersResult.error) throw ordersResult.error;
    if (productsResult.error) throw productsResult.error;
    const orders = ordersResult.data || [], products = productsResult.data || [];
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bogota' });
    const todayOrders = orders.filter(o => new Date(o.created_at).toLocaleDateString('en-CA', { timeZone: 'America/Bogota' }) === today && o.status !== 'cancelled');
    const todayPaidSales = todayOrders.filter(o => o.payment_status === 'paid')
      .reduce((sum, o) => sum + Number(o.total || 0), 0);
    const received = orders.filter(o => o.payment_status === 'paid')
      .reduce((sum, o) => sum + Number(o.total || 0), 0);
    renderStats([
      ['Pedidos de hoy', number(todayOrders.length), 'Pedidos creados hoy, sin cancelados'],
      ['Pedidos de hoy con pago confirmado', money(todayPaidSales), 'Importe de pedidos creados hoy cuyo pago figura confirmado'],
      ['Total de pedidos con pago confirmado', money(received), 'Suma de pedidos cuyo estado de pago figura como confirmado'],
      ['Pedidos abiertos', number(orders.filter(o => !['delivered','cancelled'].includes(o.status)).length), 'Pendientes de completar'],
      ['Productos con poco stock', number(products.filter(p => p.is_active && Number(p.inventory || 0) <= 5).length), 'Cinco unidades o menos']
    ]);
    await Promise.all([loadBusinessOrders(), loadCancellationRequests(), loadRefundableOrders(), loadProducts(), loadAccessEvents(businessId, '#accessContainer'), loadAuditEvents(businessId, '#auditContainer')]);
    initializeProfitReport();
  }


  function initializeProfitReport() {
    const form = document.querySelector('#profitReportForm');
    if (!form) return;
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bogota' });
    form.elements.start_date.value = today.slice(0,8) + '01';
    form.elements.end_date.value = today;
    loadProfitReport();
  }

  async function loadProfitReport(event) {
    if (event) event.preventDefault();
    const form = document.querySelector('#profitReportForm');
    const target = document.querySelector('#profitReportContainer');
    if (!form || !target) return;
    const startDate=form.elements.start_date.value, endDate=form.elements.end_date.value;
    if (!startDate || !endDate || endDate < startDate) {
      target.innerHTML='<div class="empty">Revisa las fechas: la fecha final no puede ser anterior a la inicial.</div>';
      return;
    }
    target.innerHTML='<div class="empty">Calculando resultados del periodo…</div>';
    const {data,error}=await db.rpc('get_business_admin_profit_report',{
      p_business_id:businessId,p_start_date:startDate,p_end_date:endDate
    });
    if(error || !data) {
      target.innerHTML='<div class="empty">El reporte financiero todavía no está disponible. Comprueba que la migración esté instalada en ensayo. '+esc(error?.message || '')+'</div>';
      return;
    }
    const rows=[
      ['Ventas con pago confirmado',money(data.sales)],
      ['Reembolsos confirmados',money(data.refunds)],
      ['Ventas netas',money(data.net_sales)],
      ['Costo de productos vendidos',money(data.cost_of_sales)],
      ['Ganancia bruta estimada',money(data.gross_profit_estimate)],
      ['Gastos operativos pagados',money(data.paid_expenses)],
      ['Resultado neto estimado',money(data.net_profit_estimate)],
      ['Pedidos con pago confirmado',number(data.paid_orders)],
      ['Líneas sin costo histórico',number(data.missing_cost_lines)]
    ];
    target.innerHTML='<div class="stats">'+rows.map(([label,value])=>
      '<article class="stat"><span>'+esc(label)+'</span><strong>'+esc(value)+'</strong></article>'
    ).join('')+'</div>'+(data.complete_cost_data
      ? '<p class="message success">Todos los productos vendidos en este periodo tienen costo histórico registrado.</p>'
      : '<p class="message error">Hay productos vendidos sin costo histórico. El resultado no representa la ganancia real completa.</p>'
    )+'<p class="muted">Periodo: '+esc(data.start_date)+' a '+esc(data.end_date)+'. '+esc(data.basis)+'</p>';
  }

  async function uploadBusinessImage(file, folder) {
    if (!file) return null;
    const allowedTypes = new Set(['image/png', 'image/jpeg', 'image/webp']);
    if (!allowedTypes.has(file.type)) throw new Error('El archivo debe ser PNG, JPG o WEBP.');
    if (file.size > 5 * 1024 * 1024) throw new Error('La imagen no puede superar los 5 MB.');
    const extension = file.type === 'image/jpeg' ? 'jpg' : file.type.split('/')[1];
    const path = `${businessId}/${folder}/${crypto.randomUUID()}.${extension}`;
    const { data, error } = await db.storage.from('business-assets').upload(path, file, {
      cacheControl: '3600',
      upsert: false,
      contentType: file.type
    });
    if (error) {
      if (/bucket.*not found|not found.*bucket/i.test(error.message || '')) {
        throw new Error('Falta crear el bucket público "business-assets" en Storage de Supabase. La imagen no se ha guardado.');
      }
      throw new Error('No se pudo subir la imagen: ' + error.message);
    }
    const { data: publicData } = db.storage.from('business-assets').getPublicUrl(data.path);
    return { path: data.path, publicUrl: publicData.publicUrl };
  }

  async function removeUploadedBusinessImage(path) {
    if (!path) return;
    const { error } = await db.storage.from('business-assets').remove([path]);
    if (error) console.warn('No se pudo retirar una imagen que quedó sin asociar:', error.message);
  }

  async function saveProduct(event) {
    event.preventDefault();
    const form = event.currentTarget, message = document.querySelector('#productMessage');
    const name = form.elements.name.value.trim();
    const price = Number(form.elements.price.value);
    const inventory = Number(form.elements.inventory.value);
    const costRaw = form.elements.cost_price.value.trim();
    const costPrice = costRaw === '' ? null : Number(costRaw);
    if (!name || !Number.isFinite(price) || price < 0 || !Number.isInteger(inventory) || inventory < 0
      || (costPrice !== null && (!Number.isFinite(costPrice) || costPrice < 0))) {
      message.textContent = 'Revisa nombre, precio, costo y existencias. Los valores monetarios no pueden ser negativos y las existencias deben ser un número entero.';
      message.className = 'message error';
      return;
    }
    const imageFile = form.elements.image_file.files?.[0] || null;
    const externalImageUrl = form.elements.image_url.value.trim();
    if (externalImageUrl && !/^https?:\/\//i.test(externalImageUrl)) {
      message.textContent = 'La dirección de la imagen debe comenzar por https:// o http://.';
      message.className = 'message error';
      return;
    }
    const id = form.elements.id.value;
    const button = form.querySelector('button[type="submit"]');
    let uploadedImage = null;
    button.disabled = true;
    message.textContent = imageFile ? 'Subiendo imagen y guardando producto…' : 'Guardando producto…';
    message.className = 'message';
    try {
      if (imageFile) uploadedImage = await uploadBusinessImage(imageFile, 'products');
      const payload = {
        name,
        category: form.elements.category.value.trim() || null,
        description: form.elements.description.value.trim() || null,
        price,
        inventory,
        image_url: uploadedImage?.publicUrl || externalImageUrl || null,
        is_active: form.elements.is_active.checked,
        updated_at: new Date().toISOString()
      };
      const result = id
        ? await db.from('products').update(payload).eq('id', id).eq('business_id', businessId).select('id').maybeSingle()
        : await db.from('products').insert({ ...payload, business_id: businessId }).select('id').single();
      if (result.error || !result.data) {
        await removeUploadedBusinessImage(uploadedImage?.path);
        throw new Error(result.error?.message || 'No se guardó ningún producto. Comprueba que tienes permisos sobre este negocio.');
      }
      if (costPrice !== null) {
        const costResult = await db.from('product_costs').upsert({
          product_id: result.data.id,
          business_id: businessId,
          cost_price: costPrice,
          updated_at: new Date().toISOString()
        }, { onConflict: 'product_id' });
        if (costResult.error) {
          message.textContent = 'El producto se guardó, pero no se pudo guardar su costo: ' + costResult.error.message;
          message.className = 'message error';
          await loadProducts();
          return;
        }
      }
      form.reset();
      form.elements.id.value = '';
      message.textContent = costPrice === null
        ? (id ? 'Producto actualizado. El costo sigue pendiente de registrar.' : 'Producto creado. Registra su costo para calcular el margen.')
        : (id ? 'Producto y costo actualizados.' : 'Producto y costo guardados.');
      message.className = 'message success';
      await loadProducts();
    } catch (error) {
      message.textContent = 'No se pudo guardar el producto: ' + (error.message || 'Error desconocido');
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
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
    form.elements.cost_price.value = product.cost_price ?? '';
    form.elements.inventory.value = product.inventory ?? 0;
    form.elements.image_url.value = product.image_url || '';
    if (form.elements.image_file) form.elements.image_file.value = '';
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
    const { data: updated, error } = await db.from('products').update({ is_active: !product.is_active, updated_at: new Date().toISOString() }).eq('id', id).eq('business_id', businessId).select('id').maybeSingle();
    if (error || !updated) {
      alert('No se pudo cambiar el estado del producto: ' + (error?.message || 'No se encontró el producto o no tienes permiso.'));
      button.disabled = false;
      return;
    }
    await loadProducts();
  }

  async function loadBusinessOrders() {
    const target = document.querySelector('#ordersContainer');
    target.innerHTML = '<div class="empty">Cargando pedidos…</div>';
    const [ordersResult, financeResult] = await Promise.all([
      db.from('orders').select('id,order_number,customer_name,customer_phone,delivery_address,delivery_notes,delivery_tracking,status,created_at,order_items(product_name,quantity)').eq('business_id', businessId).order('created_at', { ascending: false }).limit(100),
      db.rpc('get_business_admin_order_financials', {
        p_business_id: businessId,
        p_refundable_only: false,
        p_limit: 100
      })
    ]);
    if (ordersResult.error) return showError(target, ordersResult.error);
    if (financeResult.error) return showError(target, financeResult.error);
    const financeByOrder = new Map((financeResult.data || []).map(row => [row.order_id, row]));
    renderOrders(target, (ordersResult.data || []).map(o => ({
      ...o,
      ...(financeByOrder.get(o.id) || {}),
      id: o.id,
      items: o.order_items || []
    })), true);
  }

  async function loadEmployeeOrders() {
    const target = document.querySelector('#ordersContainer');
    target.innerHTML = '<div class="empty">Cargando pedidos…</div>';
    const { data, error } = await db.from('orders').select('id,order_number,customer_name,customer_phone,delivery_address,delivery_notes,delivery_tracking,status,created_at,order_items(product_name,quantity)').eq('business_id', businessId).order('created_at', { ascending: false }).limit(100);
    if (error) return showError(target, error);
    renderOrders(target, (data || []).map(o => ({ ...o, items: o.order_items || [] })), false);
  }

  async function loadProducts() {
    const target = document.querySelector('#productsContainer');
    const [productsResult, costsResult] = await Promise.all([
      db.from('products').select('id,name,category,description,price,inventory,image_url,is_active').eq('business_id', businessId).order('name').limit(250),
      db.from('product_costs').select('product_id,cost_price').eq('business_id', businessId)
    ]);
    if (productsResult.error) return showError(target, productsResult.error);
    if (costsResult.error) return showError(target, costsResult.error);
    const costsByProduct = new Map((costsResult.data || []).map(row => [row.product_id, Number(row.cost_price)]));
    cachedProducts = (productsResult.data || []).map(product => ({
      ...product,
      cost_price: costsByProduct.has(product.id) ? costsByProduct.get(product.id) : null
    }));
    if (!cachedProducts.length) { target.innerHTML = '<div class="empty">Este negocio todavía no tiene productos registrados. Puedes crear el primero en el formulario.</div>'; return; }
    target.innerHTML = '<div class="table-wrap"><table><thead><tr><th>Producto</th><th>Categoría</th><th>Precio</th><th>Costo unitario</th><th>Margen bruto unitario</th><th>Existencias</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>' +
      cachedProducts.map(p => {
        const hasCost = p.cost_price !== null && Number.isFinite(p.cost_price);
        const margin = hasCost ? Number(p.price) - p.cost_price : null;
        return '<tr><td><strong>' + esc(p.name) + '</strong>' +
          (p.image_url && /^https?:\/\//i.test(p.image_url) ? '<br><a href="' + esc(p.image_url) + '" target="_blank" rel="noopener"><img src="' + esc(p.image_url) + '" alt="Imagen de ' + esc(p.name) + '" loading="lazy" style="width:54px;height:54px;object-fit:cover;border-radius:10px;vertical-align:middle"> Ver imagen</a>' : '') +
          '<br><small>' + esc(p.description || '') + '</small></td><td>' + esc(p.category || '—') + '</td><td>' + money(p.price) +
          '</td><td>' + (hasCost ? money(p.cost_price) : '<span class="pill red">Sin registrar</span>') +
          '</td><td>' + (hasCost ? money(margin) : 'Pendiente de costo') +
          '</td><td>' + number(p.inventory) + '</td><td><span class="pill ' + (p.is_active ? 'green':'red') + '">' +
          (p.is_active ? 'Activo':'Inactivo') + '</span></td><td><button class="small-button" data-edit-product="' + esc(p.id) +
          '">Editar</button> <button class="small-button" data-toggle-product="' + esc(p.id) + '">' +
          (p.is_active ? 'Desactivar':'Activar') + '</button></td></tr>';
      }).join('') + '</tbody></table></div>';
    target.querySelectorAll('[data-edit-product]').forEach(button => button.addEventListener('click', () => editProduct(button.dataset.editProduct)));
    target.querySelectorAll('[data-toggle-product]').forEach(button => button.addEventListener('click', () => toggleProductStatus(button.dataset.toggleProduct, button)));
  }

  async function loadTechnical() {
    const result = await callTechnicalFunction({ action: 'list_businesses' });
    cachedBusinesses = result.businesses || [];
    const auditResult = await db.from('audit_logs').select('id', { count: 'exact', head: true });
    if (auditResult.error) throw auditResult.error;
    renderStats([
      ['Negocios registrados', number(cachedBusinesses.length), 'Administración de la plataforma'],
      ['Negocios activos', number(cachedBusinesses.filter(b => b.status === 'active').length), 'Con acceso habilitado'],
      ['Negocios suspendidos', number(cachedBusinesses.filter(b => b.status === 'suspended').length), 'Requieren revisión o reactivación'],
      ['Eventos de auditoría', number(auditResult.count || 0), 'Registros de actividad']
    ]);
    const options = `<option value="">Todos los negocios</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}${b.status === 'active' ? '' : ' (inactivo)'}</option>`).join('');
    const select = document.querySelector('#businessSelect'); if (select) select.innerHTML = options;
    const memberSelect = document.querySelector('#memberBusinessSelect'); if (memberSelect) memberSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    const assignmentBusinessSelect = document.querySelector('#assignmentBusinessSelect'); if (assignmentBusinessSelect) assignmentBusinessSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    const suspensionSelect = document.querySelector('#suspensionBusinessSelect'); if (suspensionSelect) suspensionSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}${b.status === 'active' ? '' : ' (suspendido)'}</option>`).join('');
    const inviteSelect = document.querySelector('#inviteBusinessSelect'); if (inviteSelect) inviteSelect.innerHTML = `<option value="">Selecciona un negocio</option>` + cachedBusinesses.filter(b => b.status === 'active').map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
    renderBusinesses();
    await loadSelectedBusiness('');
    await loadAuditEvents(null, '#auditContainer');
    await loadFinance();
    await loadBlockRequests();
    await loadContentModeration();
    await initPlatformAi();
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
      const result = await callTechnicalFunction({
        action: 'create_business',
        name: String(payload.name || '').trim(),
        category: String(payload.category || '').trim()
      });
      message.className = result.audit_warning ? 'message error' : 'message success';
      message.textContent = result.audit_warning
        ? `Negocio creado: ${result.business.name} (${result.business.slug}), pero falta registrar la auditoría. ${result.audit_warning}`
        : `Negocio creado: ${result.business.name}. Identificador público: ${result.business.slug}. Ahora puedes invitar a su administrador y empleados.`;
      form.reset();
      await loadTechnical();
      const inviteSelect = document.querySelector('#inviteBusinessSelect');
      if (inviteSelect) inviteSelect.value = result.business.id;
      const filterSelect = document.querySelector('#businessSelect');
      if (filterSelect) filterSelect.value = result.business.id;
      await loadSelectedBusiness(result.business.id);
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
    button.disabled = true;
    message.className = 'message';
    message.textContent = 'Creando invitación y registrando la asignación…';
    try {
      const result = await callTechnicalFunction(payload);
      message.className = result.audit_warning ? 'message error' : 'message success';
      const assignedRole = result.membership?.role === 'business_admin' ? 'administrador' : 'empleado';
      message.textContent = result.message || (result.invitation_sent
        ? `Invitación enviada para el nuevo usuario como ${assignedRole}.`
        : `Usuario existente asignado como ${assignedRole} al negocio.`);
      if (result.audit_warning) message.textContent += ` Advertencia: ${result.audit_warning}`;
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
    if (!ordersTarget) return;
    const business = cachedBusinesses.find(b => b.id === id);
    ordersTarget.innerHTML = business
      ? '<div class="empty">El panel técnico administra el negocio y sus accesos. Los pedidos, clientes, productos y movimientos comerciales solo se consultan desde el panel de ese negocio.</div>'
      : '<div class="empty">Selecciona un negocio para administrar sus usuarios y accesos. La información comercial permanece en su panel administrativo.</div>';
  }

  async function loadTechnicalMembers(id, targetSelector = '#memberTargetSelect') {
    const target = document.querySelector(targetSelector); if (!target) return;
    target.innerHTML = '<option value="">Cargando cuentas…</option>';
    if (!id) { target.innerHTML = '<option value="">Selecciona primero un negocio</option>'; return; }
    try {
      const result = await callTechnicalFunction({ action: 'list_business_members', business_id: id });
      const rows = result.members || [];
      target.innerHTML = '<option value="">Selecciona una cuenta</option>' + rows.map(m => `<option value="${esc(m.id)}" data-role="${esc(m.role)}" data-job-title="${esc(m.job_title || '')}">${esc(m.profiles?.display_name || shortId(m.user_id))} · ${esc(m.email || 'sin correo')} · ${m.role === 'business_admin' ? 'Administrador' : 'Empleado'} · ${esc(m.job_title || 'Cargo no registrado')}${m.status !== 'active' ? ' · Suspendido' : ''}</option>`).join('');
    } catch (error) { target.innerHTML = '<option value="">No se pudieron cargar las cuentas</option>'; }
  }

  function fillMemberAssignment() {
    const form = document.querySelector('#memberAssignmentForm');
    const selected = form?.elements.membership_id?.selectedOptions?.[0];
    if (!form || !selected) return;
    form.elements.role.value = selected.dataset.role || 'employee';
    form.elements.job_title.value = selected.dataset.jobTitle || '';
  }

  async function saveMemberAssignment(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#memberAssignmentMessage');
    const payload = {
      action: 'update_member_assignment',
      membership_id: form.elements.membership_id.value,
      role: form.elements.role.value,
      job_title: form.elements.job_title.value.trim()
    };
    if (!payload.membership_id || payload.job_title.length < 2) {
      message.textContent = 'Selecciona una cuenta y escribe el cargo.';
      message.className = 'message error';
      return;
    }
    try {
      const result = await callTechnicalFunction(payload);
      message.textContent = result.message || 'Asignación actualizada.';
      if (result.audit_warning) message.textContent += ` Advertencia: ${result.audit_warning}`;
      message.className = result.audit_warning ? 'message error' : 'message success';
      await loadTechnicalMembers(form.elements.business_id.value, '#assignmentMemberSelect');
    } catch (error) {
      message.textContent = error.message || 'No se pudo actualizar la asignación.';
      message.className = 'message error';
    }
  }

  async function saveMemberStatus(event) {
    event.preventDefault();
    const form = event.currentTarget, message = document.querySelector('#memberStatusMessage');
    const suspended = form.elements.is_blocked.value === 'true';
    const reason = form.elements.reason.value.trim();
    if (reason.length < 5) {
      message.textContent = 'Escribe un motivo de al menos 5 caracteres para dejar constancia en auditoría.';
      message.className = 'message error';
      return;
    }
    message.textContent = suspended ? 'Suspendiendo acceso y registrando auditoría…' : 'Reactivando acceso y registrando auditoría…';
    try {
      const result = await callTechnicalFunction({
        action: suspended ? 'block_member' : 'unblock_member',
        membership_id: form.elements.user_id.value,
        reason
      });
      message.textContent = result.message || (suspended ? 'Acceso suspendido.' : 'Acceso reactivado.');
      if (result.audit_warning) message.textContent += ` Advertencia: ${result.audit_warning}`;
      message.className = result.audit_warning ? 'message error' : 'message success';
      await loadTechnicalMembers(form.elements.business_id.value);
    } catch (error) {
      message.textContent = error.message || 'No se pudo cambiar el acceso.';
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
    const form = document.querySelector('#platformAiForm');
    if (!form) return;
    const message = document.querySelector('#platformAiMessage');
    let aiSettings = {};
    let publicSettings = {};
    try {
      const [aiResult, publicResult] = await Promise.all([
        callTechnicalFunction({ action: 'get_platform_ai_settings' }),
        callTechnicalFunction({ action: 'get_platform_public_settings' })
      ]);
      aiSettings = aiResult?.settings || {};
      publicSettings = publicResult?.settings || {};
    } catch (error) {
      if (message) {
        message.textContent = 'No se pudo cargar toda la configuración general. Comprueba que las migraciones y la función técnica estén actualizadas: ' + (error.message || 'Error de consulta.');
        message.className = 'message error';
      }
    }
    form.elements.site_name.value = publicSettings.site_name || 'MiEje Market';
    form.elements.site_description.value = publicSettings.site_description || '';
    form.elements.logo_url.value = publicSettings.logo_url || '';
    form.elements.hero_image_url.value = publicSettings.hero_image_url || '';
    form.elements.support_whatsapp.value = publicSettings.support_whatsapp || '';
    form.elements.assistant_name.value = aiSettings.assistant_name || 'Asistente general de MiEje Market';
    form.elements.system_instructions.value = aiSettings.system_instructions || '';
    form.elements.enabled.checked = Boolean(aiSettings.enabled);
  }

  async function savePlatformAi(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#platformAiMessage');
    const support = form.elements.support_whatsapp.value.replace(/[^0-9]/g, '').slice(0, 18);
    let aiSaved = false;
    try {
      const aiResult = await callTechnicalFunction({
        action: 'update_platform_ai_settings',
        enabled: form.elements.enabled.checked,
        assistant_name: form.elements.assistant_name.value.trim(),
        system_instructions: form.elements.system_instructions.value.trim()
      });
      aiSaved = true;
      const publicResult = await callTechnicalFunction({
        action: 'update_platform_public_settings',
        site_name: form.elements.site_name.value.trim(),
        site_description: form.elements.site_description.value.trim(),
        logo_url: form.elements.logo_url.value.trim(),
        hero_image_url: form.elements.hero_image_url.value.trim(),
        support_whatsapp: support
      });
      message.textContent = [
        publicResult.message || 'Configuración general guardada.',
        aiResult.audit_warning,
        publicResult.audit_warning
      ].filter(Boolean).join(' ');
      message.className = aiResult.audit_warning || publicResult.audit_warning ? 'message error' : 'message success';
    } catch (error) {
      message.textContent = aiSaved
        ? 'La configuración del asistente se guardó, pero no se completó la configuración pública: ' + (error.message || 'Error desconocido.')
        : (error.message || 'No se pudo guardar la configuración general.');
      message.className = 'message error';
    }
  }

  async function showSupportLink() {
    const link = document.querySelector('#technicalSupportLink');
    if (!link) return;
    const message = document.querySelector('#technicalSupportMessage');
    link.href = '#';
    link.classList.add('hidden');
    try {
      const { data, error } = await db.functions.invoke('get-platform-public-settings', { body: {} });
      if (error || !data?.ok) throw new Error(data?.error || error?.message || 'No se pudo consultar el contacto técnico.');
      const number = String(data.settings?.support_whatsapp || '').replace(/[^0-9]/g, '');
      if (!number) throw new Error('El WhatsApp del técnico todavía no está configurado.');
      link.href = 'https://wa.me/' + number;
      link.classList.remove('hidden');
      if (message) message.textContent = 'Soporte técnico oficial de MiEje Market.';
    } catch (error) {
      if (message) message.textContent = error.message || 'No se pudo cargar el contacto técnico.';
    }
  }

  async function initBusinessSettings() {
    await showSupportLink();
    const [businessResult, methodsResult] = await Promise.all([
      db.from('businesses').select('name,category,tagline,description,city,contact_phone,whatsapp_support,logo_url,delivery_fee,minimum_order_amount,opening_hours').eq('id', businessId).single(),
      db.from('business_payment_methods').select('method_code,display_name,public_instructions,is_enabled,sort_order').eq('business_id', businessId).order('sort_order')
    ]);
    const form = document.querySelector('#storeSettingsForm');
    if (businessResult.error) {
      const message = document.querySelector('#storeSettingsMessage');
      if (message) { message.textContent = 'No se pudieron cargar los datos del negocio: ' + businessResult.error.message; message.className = 'message error'; }
    } else if (form) {
      const b = businessResult.data;
      const schedule = b.opening_hours && typeof b.opening_hours === 'object' ? b.opening_hours : {};
      for (const day of ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']) {
        const entry = schedule[day] || {};
        if (form.elements['hours_'+day+'_open_day']) form.elements['hours_'+day+'_open_day'].checked = entry.closed === false || Boolean(entry.open && entry.close);
        if (form.elements['hours_'+day+'_open']) form.elements['hours_'+day+'_open'].value = entry.open || '08:00';
        if (form.elements['hours_'+day+'_close']) form.elements['hours_'+day+'_close'].value = entry.close || '18:00';
      }
      for (const key of ['name','category','tagline','description','city','contact_phone','whatsapp_support','logo_url','delivery_fee','minimum_order_amount']) {
        if (form.elements[key]) form.elements[key].value = b[key] ?? (['delivery_fee','minimum_order_amount'].includes(key) ? 0 : '');
      }
    }
    const paymentField = form?.elements.payment_methods;
    if (paymentField && !methodsResult.error) paymentField.value = (methodsResult.data || []).filter(m => m.is_enabled).sort((a,b) => a.sort_order-b.sort_order).map(m => m.public_instructions ? (m.display_name + ' | ' + m.public_instructions) : m.display_name).join('\n');
    if (methodsResult.error) {
      const message = document.querySelector('#storeSettingsMessage');
      if (message) { message.textContent = 'No se pudieron cargar los métodos de pago: ' + methodsResult.error.message; message.className = 'message error'; }
    }
    await Promise.all([loadBusinessContent(), loadJobApplications()]);
  }

  async function saveStoreSettings(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#storeSettingsMessage');
    const value = name => String(form.elements[name]?.value || '').trim();
    const name = value('name');
    const city = value('city');
    const category = value('category');
    const paymentEntries = value('payment_methods').split('\n').map(line => {
      const parts = line.split('|');
      return { displayName: (parts.shift() || '').trim(), publicInstructions: parts.join('|').trim() };
    }).filter(item => item.displayName.length >= 2 && item.displayName.length <= 100);
    if (!paymentEntries.length) {
      message.textContent = 'Configura al menos un método de pago para que los clientes puedan completar sus pedidos.';
      message.className = 'message error';
      return;
    }
    if (!name || !city || !category) {
      message.textContent = 'El nombre, la categoría y la ciudad son obligatorios.';
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
    const logoFile = form.elements.logo_file.files?.[0] || null;
    const externalLogoUrl = value('logo_url');
    if (externalLogoUrl && !/^https?:\/\//i.test(externalLogoUrl)) {
      message.textContent = 'La dirección del logo debe comenzar por https:// o http://.';
      message.className = 'message error';
      return;
    }
    const button = form.querySelector('button[type="submit"]');
    let uploadedLogo = null;
    button.disabled = true;
    message.textContent = logoFile ? 'Subiendo logo y guardando configuración…' : 'Guardando datos del negocio…';
    message.className = 'message';
    try {
      const openingHours = {};
      const weekdays = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
      for (const day of weekdays) {
        const enabled = Boolean(form.elements['hours_'+day+'_open_day'] && form.elements['hours_'+day+'_open_day'].checked);
        const open = String(form.elements['hours_'+day+'_open'] ? form.elements['hours_'+day+'_open'].value : '');
        const close = String(form.elements['hours_'+day+'_close'] ? form.elements['hours_'+day+'_close'].value : '');
        if (enabled && (!/^([01]\d|2[0-3]):[0-5]\d$/.test(open) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(close) || close <= open)) {
          message.textContent = 'Revisa los horarios: el cierre debe ser posterior a la apertura en cada día activo.';
          message.className = 'message error';
          return;
        }
        openingHours[day] = enabled ? { open: open, close: close, closed: false } : { closed: true };
      }
      // Subir el archivo solo después de validar todos los horarios para no
      // dejar objetos huérfanos cuando el formulario tenga datos inválidos.
      if (logoFile) uploadedLogo = await uploadBusinessImage(logoFile, 'logo');
      const businessPayload = {
        name,
        category,
        tagline: value('tagline') || null,
        description: value('description') || null,
        city,
        contact_phone: value('contact_phone') || null,
        whatsapp_support: value('whatsapp_support').replace(/[^0-9+]/g, '').slice(0, 50) || null,
        logo_url: uploadedLogo?.publicUrl || externalLogoUrl || null,
        opening_hours: openingHours,
        delivery_fee: deliveryFee,
        minimum_order_amount: minimumOrder,
      };
      const { data: updatedBusiness, error: businessError } = await db.from('businesses')
        .update(businessPayload).eq('id', businessId).select('id').maybeSingle();
      if (businessError || !updatedBusiness) {
        await removeUploadedBusinessImage(uploadedLogo?.path);
        throw new Error('No se pudieron guardar los datos del negocio: ' + (businessError?.message || 'No se encontró el negocio o no tienes permiso para modificarlo.'));
      }
      try {
        const entries = paymentEntries;
        const methodCodeFor = label => {
          const normalized = label.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
          if (normalized.includes('efectivo') || normalized.includes('contra entrega')) return 'cash';
          if (normalized.includes('transfer') || normalized.includes('nequi') || normalized.includes('bancolombia') || normalized.includes('daviplata')) return 'transfer';
          if (normalized.includes('tarjeta') || normalized.includes('card')) return 'card';
          return 'other';
        };
        const methods = entries.map((item, sortOrder) => ({ ...item, methodCode: methodCodeFor(item.displayName), sortOrder }));
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
            const { data: updatedMethod, error } = await db.from('business_payment_methods').update({
              display_name: method.displayName, public_instructions: method.publicInstructions || null, is_enabled: true, sort_order: method.sortOrder, updated_at: new Date().toISOString()
            }).eq('id', old.id).eq('business_id', businessId).select('id').maybeSingle();
            if (error || !updatedMethod) throw new Error(error?.message || 'No se pudo actualizar un método de pago del negocio.');
            retained.add(old.id);
          } else {
            const { error } = await db.from('business_payment_methods').insert({
              business_id: businessId, method_code: method.methodCode, display_name: method.displayName,
              public_instructions: method.publicInstructions || null, is_enabled: true, sort_order: method.sortOrder
            });
            if (error) throw error;
          }
        }
        for (const old of (existing || [])) {
          if (!retained.has(old.id) && old.is_enabled) {
            const { data: disabledMethod, error } = await db.from('business_payment_methods').update({ is_enabled: false, updated_at: new Date().toISOString() }).eq('id', old.id).eq('business_id', businessId).select('id').maybeSingle();
            if (error || !disabledMethod) throw new Error(error?.message || 'No se pudo desactivar un método de pago anterior.');
          }
        }
        message.textContent = 'Datos del negocio, métodos de pago y logo guardados correctamente.';
        message.className = 'message success';
        businessName = name;
        const heading = document.querySelector('#businessName'); if (heading) heading.textContent = name;
        if (form.elements.logo_url) form.elements.logo_url.value = businessPayload.logo_url || '';
        if (form.elements.logo_file) form.elements.logo_file.value = '';
      } catch (error) {
        message.textContent = 'Los datos generales se guardaron, pero hubo un problema al actualizar los métodos de pago: ' + (error.message || 'Error desconocido');
        message.className = 'message error';
      }
    } catch (error) {
      message.textContent = error.message || 'No se pudo guardar la configuración.';
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
  }

  async function saveBusinessContent(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#businessContentMessage');
    const contentType = form.elements.content_type.value;
    const title = form.elements.title.value.trim();
    const body = form.elements.body.value.trim();
    const fields = form.elements.form_fields.value.split('\n').map(value => value.trim()).filter(Boolean).slice(0, 30);
    if (!title || !body) {
      message.textContent = 'Completa el título y la descripción.';
      message.className = 'message error';
      return;
    }
    const button = form.querySelector('button[type="submit"]');
    button.disabled = true;
    message.textContent = 'Guardando y enviando a revisión…';
    message.className = 'message';
    try {
      const payload = {
        business_id: businessId,
        content_type: contentType,
        title,
        body,
        content: { form_fields: contentType === 'job_form' ? fields : [] },
        is_published: form.elements.is_published.checked,
        created_by: currentUser.id,
        updated_by: currentUser.id
      };
      const { error } = await db.from('business_content_pages').insert(payload);
      if (error) throw error;
      form.reset();
      message.textContent = 'Contenido guardado y enviado a revisión técnica. Solo aparecerá públicamente después de ser aprobado.';
      message.className = 'message success';
      await loadBusinessContent();
    } catch (error) {
      message.textContent = 'No se pudo guardar: ' + (error.message || 'Error desconocido');
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
  }

  async function loadBusinessContent() {
    const target = document.querySelector('#businessContentList');
    if (!target) return;
    const { data, error } = await db.from('business_content_pages')
      .select('id,content_type,title,body,is_published,moderation_status,moderation_note,created_at')
      .eq('business_id', businessId).order('created_at', { ascending: false }).limit(100);
    if (error) { showError(target, error); return; }
    const rows = data || [];
    if (!rows.length) { target.innerHTML = '<div class="empty">Este negocio todavía no tiene publicaciones.</div>'; return; }
    const labels = { promotion: 'Promoción', job_form: 'Empleo', announcement: 'Anuncio', contact: 'Información' };
    target.innerHTML = tableHtml(
      ['Tipo', 'Título', 'Estado de revisión', 'Visible', 'Fecha'],
      rows.map(row => [
        esc(labels[row.content_type] || row.content_type),
        '<strong>' + esc(row.title) + '</strong><br><small>' + esc(row.body) + '</small>' + (row.moderation_note ? '<br><small>Nota técnica: ' + esc(row.moderation_note) + '</small>' : ''),
        esc(row.moderation_status),
        row.is_published ? 'Sí' : 'No',
        dateTime(row.created_at)
      ])
    );
  }

  async function loadJobApplications() {
    const target = document.querySelector('#jobApplicationsContainer');
    if (!target) return;
    const { data, error } = await db.from('job_applications')
      .select('id,content_page_id,applicant_name,applicant_contact,applicant_message,form_responses,status,admin_notes,created_at,resume_path')
      .eq('business_id', businessId).order('created_at', { ascending: false }).limit(100);
    if (error) { showError(target, error); return; }
    const rows = data || [];
    if (!rows.length) { target.innerHTML = '<div class="empty">Todavía no se han recibido postulaciones.</div>'; return; }
    target.innerHTML = '<div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Postulante</th><th>Contacto</th><th>Mensaje y respuestas</th><th>Hoja de vida</th><th>Estado</th><th>Notas internas</th><th>Guardar</th></tr></thead><tbody>' +
      (await Promise.all(rows.map(async row => {
        let resumeLink = '<span class="muted">No adjuntó</span>';
        if (row.resume_path) {
          const { data: signedFile, error: signedError } = await db.storage.from('job-applications-private').createSignedUrl(row.resume_path, 300, { download: true });
          resumeLink = signedError || !signedFile?.signedUrl
            ? '<span class="muted">Archivo no disponible</span>'
            : '<a href="' + esc(signedFile.signedUrl) + '" target="_blank" rel="noopener">Descargar hoja de vida</a>';
        }
        const responseText = Object.entries(row.form_responses || {}).map(([key, value]) => esc(key + ': ' + value)).join('<br>');
        return '<tr><td>' + dateTime(row.created_at) + '</td><td>' + esc(row.applicant_name) + '</td><td>' + esc(row.applicant_contact) + '</td><td>' + esc(row.applicant_message || '—') + (responseText ? '<br>' + responseText : '') + '</td><td>' + resumeLink + '</td><td><select class="field" data-application-status="' + esc(row.id) + '"><option value="pending"' + (row.status === 'pending' ? ' selected' : '') + '>Pendiente</option><option value="reviewing"' + (row.status === 'reviewing' ? ' selected' : '') + '>En revisión</option><option value="contacted"' + (row.status === 'contacted' ? ' selected' : '') + '>Contactado</option><option value="accepted"' + (row.status === 'accepted' ? ' selected' : '') + '>Aceptado</option><option value="rejected"' + (row.status === 'rejected' ? ' selected' : '') + '>No seleccionado</option></select></td><td><textarea class="field" rows="2" maxlength="3000" data-application-notes="' + esc(row.id) + '">' + esc(row.admin_notes || '') + '</textarea></td><td><button type="button" class="small-button" data-save-application="' + esc(row.id) + '">Guardar</button></td></tr>';
      }))).join('') + '</tbody></table></div>';
    target.querySelectorAll('[data-save-application]').forEach(button => button.addEventListener('click', async () => {
      const id = button.dataset.saveApplication;
      const status = target.querySelector('[data-application-status="' + id + '"]')?.value;
      const notes = target.querySelector('[data-application-notes="' + id + '"]')?.value || '';
      button.disabled = true;
      const { error: updateError } = await db.from('job_applications').update({
        status, admin_notes: notes, reviewed_by: currentUser.id, reviewed_at: new Date().toISOString()
      }).eq('id', id).eq('business_id', businessId);
      if (updateError) alert('No se pudo actualizar la postulación: ' + updateError.message);
      else alert('Postulación actualizada.');
      button.disabled = false;
    }));
  }

  async function initBusinessAi() {
    const form = document.querySelector('#businessAiForm');
    if (!form) return;
    const message = document.querySelector('#businessAiMessage');
    const { data, error } = await db.from('business_ai_settings')
      .select('enabled,assistant_name,instructions')
      .eq('business_id', businessId)
      .maybeSingle();
    if (error) {
      if (message) {
        message.textContent = 'No se pudo cargar la configuración de IA de este negocio: ' + error.message;
        message.className = 'message error';
      }
      return;
    }
    form.elements.enabled.checked = Boolean(data?.enabled);
    form.elements.assistant_name.value = data?.assistant_name || 'Asistente del negocio';
    form.elements.instructions.value = data?.instructions || '';
  }

  async function saveBusinessAi(event) {
    event.preventDefault(); const form=event.currentTarget, message=document.querySelector('#businessAiMessage');
    const payload={business_id:businessId,enabled:form.elements.enabled.checked,assistant_name:form.elements.assistant_name.value.trim(),instructions:form.elements.instructions.value.trim(),updated_by:currentUser.id,updated_at:new Date().toISOString()};
    const {error}=await db.from('business_ai_settings').upsert(payload,{onConflict:'business_id'}); message.textContent=error?`No se pudo guardar: ${error.message}`:'Configuración de IA de este negocio guardada por separado de la IA general.'; message.className=error?'message error':'message success';
  }

  async function loadBlockTargetUsers() {
    const target = document.querySelector('#blockTargetUser');
    if (!target) return;
    if (panel !== 'business_admin' || !isBusinessOwner) {
      target.closest('form')?.classList.add('hidden');
      const note = document.querySelector('#blockRequestOwnerNote');
      if (note) note.classList.remove('hidden');
      return;
    }
    target.innerHTML = '<option value="">Cargando usuarios del negocio…</option>';
    const { data, error } = await db.from('business_memberships')
      .select('user_id,role,profiles(display_name)')
      .eq('business_id', businessId)
      .eq('status', 'active')
      .neq('user_id', currentUser.id)
      .order('created_at', { ascending: true });
    if (error) {
      target.innerHTML = '<option value="">No se pudieron cargar los usuarios</option>';
      const message = document.querySelector('#blockRequestMessage');
      if (message) { message.textContent = 'No fue posible consultar las cuentas activas del negocio.'; message.className = 'message error'; }
      console.warn('Block request target users:', error);
      return;
    }
    const users = data || [];
    target.innerHTML = '<option value="">Selecciona una cuenta</option>' + users.map(member => {
      const profile = Array.isArray(member.profiles) ? member.profiles[0] : member.profiles;
      const name = profile?.display_name || shortId(member.user_id);
      const role = member.role === 'business_admin' ? 'Administrador' : 'Empleado';
      return `<option value="${esc(member.user_id)}">${esc(name)} · ${role}</option>`;
    }).join('');
    if (!users.length) target.innerHTML = '<option value="">No hay otras cuentas activas en este negocio</option>';
  }

  async function submitBlockRequest(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#blockRequestMessage');
    const button = form.querySelector('button[type="submit"]');
    const targetUserId = form.elements.target_user_id.value;
    const reason = form.elements.reason.value.trim();
    if (panel !== 'business_admin' || !isBusinessOwner) {
      message.textContent = 'Solo el administrador del negocio puede solicitar este bloqueo.';
      message.className = 'message error';
      return;
    }
    if (!targetUserId || targetUserId === currentUser.id || reason.length < 5) {
      message.textContent = 'Selecciona otra cuenta activa y escribe un motivo de al menos cinco caracteres.';
      message.className = 'message error';
      return;
    }
    button.disabled = true;
    try {
      const { error } = await db.from('access_block_requests').insert({
        business_id: businessId,
        requested_by: currentUser.id,
        target_user_id: targetUserId,
        reason
      });
      if (error) throw error;
      message.textContent = 'Solicitud enviada al servicio técnico. El acceso no se bloquea hasta que el propietario técnico la revise.';
      message.className = 'message success';
      form.reset();
      await loadBlockTargetUsers();
    } catch (error) {
      message.textContent = error.message || 'No se pudo enviar la solicitud.';
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
  }

  function populateFinanceBusinessOptions() {
    document.querySelectorAll('#platformFinanceForm select[name="business_id"], #payrollForm select[name="business_id"]').forEach(select => {
      const selected = select.value;
      select.innerHTML = '<option value="">Plataforma</option>' + cachedBusinesses.map(b => `<option value="${esc(b.id)}">${esc(b.name)}</option>`).join('');
      select.value = selected;
    });
  }

  async function loadFinance() {
    const target = document.querySelector('#financeContainer');
    if (!target) return;
    target.innerHTML = '<div class="empty">Cargando finanzas y nómina…</div>';
    try {
      const result = await callTechnicalFunction({ action: 'list_platform_finance' });
      const finance = result.financial_records || [];
      const payroll = result.payroll_records || [];
      const businessMap = new Map(cachedBusinesses.map(b => [b.id, b.name]));
      populateFinanceBusinessOptions();
      const financeHtml = finance.length
        ? tableHtml(['Fecha','Negocio','Tipo','Descripción','Importe','Referencia'], finance.map(r => [
            dateTime(r.occurred_at),
            r.business_id ? businessMap.get(r.business_id) || 'Negocio' : 'Plataforma',
            ({ income: 'Ingreso', expense: 'Gasto', refund: 'Reembolso', adjustment: 'Ajuste' })[r.record_type] || r.record_type,
            r.description,
            money(r.amount),
            r.reference || '—'
          ]))
        : '<div class="empty">Todavía no hay movimientos financieros registrados.</div>';
      const payrollHtml = payroll.length
        ? `<div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Beneficiario</th><th>Concepto</th><th>Importe</th><th>Estado</th><th>Acciones</th></tr></thead><tbody>${payroll.map(r => `<tr>
            <td>${dateTime(r.paid_at || r.due_date || r.created_at)}</td>
            <td>${esc(r.payee_name)}</td>
            <td>${esc(r.description)}</td>
            <td>${money(r.amount)}</td>
            <td>${({ pending: 'Pendiente', paid: 'Registrado como pagado', cancelled: 'Cancelado' })[r.status] || esc(r.status)}</td>
            <td>${r.status === 'pending'
              ? `<button class="small-button" data-payroll-action="paid" data-payroll-id="${esc(r.id)}">Registrar pago</button> <button class="small-button" data-payroll-action="cancelled" data-payroll-id="${esc(r.id)}">Cancelar</button>`
              : '—'}</td>
          </tr>`).join('')}</tbody></table></div>`
        : '<div class="empty">Todavía no hay obligaciones de nómina registradas.</div>';
      target.innerHTML = `<div class="section-heading"><h3>Movimientos financieros</h3></div>${financeHtml}<div class="section-heading"><h3>Nómina y honorarios</h3></div>${payrollHtml}`;
      target.querySelectorAll('[data-payroll-action]').forEach(button => button.addEventListener('click', async () => {
        const decision = button.dataset.payrollAction;
        if (decision === 'cancelled' && !window.confirm('¿Cancelar esta obligación de nómina?')) return;
        const reference = decision === 'paid' ? (window.prompt('Referencia del comprobante (opcional):', '') || '') : '';
        button.disabled = true;
        try {
          const response = await callTechnicalFunction({
            action: 'resolve_payroll_record',
            record_id: button.dataset.payrollId,
            decision,
            payment_reference: reference
          });
          alert(response.message || 'Registro actualizado.');
          await loadFinance();
          await loadAuditEvents(null, '#auditContainer');
        } catch (error) {
          alert(error.message || 'No se pudo actualizar el registro.');
          button.disabled = false;
        }
      }));
    } catch (error) {
      showError(target, error);
    }
  }

  async function createPlatformFinancialRecord(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#platformFinanceMessage');
    const button = form.querySelector('button[type="submit"]');
    button.disabled = true;
    try {
      const response = await callTechnicalFunction({
        action: 'create_platform_financial_record',
        record_type: form.elements.record_type.value,
        business_id: form.elements.business_id.value || null,
        description: form.elements.description.value.trim(),
        amount: form.elements.amount.value,
        occurred_at: form.elements.occurred_at.value ? new Date(form.elements.occurred_at.value).toISOString() : null,
        reference: form.elements.reference.value.trim() || null,
        currency: 'COP'
      });
      message.textContent = response.audit_warning || 'Movimiento financiero guardado.';
      message.className = response.audit_warning ? 'message error' : 'message success';
      form.reset();
      await loadFinance();
      await loadAuditEvents(null, '#auditContainer');
    } catch (error) {
      message.textContent = error.message || 'No se pudo guardar el movimiento.';
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
  }

  async function createPayrollRecord(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.querySelector('#payrollMessage');
    const button = form.querySelector('button[type="submit"]');
    button.disabled = true;
    try {
      const response = await callTechnicalFunction({
        action: 'create_payroll_record',
        payee_name: form.elements.payee_name.value.trim(),
        business_id: form.elements.business_id.value || null,
        description: form.elements.description.value.trim(),
        amount: form.elements.amount.value,
        due_date: form.elements.due_date.value || null,
        currency: 'COP'
      });
      message.textContent = response.audit_warning || 'Obligación de nómina guardada.';
      message.className = response.audit_warning ? 'message error' : 'message success';
      form.reset();
      await loadFinance();
      await loadAuditEvents(null, '#auditContainer');
    } catch (error) {
      message.textContent = error.message || 'No se pudo guardar la obligación.';
      message.className = 'message error';
    } finally {
      button.disabled = false;
    }
  }

  async function loadContentModeration() {
    const target = document.querySelector('#contentModerationContainer');
    if (!target) return;
    target.innerHTML = '<div class="empty">Cargando publicaciones para revisión…</div>';
    try {
      // La moderación técnica usa la Edge Function privilegiada; no abre
      // lectura global de business_content_pages mediante el Data API/RLS.
      const result = await callTechnicalFunction({ action: 'list_content_moderation', limit: 100 });
      const rows = result.contents || [];
      if (!rows.length) {
        target.innerHTML = '<div class="empty">No hay publicaciones enviadas por los negocios.</div>';
        return;
      }
      target.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Negocio</th><th>Tipo</th><th>Título y contenido</th><th>Estado</th><th>Acción</th></tr></thead><tbody>${rows.map(r => `<tr><td>${dateTime(r.created_at)}</td><td>${esc(r.businesses?.name || shortId(r.business_id))}</td><td>${esc(r.content_type)}</td><td><strong>${esc(r.title)}</strong><br>${esc(r.body)}</td><td>${esc(r.moderation_status || 'pending')}</td><td>${r.moderation_status !== 'approved' ? `<button class="small-button" data-moderate-content="${esc(r.id)}" data-decision="approved">Aprobar</button>` : ''} ${r.moderation_status !== 'rejected' ? `<button class="small-button" data-moderate-content="${esc(r.id)}" data-decision="rejected">Rechazar</button>` : '—'}</td></tr>`).join('')}</tbody></table></div>`;
      target.querySelectorAll('[data-moderate-content]').forEach(btn => btn.addEventListener('click', async () => {
        const note = window.prompt('Nota de revisión (opcional):', '') || '';
        btn.disabled = true;
        try {
          const actionResult = await callTechnicalFunction({
            action: 'moderate_business_content',
            content_id: btn.dataset.moderateContent,
            decision: btn.dataset.decision,
            moderation_note: note
          });
          alert(actionResult.message);
          await loadContentModeration();
          await loadAuditEvents(null, '#auditContainer');
        } catch (error) {
          alert(error.message);
          btn.disabled = false;
        }
      }));
    } catch (error) {
      showError(target, error);
    }
  }

  async function loadBlockRequests() {
    const target = document.querySelector('#blockRequestsContainer');
    if (!target) return;
    target.innerHTML = '<div class="empty">Cargando solicitudes de bloqueo…</div>';
    try {
      const result = await callTechnicalFunction({ action: 'list_block_requests' });
      const rows = result.requests || [];
      if (!rows.length) {
        target.innerHTML = '<div class="empty">No hay solicitudes de bloqueo registradas.</div>';
        return;
      }
      target.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Negocio</th><th>Solicitante</th><th>Cuenta solicitada</th><th>Motivo</th><th>Estado</th><th>Acción</th></tr></thead><tbody>${rows.map(r => `<tr><td>${dateTime(r.created_at)}</td><td>${esc(r.businesses?.name || shortId(r.business_id))}</td><td>${esc(r.requested_by_name || shortId(r.requested_by))}</td><td>${esc(r.target_user_name || shortId(r.target_user_id))}</td><td>${esc(r.reason)}</td><td>${esc(r.status)}</td><td>${r.status === 'pending' ? `<button class="small-button" data-request-resolve="${esc(r.id)}" data-decision="approved">Bloquear acceso</button> <button class="small-button" data-request-resolve="${esc(r.id)}" data-decision="rejected">Rechazar</button>` : esc(r.technician_note || 'Resuelta')}</td></tr>`).join('')}</tbody></table></div>`;
      target.querySelectorAll('[data-request-resolve]').forEach(button => button.addEventListener('click', async () => {
        const decision = button.dataset.decision;
        const note = window.prompt('Nota del servicio técnico (opcional):', '') || '';
        if (decision === 'approved' && !window.confirm('Se suspenderá únicamente la membresía de esta persona en el negocio indicado. ¿Deseas continuar?')) return;
        button.disabled = true;
        try {
          const result = await callTechnicalFunction({
            action: 'resolve_block_request',
            request_id: button.dataset.requestResolve,
            decision,
            technician_note: note
          });
          alert(result.message);
          await loadBlockRequests();
          await loadTechnical();
        } catch (error) {
          alert(error.message || 'No se pudo resolver la solicitud.');
          button.disabled = false;
        }
      }));
    } catch (error) {
      showError(target, error);
    }
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
      const paymentAction = admin && o.payment_status === 'pending' && o.status !== 'cancelled'
        ? ` <button class="small-button" data-mark-payment="${esc(o.id)}" data-payment-method="${esc(o.payment_method || '')}">Confirmar pago recibido</button>`
        : '';
      const action = `${nextStatus[o.status] ? `<button class="small-button" data-next="${nextStatus[o.status]}" data-order="${esc(o.id)}">Marcar: ${statusLabels[nextStatus[o.status]]}</button>` : ''}${paymentAction}${!['delivered','cancelled'].includes(o.status) ? ` <button class="small-button" data-cancel-request="${esc(o.id)}">Solicitar cancelación</button>` : ''}` || '—';
      const base = [esc(`#${o.order_number}`), esc(o.customer_name || 'Cliente'), esc(o.customer_phone || '—'), esc(o.delivery_address || '—') + (o.delivery_notes ? `<br><small>${esc(o.delivery_notes)}</small>` : '') + (o.delivery_tracking ? `<br><small>Seguimiento: ${esc(o.delivery_tracking)}</small>` : ''), items || 'Sin detalle', `<span class="pill ${statusClass[o.status] || ''}">${statusLabels[o.status] || esc(o.status)}</span>`, dateTime(o.created_at)];
      if (admin) base.splice(5, 0, `${money(o.total)}<br><small>${esc(o.payment_status || '—')} · ${esc(o.payment_method || '—')}</small>`);
      base.push(action);
      return base;
    });
    const headers = admin ? ['Pedido','Cliente','Teléfono','Entrega','Productos','Total / pago','Estado','Creado','Acción'] : ['Pedido','Cliente','Teléfono','Entrega','Productos','Estado','Creado','Acción'];
    target.innerHTML = tableHtml(headers, rows);
    target.querySelectorAll('[data-next][data-order]').forEach(button => button.addEventListener('click', () => changeOrderStatus(button.dataset.order, button.dataset.next, button)));
    target.querySelectorAll('[data-mark-payment]').forEach(button => button.addEventListener('click', () => markOrderPaymentReceived(button.dataset.markPayment, button.dataset.paymentMethod, button)));
    target.querySelectorAll('[data-cancel-request]').forEach(button => button.addEventListener('click', () => requestCancellation(button.dataset.cancelRequest, button)));
  }

  async function loadRefundableOrders() {
    const target = document.querySelector('#refundsContainer');
    if (!target || panel !== 'business_admin') return;
    target.innerHTML = '<div class="empty">Consultando pedidos pagados y cancelados…</div>';
    const { data, error } = await db.rpc('get_business_admin_order_financials', {
      p_business_id: businessId,
      p_refundable_only: true,
      p_limit: 100
    });
    if (error) return showError(target, error);
    const orders = data || [];
    if (!orders.length) {
      target.innerHTML = '<div class="empty">No hay reembolsos pendientes de registrar.</div>';
      return;
    }
    const rows = orders.map(o => [
      esc(`#${o.order_number}`),
      money(o.total),
      dateTime(o.created_at),
      `<button class="small-button" data-register-refund="${esc(o.order_id)}">Registrar reembolso realizado</button>`
    ]);
    target.innerHTML = tableHtml(['Pedido','Importe a devolver','Fecha del pedido','Acción'], rows);
    target.querySelectorAll('[data-register-refund]').forEach(button => {
      button.addEventListener('click', () => registerOrderRefund(button.dataset.registerRefund, button));
    });
  }

  async function markOrderPaymentReceived(orderId, paymentMethod, button) {
    if (!window.confirm('Confirma que el negocio ya recibió realmente el pago de este pedido? Esta acción registrará el ingreso y no realiza ningún cobro automático.')) return;
    const provider = window.prompt('Entidad o proveedor (opcional, por ejemplo, banco o billetera):');
    if (provider === null) return;
    const reference = window.prompt(paymentMethod === 'cash'
      ? 'Referencia o comprobante (opcional para efectivo):'
      : 'Referencia o número del comprobante del pago recibido:');
    if (reference === null) return;
    if (paymentMethod !== 'cash' && !reference.trim()) {
      alert('Para pagos que no son en efectivo debes registrar una referencia o comprobante.');
      return;
    }
    const notes = window.prompt('Observaciones adicionales (opcional):');
    if (notes === null) return;
    button.disabled = true;
    const { data, error } = await db.rpc('mark_order_payment_received', {
      p_order_id: orderId,
      p_provider: provider.trim() || null,
      p_reference: reference.trim() || null,
      p_notes: notes.trim() || null
    });
    if (error) {
      alert(`No se pudo confirmar el pago. Comprueba que el procedimiento de confirmación esté desplegado y que el dinero ya se haya recibido. ${error.message}`);
      button.disabled = false;
      return;
    }
    alert('Pago recibido y registrado. El ingreso quedó guardado en los movimientos financieros.');
    await loadBusinessAdmin();
  }

  async function registerOrderRefund(orderId, button) {
    const method = window.prompt('Medio utilizado para devolver el dinero (por ejemplo, transferencia o efectivo):');
    if (method === null) return;
    if (!method.trim()) { alert('Debes indicar el medio de reembolso.'); return; }
    const provider = window.prompt('Entidad o proveedor (opcional, por ejemplo, banco o billetera):');
    if (provider === null) return;
    const reference = window.prompt('Referencia o número del comprobante del reembolso ya realizado:');
    if (reference === null) return;
    if (!reference.trim()) { alert('Debes registrar una referencia o comprobante.'); return; }
    const notes = window.prompt('Observaciones adicionales (opcional):');
    if (notes === null) return;
    button.disabled = true;
    const { data, error } = await db.rpc('complete_order_refund', {
      p_order_id: orderId,
      p_refund_method: method.trim(),
      p_provider: provider.trim() || null,
      p_reference: reference.trim(),
      p_notes: notes.trim() || null
    });
    if (error) {
      alert(`No se pudo registrar el reembolso. Comprueba que el procedimiento de reembolsos esté desplegado y que el dinero ya se haya devuelto. ${error.message}`);
      button.disabled = false;
      return;
    }
    alert('Reembolso registrado. El pedido ahora figura como reembolsado.');
    await loadBusinessAdmin();
  }

  async function requestCancellation(orderId, button) {
    const reason = window.prompt('Escribe el motivo comunicado por el cliente (mínimo 5 caracteres):');
    if (reason === null) return;
    if (reason.trim().length < 5 || reason.trim().length > 2000) {
      alert('El motivo debe tener entre 5 y 2000 caracteres.');
      return;
    }
    button.disabled = true;
    const { data, error } = await db.rpc('request_order_cancellation', {
      p_business_id: businessId,
      p_order_id: orderId,
      p_customer_reason: reason.trim()
    });
    if (error) {
      alert(`No se pudo registrar la solicitud. Comprueba que la migración de cancelaciones esté desplegada. ${error.message}`);
      button.disabled = false;
      return;
    }
    alert('La solicitud quedó registrada y pendiente de decisión del administrador.');
    if (panel === 'business_admin') await Promise.all([loadBusinessOrders(), loadCancellationRequests()]);
    else await loadEmployeeOrders();
  }

  async function loadCancellationRequests() {
    const target = document.querySelector('#cancellationRequestsContainer');
    if (!target || panel !== 'business_admin') return;
    target.innerHTML = '<div class="empty">Cargando solicitudes…</div>';
    const { data, error } = await db.from('order_cancellation_requests')
      .select('id,order_id,customer_reason,status,forwarded_at,admin_response,orders(order_number,status)')
      .eq('business_id', businessId)
      .order('created_at', { ascending: false })
      .limit(100);
    if (error) return showError(target, error);
    const requests = data || [];
    if (!requests.length) {
      target.innerHTML = '<div class="empty">Todavía no hay solicitudes de cancelación.</div>';
      return;
    }
    const rows = requests.map(r => {
      const order = Array.isArray(r.orders) ? r.orders[0] : r.orders;
      const decision = r.status === 'pending'
        ? `<button class="small-button" data-cancellation-decision="approved" data-request="${esc(r.id)}">Aprobar</button> <button class="small-button" data-cancellation-decision="rejected" data-request="${esc(r.id)}">Rechazar</button>`
        : esc(r.status === 'approved' ? 'Aprobada' : 'Rechazada');
      return [
        esc(order?.order_number ? `#${order.order_number}` : r.order_id),
        esc(r.customer_reason),
        esc(statusLabels[order?.status] || order?.status || '—'),
        esc(r.status === 'pending' ? 'Pendiente' : r.status === 'approved' ? 'Aprobada' : 'Rechazada'),
        dateTime(r.forwarded_at),
        decision
      ];
    });
    target.innerHTML = tableHtml(['Pedido','Motivo','Estado del pedido','Solicitud','Fecha','Decisión'], rows);
    target.querySelectorAll('[data-cancellation-decision][data-request]').forEach(button => {
      button.addEventListener('click', () => decideCancellation(button.dataset.request, button.dataset.cancellationDecision, button));
    });
  }

  async function decideCancellation(requestId, decision, button) {
    const response = window.prompt(decision === 'approved'
      ? 'Respuesta para dejar registrada al aprobar (opcional):'
      : 'Indica el motivo del rechazo:');
    if (response === null) return;
    if (decision === 'rejected' && response.trim().length < 5) {
      alert('Escribe un motivo de rechazo de al menos 5 caracteres.');
      return;
    }
    button.disabled = true;
    const { data, error } = await db.rpc('decide_order_cancellation', {
      p_request_id: requestId,
      p_decision: decision,
      p_admin_response: response.trim() || null
    });
    if (error) {
      alert(`No se pudo procesar la solicitud. Comprueba que la migración esté desplegada. ${error.message}`);
      button.disabled = false;
      return;
    }
    alert(decision === 'approved'
      ? 'Cancelación aprobada. El inventario asociado fue restituido. Si el pedido estaba pagado, el reembolso debe gestionarse por separado.'
      : 'Solicitud rechazada. El pedido y el inventario no fueron modificados.');
    await loadBusinessAdmin();
  }

  async function changeOrderStatus(orderId, next, button) {
    button.disabled = true;
    const changes = { status: next };

    // Al iniciar el reparto, guardar una referencia que el cliente pueda consultar
    // con su código privado de seguimiento.
    if (next === 'out_for_delivery') {
      const tracking = window.prompt(
        'Ingresa el enlace o referencia de seguimiento. Si no usas transportadora, escribe por ejemplo: Domiciliario del negocio.',
        'Domiciliario del negocio'
      );
      if (tracking === null) {
        button.disabled = false;
        return;
      }
      const normalizedTracking = tracking.trim();
      if (normalizedTracking.length < 3 || normalizedTracking.length > 500) {
        alert('La referencia de seguimiento debe tener entre 3 y 500 caracteres.');
        button.disabled = false;
        return;
      }
      changes.delivery_tracking = normalizedTracking;
    }

    const { data: updatedOrder, error } = await db.from('orders')
      .update(changes)
      .eq('id', orderId)
      .eq('business_id', businessId)
      .select('id,status,delivery_tracking')
      .maybeSingle();
    if (error || !updatedOrder) {
      alert(`No se pudo cambiar el estado: ${error?.message || 'El pedido no existe, pertenece a otro negocio o no tienes permiso para cambiarlo.'}`);
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
