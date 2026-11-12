(() => {
  const $ = selector => document.querySelector(selector);
  const message = $("#customerMessage");
  let client;
  let activeUserId = null;

  function say(text, kind = "") {
    message.textContent = text;
    message.className = ("message " + kind).trim();
  }
  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, char => ({
      "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"
    }[char]));
  }
  function money(value) {
    return new Intl.NumberFormat("es-CO", { style:"currency", currency:"COP", maximumFractionDigits:0 }).format(Number(value || 0));
  }
  function date(value) {
    return value ? new Intl.DateTimeFormat("es-CO", { dateStyle:"medium", timeStyle:"short", timeZone:"America/Bogota" }).format(new Date(value)) : "Fecha no disponible";
  }
  function status(value) {
    return ({pending:"Recibido",confirmed:"Confirmado",preparing:"En preparación",ready:"Listo",out_for_delivery:"En camino",delivered:"Entregado",cancelled:"Cancelado"})[value] || value || "Sin estado";
  }
  async function showSession(session) {
    if (!session) {
      activeUserId = null;
      $("#accountAccess").hidden = false;
      $("#customerDashboard").hidden = true;
      $("#customerOrders").replaceChildren();
      $("#customerFavorites").replaceChildren();
      $("#customerEmailLabel").textContent = "";
      return;
    }
    activeUserId = session.user.id;
    $("#accountAccess").hidden = true;
    $("#customerDashboard").hidden = false;
    $("#customerWelcome").textContent = "Hola, " + (session.user.user_metadata?.display_name || "cliente");
    $("#customerEmailLabel").textContent = session.user.email || "";
    await Promise.all([loadOrders(session.user.id), loadFavorites(session.user.id)]);
  }
  async function loadOrders(userId) {
    const target = $("#customerOrders");
    target.innerHTML = '<p class="muted">Cargando pedidos…</p>';
    const { data, error } = await client.from("orders")
      .select("id,order_number,status,payment_status,subtotal,delivery_fee,total,created_at,businesses(name),order_items(product_name,quantity,unit_price,line_total)")
      .eq("customer_user_id", userId)
      .order("created_at", { ascending:false })
      .limit(50);
    if (activeUserId !== userId) return;
    if (error) {
      target.textContent = "No fue posible cargar el historial. Comprueba que la migración de clientes esté aplicada.";
      console.warn("Customer order history:", error);
      return;
    }
    if (!data?.length) {
      target.innerHTML = '<p class="muted">Todavía no tienes pedidos asociados a esta cuenta. Los pedidos realizados como invitado no se vinculan automáticamente.</p>';
      return;
    }
    target.innerHTML = data.map(order => `
      <article class="security-note">
        <strong>Pedido #${escapeHtml(order.order_number)} · ${escapeHtml(order.businesses?.name || "Negocio")}</strong>
        <p>${escapeHtml(date(order.created_at))} · ${escapeHtml(status(order.status))}</p>
        <p>Total: <strong>${money(order.total)}</strong> · Pago: ${escapeHtml(order.payment_status)}</p>
        <ul>${(order.order_items || []).map(item => `<li>${escapeHtml(item.product_name)} × ${Number(item.quantity)} — ${money(item.line_total ?? Number(item.unit_price) * Number(item.quantity))}</li>`).join("")}</ul>
      </article>`).join("");
  }
  async function loadFavorites(userId) {
    const target = $("#customerFavorites");
    target.innerHTML = '<p class="muted">Cargando favoritos…</p>';
    const { data, error } = await client.from("customer_favorites")
      .select("id,product_id,created_at,products(id,name,price,image_url,business_id)")
      .eq("user_id", userId)
      .order("created_at", { ascending:false });
    if (activeUserId !== userId) return;
    if (error) {
      target.textContent = "No fue posible cargar los favoritos. Comprueba que la migración de clientes esté aplicada.";
      console.warn("Customer favorites:", error);
      return;
    }
    const visible = (data || []).filter(item => item.products);
    if (!visible.length) {
      target.innerHTML = '<p class="muted">Aún no has guardado productos favoritos.</p>';
      return;
    }
    target.innerHTML = visible.map(item => `
      <article class="security-note">
        <strong>${escapeHtml(item.products.name)}</strong>
        <p>${money(item.products.price)}</p>
        <button class="button secondary" type="button" data-remove-favorite="${escapeHtml(item.id)}">Quitar de favoritos</button>
      </article>`).join("");
  }

  document.addEventListener("DOMContentLoaded", async () => {
    if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) {
      say("No se pudo cargar la conexión con el servicio. Intenta más tarde.", "error");
      return;
    }
    client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
    const { data, error } = await client.auth.getSession();
    if (error) say("No fue posible comprobar tu sesión.", "error");
    else await showSession(data.session);
    client.auth.onAuthStateChange((_event, session) => {
      // Evita ejecutar consultas Supabase dentro del callback de Auth.
      window.setTimeout(() => { void showSession(session); }, 0);
    });
  });

  $("#customerLoginForm").addEventListener("submit", async event => {
    event.preventDefault();
    const button = $("#customerLoginBtn");
    button.disabled = true;
    say("Verificando cuenta…");
    try {
      const { error } = await client.auth.signInWithPassword({
        email: $("#customerEmail").value.trim(),
        password: $("#customerPassword").value
      });
      if (error) throw error;
      say("Sesión iniciada.");
    } catch (error) {
      say(error.message || "No fue posible iniciar sesión.", "error");
    } finally { button.disabled = false; }
  });

  $("#customerRegisterForm").addEventListener("submit", async event => {
    event.preventDefault();
    const button = $("#customerRegisterBtn");
    const name = $("#customerName").value.trim();
    const email = $("#registerEmail").value.trim();
    const password = $("#registerPassword").value;
    if (name.length < 2 || password.length < 10) return say("Escribe tu nombre y una contraseña de al menos 10 caracteres.", "error");
    button.disabled = true;
    say("Creando cuenta…");
    try {
      const { data, error } = await client.auth.signUp({
        email,
        password,
        options:{
          data:{ display_name:name },
          emailRedirectTo:new URL("cuenta.html", window.location.href).href
        }
      });
      if (error) throw error;
      if (data.session) {
        say("Cuenta creada correctamente.");
        await showSession(data.session);
      } else {
        say("La cuenta fue creada. Revisa tu correo para confirmar la dirección y después inicia sesión.");
      }
    } catch (error) {
      say(error.message || "No fue posible crear la cuenta.", "error");
    } finally { button.disabled = false; }
  });

  $("#customerLogoutBtn").addEventListener("click", async () => {
    const { error } = await client.auth.signOut();
    if (error) say("No fue posible cerrar sesión.", "error");
    else {
      await showSession(null);
      say("Sesión cerrada.");
    }
  });

  document.addEventListener("click", async event => {
    const button = event.target.closest("[data-remove-favorite]");
    if (!button) return;
    button.disabled = true;
    const { error } = await client.from("customer_favorites").delete().eq("id", button.dataset.removeFavorite);
    if (error) say("No fue posible quitar el favorito.", "error");
    else {
      const { data } = await client.auth.getUser();
      if (data.user) await loadFavorites(data.user.id);
    }
  });
})();