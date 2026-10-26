
(() => {
  "use strict";

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[char]));

  const money = value => new Intl.NumberFormat("es-CO", {
    style: "currency",
    currency: "COP",
    maximumFractionDigits: 0
  }).format(value);

  const categoryInfo = {
    Comidas: {
      description: "Restaurantes, comidas rápidas y sabores de la región."
    },
    Moda: {
      description: "Prendas, accesorios y estilo para todos los días."
    },
    Tecnología: {
      description: "Accesorios y productos tecnológicos."
    },
    Mercado: {
      description: "Frutas, verduras y productos para tu despensa."
    },
    Hogar: {
      description: "Detalles para hacer tu casa más acogedora."
    }
  };

  let businesses = [
    {
      id: "sabor-expres",
      name: "Sabor Exprés",
      category: "Comidas",
      tagline: "Antojos preparados con mucho sabor.",
      location: "Pereira, Risaralda",
      hours: "Todos los días, 11:00 a. m. a 9:00 p. m.",
      rating: "4.8",
      image: "https://images.unsplash.com/photo-1555396273-367ea4eb4db5?auto=format&fit=crop&w=1000&q=85",
      products: [
        {
          id: "hamburguesa",
          name: "Hamburguesa de la casa",
          description: "Carne, vegetales frescos y salsa especial.",
          price: 18000,
          image: "https://images.unsplash.com/photo-1568901346375-23c9450c58cd?auto=format&fit=crop&w=700&q=80"
        },
        {
          id: "papas",
          name: "Papas crocantes",
          description: "Porción para acompañar tu comida.",
          price: 7000,
          image: "https://images.unsplash.com/photo-1573080496219-bb080dd4f877?auto=format&fit=crop&w=700&q=80"
        },
        {
          id: "pizza",
          name: "Pizza personal",
          description: "Pizza personal de la casa.",
          price: 16000,
          image: "https://images.unsplash.com/photo-1571407970349-bc81e7e96d47?auto=format&fit=crop&w=700&q=80"
        }
      ]
    },
    {
      id: "mercado-verde",
      name: "Mercado Verde",
      category: "Mercado",
      tagline: "Frescura para tu mesa cada día.",
      location: "Dosquebradas, Risaralda",
      hours: "Lunes a sábado, 7:00 a. m. a 6:00 p. m.",
      rating: "4.9",
      image: "https://images.unsplash.com/photo-1542838132-92c53300491e?auto=format&fit=crop&w=1000&q=85",
      products: [
        {
          id: "frutas",
          name: "Canasta de frutas",
          description: "Selección de frutas de temporada.",
          price: 24000,
          image: "https://images.unsplash.com/photo-1619566636858-adf3ef46400b?auto=format&fit=crop&w=700&q=80"
        },
        {
          id: "aguacate",
          name: "Aguacates",
          description: "Precio por unidad de demostración.",
          price: 3500,
          image: "https://images.unsplash.com/photo-1523049673857-eb18f1d7b578?auto=format&fit=crop&w=700&q=80"
        }
      ]
    },
    {
      id: "estilo-local",
      name: "Estilo Local",
      category: "Moda",
      tagline: "Prendas cómodas para tu propio estilo.",
      location: "Pereira, Risaralda",
      hours: "Lunes a sábado, 9:00 a. m. a 7:00 p. m.",
      rating: "4.7",
      image: "https://images.unsplash.com/photo-1483985988355-763728e1935b?auto=format&fit=crop&w=1000&q=85",
      products: [
        {
          id: "camiseta",
          name: "Camiseta básica",
          description: "Diseño casual para uso diario.",
          price: 32000,
          image: "https://images.unsplash.com/photo-1521572163474-6864f9cf17ab?auto=format&fit=crop&w=700&q=80"
        },
        {
          id: "bolso",
          name: "Bolso urbano",
          description: "Accesorio práctico para el día a día.",
          price: 58000,
          image: "https://images.unsplash.com/photo-1548036328-c9fa89d128fa?auto=format&fit=crop&w=700&q=80"
        }
      ]
    },
    {
      id: "tecno-eje",
      name: "Tecno Eje",
      category: "Tecnología",
      tagline: "Accesorios tecnológicos para tu rutina.",
      location: "Pereira, Risaralda",
      hours: "Lunes a sábado, 9:00 a. m. a 6:00 p. m.",
      rating: "4.8",
      image: "https://images.unsplash.com/photo-1498049794561-7780e7231661?auto=format&fit=crop&w=1000&q=85",
      products: [
        {
          id: "audifonos",
          name: "Audífonos inalámbricos",
          description: "Audífonos para música y llamadas.",
          price: 69000,
          image: "https://images.unsplash.com/photo-1505740420928-5e560c06d30e?auto=format&fit=crop&w=700&q=80"
        },
        {
          id: "parlante",
          name: "Parlante portátil",
          description: "Sonido compacto para llevar contigo.",
          price: 85000,
          image: "https://images.unsplash.com/photo-1608043152269-423dbba4e7e1?auto=format&fit=crop&w=700&q=80"
        }
      ]
    },
    {
      id: "hogar-practico",
      name: "Hogar Práctico",
      category: "Hogar",
      tagline: "Pequeños detalles que hacen la diferencia.",
      location: "Santa Rosa de Cabal, Risaralda",
      hours: "Lunes a sábado, 9:00 a. m. a 6:00 p. m.",
      rating: "4.6",
      image: "https://images.unsplash.com/photo-1616486338812-3dadae4b4ace?auto=format&fit=crop&w=1000&q=85",
      products: [
        {
          id: "lampara",
          name: "Lámpara de mesa",
          description: "Iluminación decorativa para interiores.",
          price: 49000,
          image: "https://images.unsplash.com/photo-1507473885765-e6ed057f782c?auto=format&fit=crop&w=700&q=80"
        },
        {
          id: "cojin",
          name: "Cojín decorativo",
          description: "Un toque de color para tu espacio.",
          price: 26000,
          image: "https://images.unsplash.com/photo-1584100936595-c0654b55a2e2?auto=format&fit=crop&w=700&q=80"
        }
      ]
    }
  ];

  let selectedCategory = "Todas";
  let currentBusinessId = null;
  let cart = [];
  let toastTimer;

  const getBusiness = id => businesses.find(business => business.id === id);
  const getProduct = (business, productId) =>
    business?.products.find(product => product.id === productId);

  async function loadRegisteredBusinesses() {
    try {
      if (!window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) return;
      const client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
      const { data: rows, error } = await client.from("businesses")
        .select("id,name,slug,business_type,category,description,tagline,city,contact_phone,opening_hours,logo_url,is_active,suspension_reason,suspension_public_message")
        .order("created_at", { ascending: false }).limit(200);
      if (error || !rows?.length) return;
      const { data: productRows, error: productError } = await client.from("products")
        .select("id,business_id,name,description,image_url,price,stock_quantity,track_inventory,is_active")
        .in("business_id", rows.map(row => row.id)).eq("is_active", true).order("created_at", { ascending: false }).limit(1000);
      const products = productError ? [] : (productRows || []);
      const [settingsResult, contentResult] = await Promise.all([
        client.from("business_store_settings").select("business_id,whatsapp_number,payment_methods,delivery_options,contact_options,advertising_enabled").in("business_id", rows.filter(r=>r.is_active).map(row => row.id)),
        client.from("business_content_pages").select("id,business_id,content_type,title,body,content,created_at").in("business_id", rows.filter(r=>r.is_active).map(row => row.id)).eq("is_published", true).order("created_at", { ascending: false }).limit(300)
      ]);
      const settingsByBusiness = new Map((settingsResult.data || []).map(item => [item.business_id, item]));
      const contentRows = contentResult.data || [];
      const registered = rows.map(row => ({
        id: row.id,
        name: row.name,
        category: row.category || row.business_type || "General",
        tagline: row.tagline || row.description || "Conoce los productos de este negocio local.",
        location: row.city || "Eje Cafetero",
        hours: row.opening_hours || "Consulta el horario con el negocio.",
        phone: row.contact_phone || "",
        rating: "Nuevo",
        isActive: row.is_active !== false,
        suspensionReason: row.suspension_reason || "",
        publicSuspensionMessage: row.suspension_public_message || "Esta tienda no está disponible temporalmente.",
        storeSettings: settingsByBusiness.get(row.id) || {},
        contentPages: contentRows.filter(item => item.business_id === row.id),
        image: row.logo_url || "https://images.unsplash.com/photo-1555396273-367ea4eb4db5?auto=format&fit=crop&w=1000&q=85",
        slug: row.slug,
        products: products.filter(product => product.business_id === row.id).map(product => ({
          id: product.id,
          name: product.name,
          description: product.description || "Producto disponible en esta tienda.",
          price: Number(product.price || 0),
          image: product.image_url || "https://images.unsplash.com/photo-1542838132-92c53300491e?auto=format&fit=crop&w=700&q=80"
        }))
      }));
      const registeredIds = new Set(registered.map(business => business.id));
      businesses = [...registered, ...businesses.filter(business => !registeredIds.has(business.id))];
    } catch (error) {
      console.warn("No se pudo cargar el directorio de negocios registrados; se mantiene la vista local de demostración.", error);
    }
  }

  function showToast(message) {
    const toast = $("#toast");
    toast.textContent = message;
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 2600);
  }

  function showView(view) {
    $("#homeView").classList.toggle("hidden", view !== "home");
    $("#listingView").classList.toggle("hidden", view !== "listing");
    $("#storeView").classList.toggle("hidden", view !== "store");
    $("#policyView").classList.toggle("hidden", view !== "policy");

    $$(".nav button").forEach(button => {
      button.classList.toggle(
        "active",
        (view === "home" && button.dataset.action === "home") ||
        (view === "listing" && button.dataset.action === "businesses")
      );
    });

    $(".nav").classList.remove("open");
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function businessCard(business) {
    return `
      <article class="business-card">
        <div class="business-image">
          <img src="${escapeHtml(business.image)}" alt="${escapeHtml(business.name)}" loading="lazy">
          <span class="business-badge">${business.isActive === false ? "Tienda suspendida" : escapeHtml(business.category)}</span>
        </div>
        <div class="business-card-body">
          <div class="business-card-top">
            <div>
              <h3>${escapeHtml(business.name)}</h3>
              <p>${escapeHtml(business.tagline)}</p>
            </div>
            <span class="rating">★ ${business.rating}</span>
          </div>
          <div class="business-meta">
            <span>⌖ ${business.location}</span>
            <button type="button" class="small-link"
              data-action="open-store" data-business="${business.id}">
              ${business.isActive === false ? "Ver aviso" : "Visitar tienda ↗"}
            </button>
          </div>
        </div>
      </article>`;
  }

  function renderFeatured() {
    $("#featuredGrid").innerHTML = businesses.slice(0, 3).map(businessCard).join("");
  }

  function renderChips() {
    const categories = ["Todas", ...Object.keys(categoryInfo)];

    $("#categoryChips").innerHTML = categories.map(category => `
      <button type="button"
        class="chip ${selectedCategory === category ? "active" : ""}"
        data-filter="${category}">${category}</button>
    `).join("");
  }

  function renderListing() {
    const query = $("#listingSearch").value.trim().toLocaleLowerCase("es");

    const filtered = businesses.filter(business => {
      const matchesCategory =
        selectedCategory === "Todas" || business.category === selectedCategory;

      const searchable = [
        business.name,
        business.category,
        business.tagline,
        ...business.products.map(product => product.name)
      ].join(" ").toLocaleLowerCase("es");

      return matchesCategory && (!query || searchable.includes(query));
    });

    $("#listingGrid").innerHTML = filtered.map(businessCard).join("");
    $("#emptyListing").classList.toggle("hidden", filtered.length > 0);
    $("#listingGrid").classList.toggle("hidden", filtered.length === 0);

    $("#listingTitle").textContent =
      selectedCategory === "Todas" ? "Tiendas locales" : selectedCategory;

    $("#listingDescription").textContent =
      selectedCategory === "Todas"
        ? "Descubre negocios y productos de nuestra región."
        : categoryInfo[selectedCategory].description;

    renderChips();
  }

  function openListing(category = "Todas", query = "") {
    selectedCategory = category;
    $("#listingSearch").value = query;
    $("#globalSearch").value = query;
    renderListing();
    showView("listing");
  }

  function productCard(business, product) {
    return `
      <article class="product-card">
        <img src="${escapeHtml(product.image)}" alt="${escapeHtml(product.name)}" loading="lazy">
        <div class="product-info">
          <h4>${escapeHtml(product.name)}</h4>
          <p>${escapeHtml(product.description)}</p>
          <div class="product-bottom">
            <span class="product-price">${money(product.price)}</span>
            <button type="button" class="add-button"
              data-action="add"
              data-business="${business.id}"
              data-product="${product.id}">+ Agregar</button>
          </div>
        </div>
      </article>`;
  }

  function openStore(businessId) {
    const business = getBusiness(businessId);

    if (!business) {
      showToast("No encontramos esa tienda.");
      return;
    }

    currentBusinessId = business.id;
    if (business.isActive === false) {
      const publicMessage = business.publicSuspensionMessage || "Esta tienda no está disponible temporalmente.";
      const supportPhone = String(business.phone || "").replace(/[^0-9]/g, "");
      const contactLink = supportPhone ? `<a class="button primary" href="https://wa.me/${supportPhone}" target="_blank" rel="noopener">Contactar al negocio</a>` : "";
      $("#storeContent").innerHTML = `<section class="info-panel" role="status"><p class="eyebrow">TIENDA NO DISPONIBLE</p><h1>${escapeHtml(business.name)}</h1><p>${escapeHtml(publicMessage)}</p><p>La tienda no puede recibir pedidos mientras permanezca suspendida.</p>${contactLink}<button type="button" class="button secondary" data-action="back-list">Volver al directorio</button></section>`;
      showView("store");
      return;
    }

    const settings = business.storeSettings || {};
    const payments = (settings.payment_methods || []).map(item => typeof item === "string" ? item : item.label).filter(Boolean);
    const delivery = (settings.delivery_options || []).map(item => typeof item === "string" ? item : item.label).filter(Boolean);
    const contentPages = business.contentPages || [];
    const publicWhatsapp = String(settings.whatsapp_number || business.phone || "").replace(/[^0-9]/g, "");
    const contactNotes = settings.contact_options?.notes || [];
    const contentPagesHtml = contentPages.map(page => {
      const fields = Array.isArray(page.content?.form_fields) ? page.content.form_fields : [];
      const customFields = page.content_type === "job_form" ? fields.map((field, index) => `<label>${escapeHtml(field)}<input name="custom_field_${index}" required maxlength="500"></label>`).join("") : "";
      return `<section class="info-panel"><h3>${escapeHtml(page.title)}</h3><p>${escapeHtml(page.body)}</p>${page.content_type === "job_form" ? `<form class="job-application-form" data-job-page="${escapeHtml(page.id)}"><label>Nombre completo<input name="applicant_name" required maxlength="120"></label><label>Teléfono o correo<input name="applicant_contact" required maxlength="180"></label>${customFields}<label>Experiencia y mensaje<textarea name="applicant_message" rows="3" maxlength="2000"></textarea></label><label><input type="checkbox" name="privacy_consent" required> Autorizo el tratamiento de mis datos para gestionar esta postulación.</label><button class="button primary" type="submit">Enviar postulación</button></form>` : ""}</section>`;
    }).join("");

    $("#storeContent").innerHTML = `
      <div class="store-hero">
        <img src="${escapeHtml(business.image)}" alt="${escapeHtml(business.name)}">
        <div class="store-hero-copy">
          <p class="eyebrow">${escapeHtml(business.category.toUpperCase())} · EJE CAFETERO</p>
          <h1>${escapeHtml(business.name)}</h1>
          <p>${escapeHtml(business.tagline)}</p>
        </div>
      </div>

      <div class="store-layout">
        <section>
          <h2 class="store-section-title">Productos de esta tienda</h2>
          <div class="product-grid">
            ${business.products.map(product => productCard(business, product)).join("")}
          </div>
        </section>

        <aside class="store-side">
          <section class="info-panel">
            <h3>Información de la tienda</h3>
            <div class="info-line"><span>📍</span><span>${escapeHtml(business.location)}</span></div>
            <div class="info-line"><span>🕒</span><span>${escapeHtml(business.hours)}</span></div>
            <div class="info-line"><span>★</span><span>Calificación de demostración: ${escapeHtml(business.rating)}/5</span></div>
            ${payments.length ? `<div class="info-line"><span>💳</span><span><strong>Pagos:</strong> ${payments.map(escapeHtml).join(", ")}</span></div>` : ""}
            ${delivery.length ? `<div class="info-line"><span>🛵</span><span><strong>Entrega:</strong> ${delivery.map(escapeHtml).join(", ")}</span></div>` : ""}
            ${publicWhatsapp ? `<div class="info-line"><span>☎</span><span><a href="https://wa.me/${publicWhatsapp}" target="_blank" rel="noopener">Contactar por WhatsApp</a></span></div>` : ""}
            ${contactNotes.map(note => `<div class="info-line"><span>ℹ</span><span>${escapeHtml(note)}</span></div>`).join("")}
          </section>
          ${contentPagesHtml}

          <section class="assistant-panel">
            <h3>Asistente de ${business.name}</h3>
            <p>Pregunta por productos, precios, horario o ubicación. Las respuestas usan los datos de demostración de esta tienda.</p>
            <div id="chatMessages" class="chat-messages">
              <div class="chat-bubble">¡Hola! Soy el asistente de ${escapeHtml(business.name)}. ¿Qué deseas saber?</div>
            </div>
            <form id="chatForm" class="chat-form">
              <input id="chatInput" name="message" required
                placeholder="Escribe tu pregunta..." autocomplete="off">
              <button type="submit" aria-label="Enviar pregunta">➤</button>
            </form>
          </section>
        </aside>
      </div>`;

    showView("store");
  }

  function cartCount() {
    return cart.reduce((total, item) => total + item.quantity, 0);
  }

  function cartTotal() {
    return cart.reduce((total, item) => total + item.price * item.quantity, 0);
  }

  function updateCart() {
    $("#cartCount").textContent = cartCount();
    $("#cartTotal").textContent = money(cartTotal());

    const paymentSelect = $("#checkoutForm select[name=payment]");
    const deliverySelect = $("#checkoutForm select[name=deliveryMethod]");
    if (!cart.length) {
      $("#cartItems").innerHTML =
        '<div class="cart-empty">Tu carrito está vacío.<br>Explora una tienda y agrega productos.</div>';
      $("#cartBusinessNote").textContent = "Agrega productos de una tienda para comenzar.";
      if (paymentSelect) paymentSelect.innerHTML = '<option value="">Selecciona una opción</option>';
      if (deliverySelect) deliverySelect.innerHTML = '<option value="">Primero selecciona productos de una tienda</option>';
      return;
    }

    const cartBusiness = getBusiness(cart[0].businessId);
    const storeSettings = cartBusiness?.storeSettings || {};
    const paymentOptions = (storeSettings.payment_methods || []).map(item => typeof item === "string" ? item : item.label).filter(Boolean);
    const deliveryOptions = (storeSettings.delivery_options || []).map(item => typeof item === "string" ? item : item.label).filter(Boolean);
    if (paymentSelect) {
      const current = paymentSelect.value;
      const choices = paymentOptions.length ? paymentOptions : ["Efectivo al recibir", "Transferencia por coordinar", "Pago en el local"];
      paymentSelect.innerHTML = '<option value="">Selecciona una opción</option>' + choices.map(item => `<option value="${escapeHtml(item)}">${escapeHtml(item)}</option>`).join("");
      if (choices.includes(current)) paymentSelect.value = current;
    }
    if (deliverySelect) {
      const current = deliverySelect.value;
      const choices = deliveryOptions.length ? deliveryOptions : ["Domicilio por coordinar", "Recoger en tienda"];
      deliverySelect.innerHTML = '<option value="">Selecciona una opción</option>' + choices.map(item => `<option value="${escapeHtml(item)}">${escapeHtml(item)}</option>`).join("");
      if (choices.includes(current)) deliverySelect.value = current;
    }

    $("#cartBusinessNote").textContent =
      `Tu pedido es de ${cart[0].businessName}. Cada pedido de demostración corresponde a una sola tienda.`;

    $("#cartItems").innerHTML = cart.map(item => `
      <div class="cart-item">
        <div>
          <strong>${item.name}</strong>
          <small>${item.businessName} · ${money(item.price)} c/u</small>
          <div class="quantity-controls">
            <button type="button" data-action="quantity" data-key="${item.key}" data-delta="-1">−</button>
            <span>${item.quantity}</span>
            <button type="button" data-action="quantity" data-key="${item.key}" data-delta="1">+</button>
            <button type="button" data-action="remove" data-key="${item.key}">✕</button>
          </div>
        </div>
        <span class="cart-item-price">${money(item.price * item.quantity)}</span>
      </div>
    `).join("");
  }

  function addToCart(businessId, productId) {
    const business = getBusiness(businessId);
    const product = getProduct(business, productId);

    if (!business || !product) {
      showToast("No se pudo agregar el producto.");
      return;
    }

    if (cart.length && cart[0].businessId !== businessId) {
      const confirmed = window.confirm(
        `Tu carrito tiene productos de ${cart[0].businessName}. ¿Quieres vaciarlo y empezar un pedido en ${business.name}?`
      );

      if (!confirmed) return;
      cart = [];
    }

    const key = `${businessId}:${productId}`;
    const existing = cart.find(item => item.key === key);

    if (existing) {
      existing.quantity++;
    } else {
      cart.push({
        key,
        businessId,
        businessName: business.name,
        productId,
        name: product.name,
        price: product.price,
        quantity: 1
      });
    }

    updateCart();
    showToast(`${product.name} agregado al carrito.`);
  }

  function openCart() {
    $("#cartBackdrop").classList.remove("hidden");
    $("#cartDrawer").classList.add("open");
    $("#cartDrawer").setAttribute("aria-hidden", "false");
  }

  function closeCart() {
    $("#cartBackdrop").classList.add("hidden");
    $("#cartDrawer").classList.remove("open");
    $("#cartDrawer").setAttribute("aria-hidden", "true");
  }

  function assistantReply(question, business) {
    const q = question.toLocaleLowerCase("es");

    if (/(hola|buenas|buenos días|buenas tardes|buenas noches)/i.test(q)) {
      return `¡Hola! Bienvenido a ${business.name}. Puedes preguntarme por productos, precios, horario o ubicación.`;
    }

    if (/(horario|abren|abierto|cierran|hora)/i.test(q)) {
      return `El horario de demostración registrado para ${business.name} es: ${business.hours}. Confirma directamente con el negocio antes de visitarlo.`;
    }

    if (/(ubicación|ubicacion|dirección|direccion|dónde|donde|queda)/i.test(q)) {
      return `La ubicación registrada es ${business.location}. Todavía no hay una dirección exacta ni un mapa conectado.`;
    }

    if (/(precio|cuánto|cuanto|cuesta|vale|valor)/i.test(q)) {
      const matches = business.products.filter(product =>
        q.includes(product.name.toLocaleLowerCase("es"))
      );

      if (matches.length) {
        return matches.map(product =>
          `${product.name}: ${money(product.price)}.`
        ).join("\n");
      }

      return `Productos y precios registrados:\n${business.products.map(product =>
        `• ${product.name}: ${money(product.price)}`
      ).join("\n")}`;
    }

    if (/(producto|venden|menú|menu|catálogo|catalogo|tienen|ofrecen)/i.test(q)) {
      return `Productos registrados en ${business.name}:\n${business.products.map(product =>
        `• ${product.name}: ${money(product.price)}`
      ).join("\n")}`;
    }

    const product = business.products.find(item =>
      q.includes(item.name.toLocaleLowerCase("es"))
    );

    if (product) {
      return `${product.name}: ${product.description} Precio de demostración: ${money(product.price)}.`;
    }

    return `Puedo responder preguntas sobre productos, precios, horario y ubicación registrada de ${business.name}. ¿Qué quieres consultar?`;
  }

  function addChatBubble(text, type = "") {
    const box = $("#chatMessages");
    if (!box) return;

    const bubble = document.createElement("div");
    bubble.className = `chat-bubble ${type}`;
    bubble.textContent = text;
    box.appendChild(bubble);
    box.scrollTop = box.scrollHeight;
  }

  const policyPages = {
    privacidad: {
      eyebrow: "TRANSPARENCIA Y CONFIANZA",
      title: "Política de privacidad",
      intro: "Esta política explica qué información podría tratar MiEje Market, para qué se usaría y cómo las personas pueden ejercer sus derechos.",
      body: `
        <div class="policy-notice"><strong>Importante:</strong> MiEje Market se encuentra en fase de prototipo. Antes de publicar una versión real, el responsable debe completar sus datos legales y revisar esta política con base en el funcionamiento definitivo del sitio. En este prototipo, el formulario de pedido no guarda ni transmite los datos.</div>
        <h2>1. Responsable del tratamiento</h2>
        <p>Responsable o razón social: <strong>[COMPLETAR NOMBRE O RAZÓN SOCIAL]</strong>. NIT o documento: <strong>[COMPLETAR SI APLICA]</strong>. Domicilio: <strong>[COMPLETAR MUNICIPIO Y DIRECCIÓN]</strong>. Correo para privacidad y consultas: <strong>[COMPLETAR CORREO DE CONTACTO]</strong>. Estos datos deben completarse antes de poner el servicio en funcionamiento.</p>
        <h2>2. Información que podría recopilarse</h2>
        <p>Cuando las funciones reales estén activas, podrían tratarse datos de contacto y entrega (nombre, teléfono y dirección), detalles de productos y pedidos, preferencias de compra y datos técnicos básicos necesarios para la seguridad y el funcionamiento. Solo se deben solicitar los datos pertinentes para cada finalidad.</p>
        <h2>3. Finalidades</h2>
        <ul><li>Atender consultas y solicitudes de las personas usuarias.</li><li>Preparar, confirmar, entregar y dar seguimiento a pedidos, cuando esta función esté habilitada.</li><li>Gestionar pagos, devoluciones, garantías y atención al cliente, según los servicios que realmente se ofrezcan.</li><li>Prevenir usos no autorizados, proteger la plataforma y cumplir obligaciones legales.</li></ul>
        <h2>4. Autorización y base legal</h2>
        <p>Cuando la ley lo exija, se solicitará autorización previa, informada y verificable antes de tratar datos personales. La autorización para el tratamiento no debe confundirse con la aceptación de publicidad opcional. En el prototipo, marcar la casilla del formulario solo permite mostrar la vista previa: no envía los datos ni crea un pedido.</p>
        <h2>5. Derechos de las personas</h2>
        <p>De acuerdo con la normativa colombiana aplicable, las personas pueden solicitar conocer, actualizar y rectificar sus datos; pedir prueba de la autorización cuando corresponda; conocer el uso dado a la información; presentar consultas o reclamos; solicitar la supresión o revocar la autorización cuando proceda; y acudir ante la Superintendencia de Industria y Comercio, una vez agotado el trámite correspondiente ante el responsable.</p>
        <h2>6. Cómo presentar una solicitud</h2>
        <p>En la versión real, las consultas o reclamos deberán enviarse al correo de privacidad indicado en la sección 1 e incluir una descripción clara de la solicitud y los datos necesarios para verificar la identidad. Se responderán dentro de los términos legales aplicables. No envíes contraseñas ni datos financieros completos por correo.</p>
        <h2>7. Compartir información</h2>
        <p>La versión real deberá explicar de forma transparente si los datos se comparten con proveedores tecnológicos, servicios de pago, logística o comercios participantes, indicando para qué y bajo qué condiciones. No se deben vender ni compartir datos para finalidades incompatibles sin una base válida y las autorizaciones que correspondan.</p>
        <h2>8. Seguridad y conservación</h2>
        <p>Se deberán aplicar medidas técnicas, administrativas y organizativas razonables para proteger la información y limitar el acceso a personas autorizadas. Los datos se conservarán solo durante el tiempo necesario para las finalidades informadas o durante los plazos exigidos por la ley. Ninguna medida de seguridad garantiza riesgo cero.</p>
        <h2>9. Cookies y tecnologías similares</h2>
        <p>Este prototipo no incorpora un panel de consentimiento de cookies. Antes de añadir analítica, publicidad o herramientas de terceros, se deberá identificar qué tecnologías se usan, qué información recopilan y cómo puede gestionarlas la persona usuaria.</p>
        <h2>10. Menores de edad</h2>
        <p>El servicio no debe recopilar datos de niños, niñas o adolescentes sin cumplir las garantías y requisitos especiales previstos por la normativa aplicable y priorizar su interés superior.</p>
        <h2>11. Cambios</h2>
        <p>La política podrá actualizarse cuando cambien el servicio o las obligaciones legales. La versión publicada deberá mostrar la fecha de actualización y explicar los cambios relevantes.</p>
        <p><strong>Marco de referencia:</strong> Constitución Política de Colombia, artículo 15; Ley 1581 de 2012 y sus normas reglamentarias, junto con las demás disposiciones aplicables. Este texto es una base de trabajo y no constituye certificación de cumplimiento legal.</p>`
    },
    datos: {
      eyebrow: "TUS DATOS, TUS DERECHOS",
      title: "Tratamiento de datos personales",
      intro: "Información sobre la autorización, las finalidades y los canales para ejercer los derechos relacionados con los datos personales.",
      body: `
        <div class="policy-notice"><strong>Antes de activar la plataforma:</strong> completa la identidad y el contacto del responsable y verifica que el aviso corresponda a las funciones, proveedores y bases de datos que se usarán realmente.</div>
        <h2>1. Responsable</h2>
        <p>Nombre o razón social: <strong>[COMPLETAR]</strong>. NIT o documento: <strong>[COMPLETAR SI APLICA]</strong>. Dirección: <strong>[COMPLETAR]</strong>. Correo para consultas y reclamos: <strong>[COMPLETAR]</strong>.</p>
        <h2>2. Datos y usos previstos</h2>
        <p>Según las funciones que se activen, se podrán tratar datos de identificación y contacto, información de entrega, detalles de pedidos, solicitudes de soporte y datos técnicos de seguridad. Se utilizarán únicamente para las finalidades informadas en la Política de privacidad y para las obligaciones legales correspondientes.</p>
        <h2>3. Autorización</h2>
        <p>Cuando corresponda, la autorización se solicitará antes de iniciar el tratamiento, de manera clara, informada y demostrable. Las casillas no deben estar marcadas previamente. Las finalidades opcionales, como comunicaciones promocionales, deben distinguirse de las necesarias para gestionar un pedido.</p>
        <h2>4. Derechos</h2>
        <ul><li>Consultar los datos personales que se estén tratando.</li><li>Solicitar la actualización o corrección de datos incompletos, inexactos o desactualizados.</li><li>Solicitar información sobre la autorización y el uso de los datos.</li><li>Presentar reclamos y, cuando proceda, solicitar supresión de datos o revocación de la autorización.</li><li>Acudir a la Superintendencia de Industria y Comercio en los términos de la ley.</li></ul>
        <h2>5. Canal y procedimiento</h2>
        <p>Envía la solicitud a <strong>[COMPLETAR CORREO DE PRIVACIDAD]</strong> con el asunto “Consulta de datos personales” o “Reclamo de datos personales”. Describe la solicitud y aporta la información estrictamente necesaria para verificar tu identidad. El responsable deberá gestionar las consultas y reclamos dentro de los plazos legales aplicables.</p>
        <h2>6. Seguridad y terceros</h2>
        <p>El responsable deberá controlar los accesos, proteger las bases de datos y establecer acuerdos apropiados con proveedores que traten información por su cuenta. Antes de operar, se deben identificar los proveedores reales de alojamiento, pagos, mensajería, analítica y logística, si los hay.</p>
        <h2>7. Estado del prototipo</h2>
        <p>Actualmente, el pedido es una demostración: el formulario muestra una vista previa mediante una alerta del navegador y no almacena ni envía la información a un servidor. Si en el futuro se conectan bases de datos, correos, WhatsApp, pagos u otros servicios, esta sección deberá actualizarse antes de activar esas funciones.</p>
        <p><strong>Marco de referencia:</strong> Ley 1581 de 2012 y normas reglamentarias aplicables en Colombia. Esta página es informativa y debe validarse antes del lanzamiento comercial.</p>`
    },
    terminos: {
      eyebrow: "CONDICIONES DE USO",
      title: "Términos y condiciones",
      intro: "Reglas generales para consultar el prototipo MiEje Market y para una futura operación comercial. Las condiciones definitivas deben corresponder al modelo de negocio real.",
      body: `
        <div class="policy-notice"><strong>Prototipo:</strong> los negocios, productos, precios, calificaciones y horarios que aparecen en esta versión son datos de demostración. No representan una oferta comercial real ni confirman disponibilidad.</div>
        <h2>1. Identificación del operador</h2>
        <p>Operador: <strong>[COMPLETAR NOMBRE O RAZÓN SOCIAL]</strong>. NIT o documento: <strong>[COMPLETAR SI APLICA]</strong>. Domicilio y contacto: <strong>[COMPLETAR]</strong>. No se debe publicar la versión comercial hasta completar estos datos y revisar las obligaciones aplicables.</p>
        <h2>2. Alcance del servicio</h2>
        <p>MiEje Market presenta una vitrina digital de productos y negocios de la región. En este prototipo, la navegación, el carrito y el formulario son demostrativos. No se reciben pagos, no se confirma una compra y no se genera un pedido real.</p>
        <h2>3. Información de productos y precios</h2>
        <p>Antes de una operación real, la información deberá ser clara, verificable y actualizada, incluyendo precio total, características relevantes, disponibilidad, costos de envío, tiempos de entrega, restricciones y datos del vendedor o proveedor cuando aplique. Las imágenes ilustrativas deben identificarse cuando puedan generar confusión.</p>
        <h2>4. Pedidos y pagos</h2>
        <p>En la versión actual, el botón “Revisar pedido” solo presenta una vista previa local y no guarda ni envía la información. En una versión comercial se deberán explicar los pasos para confirmar el pedido, los medios de pago disponibles, cuándo se entiende celebrado el contrato, cómo se entrega el comprobante y cómo se gestionan errores o cancelaciones.</p>
        <h2>5. Entregas, cambios, garantías y retracto</h2>
        <p>Antes de vender, el operador debe publicar reglas claras y legalmente revisadas sobre cobertura y costo de domicilios, tiempos estimados, productos defectuosos, garantías, devoluciones, cancelaciones, derecho de retracto cuando aplique y excepciones legales. Estas reglas no pueden eliminar los derechos mínimos que reconoce la normativa de protección al consumidor.</p>
        <h2>6. Uso aceptable</h2>
        <p>Las personas usuarias deben utilizar el sitio de forma lícita, no intentar acceder sin autorización a sus sistemas, no interferir con su funcionamiento y no publicar información engañosa o de terceros sin autorización.</p>
        <h2>7. Propiedad intelectual</h2>
        <p>Los elementos gráficos, textos, marcas y contenidos deben usarse respetando los derechos de sus titulares. Los comercios que aporten contenido deberán contar con los permisos necesarios para su publicación.</p>
        <h2>8. Privacidad</h2>
        <p>El tratamiento de datos personales se rige por la Política de privacidad y el aviso de Tratamiento de datos personales. Antes de activar funciones que almacenen o transmitan datos, se deberá informar el flujo real de la información y solicitar las autorizaciones necesarias.</p>
        <h2>9. Cambios y contacto</h2>
        <p>Las condiciones comerciales definitivas deberán indicar cómo se notifican cambios y cómo contactar al operador: <strong>[COMPLETAR CORREO Y CANAL DE ATENCIÓN]</strong>. La versión final debe mostrar su fecha de vigencia.</p>
        <p><strong>Marco de referencia:</strong> Ley 1480 de 2011 (Estatuto del Consumidor) y demás normas colombianas aplicables al comercio electrónico. Este borrador no reemplaza una revisión jurídica del modelo comercial concreto.</p>`
    }
  };

  let previousView = "home";

  function openPolicy(policyKey) {
    const page = policyPages[policyKey];
    if (!page) return;
    previousView = !$("#policyView").classList.contains("hidden") ? previousView :
      (!$("#storeView").classList.contains("hidden") ? "store" :
      (!$("#listingView").classList.contains("hidden") ? "listing" : "home"));
    $("#policyContent").innerHTML = `
      <header class="policy-hero">
        <p class="eyebrow">${page.eyebrow}</p>
        <h1>${page.title}</h1>
        <p>${page.intro}</p>
      </header>
      <article class="policy-content">${page.body}</article>`;
    showView("policy");
  }

  // Delegación global: también funciona con tarjetas creadas dinámicamente.
  document.addEventListener("click", event => {
    const policyButton = event.target.closest("[data-policy]");
    if (policyButton) {
      openPolicy(policyButton.dataset.policy);
      return;
    }

    const categoryButton = event.target.closest("[data-category]");

    if (categoryButton) {
      openListing(categoryButton.dataset.category);
      return;
    }

    const filterButton = event.target.closest("[data-filter]");

    if (filterButton) {
      selectedCategory = filterButton.dataset.filter;
      renderListing();
      return;
    }

    const actionButton = event.target.closest("[data-action]");

    if (actionButton) {
      const action = actionButton.dataset.action;

      if (action === "home") {
        showView("home");
        $("#globalSearch").value = "";
      }

      if (action === "categories") {
        showView("home");
        $("#categoriesSection").scrollIntoView({ behavior: "smooth" });
      }

      if (action === "businesses") {
        openListing("Todas");
      }

      if (action === "open-store") {
        openStore(actionButton.dataset.business);
      }

      if (action === "back-list") {
        openListing(selectedCategory);
      }

      if (action === "policy-back") {
        if (previousView === "listing") openListing(selectedCategory);
        else if (previousView === "store" && currentBusinessId) openStore(currentBusinessId);
        else showView("home");
      }

      if (action === "add") {
        addToCart(actionButton.dataset.business, actionButton.dataset.product);
      }

      if (action === "quantity") {
        const item = cart.find(entry => entry.key === actionButton.dataset.key);

        if (item) {
          item.quantity += Number(actionButton.dataset.delta);

          if (item.quantity <= 0) {
            cart = cart.filter(entry => entry.key !== item.key);
          }

          updateCart();
        }
      }

      if (action === "remove") {
        cart = cart.filter(entry => entry.key !== actionButton.dataset.key);
        updateCart();
      }

      return;
    }

    if (event.target.closest("#openCart")) openCart();

    if (
      event.target.closest("#closeCart") ||
      event.target.closest("#cartBackdrop")
    ) {
      closeCart();
    }

    if (event.target.closest("#mobileMenu")) {
      $("#mainNav").classList.toggle("open");
    }
  });

  $("#globalSearch").addEventListener("keydown", event => {
    if (event.key === "Enter") {
      openListing("Todas", event.currentTarget.value);
    }
  });

  $("#globalSearch").addEventListener("search", event => {
    openListing("Todas", event.currentTarget.value);
  });

  $("#listingSearch").addEventListener("input", renderListing);

  $("#storeContent").addEventListener("submit", async event => {
    const jobForm = event.target.closest(".job-application-form");
    if (jobForm) {
      event.preventDefault();
      const business = getBusiness(currentBusinessId);
      if (!business || !window.supabase || !window.MIEJE_SUPABASE_URL || !window.MIEJE_SUPABASE_PUBLISHABLE_KEY) { showToast("No se pudo enviar la postulación en este momento."); return; }
      const client = window.supabase.createClient(window.MIEJE_SUPABASE_URL, window.MIEJE_SUPABASE_PUBLISHABLE_KEY);
      const formData = new FormData(jobForm);
      const applicationData = Object.fromEntries([...formData.entries()].filter(([key]) => key.startsWith("custom_field_")).map(([key, value]) => [key, String(value).trim()]));
      const { error } = await client.from("job_applications").insert({ business_id: business.id, content_page_id: jobForm.dataset.jobPage, applicant_name: String(formData.get("applicant_name")||"").trim(), applicant_contact: String(formData.get("applicant_contact")||"").trim(), applicant_message: String(formData.get("applicant_message")||"").trim(), application_data: applicationData });
      if (error) { showToast("No se pudo guardar la postulación. Intenta más tarde."); console.warn("job application submit failed", error); return; }
      jobForm.reset(); showToast("Postulación enviada correctamente."); return;
    }
    if (event.target.id !== "chatForm") return;

    event.preventDefault();

    const input = $("#chatInput");
    const question = input.value.trim();
    const business = getBusiness(currentBusinessId);

    if (!question || !business) return;

    addChatBubble(question, "user");
    input.value = "";
    addChatBubble(assistantReply(question, business));
  });

  $("#checkoutForm").addEventListener("submit", event => {
    event.preventDefault();

    if (!cart.length) {
      showToast("Primero agrega productos al carrito.");
      return;
    }

    const form = new FormData(event.currentTarget);

    const summary = cart.map(item =>
      `${item.quantity} × ${item.name} — ${money(item.price * item.quantity)}`
    ).join("\n");

    window.alert(
      `PEDIDO DE DEMOSTRACIÓN\n\n` +
      `Tienda: ${cart[0].businessName}\n\n${summary}\n\n` +
      `Total estimado: ${money(cartTotal())}\n` +
      `Nombre: ${form.get("customerName")}\n` +
      `Teléfono: ${form.get("phone")}\n` +
      `Entrega: ${form.get("deliveryMethod")}\n` +
      `Dirección: ${form.get("address")}\n` +
      `Pago: ${form.get("payment")}\n\n` +
      `Este pedido no se ha guardado ni enviado.`
    );

    showToast("Vista previa lista. El pedido no se envió ni se guardó.");
  });

  document.addEventListener("keydown", event => {
    if (event.key === "Escape") closeCart();
  });

  loadRegisteredBusinesses().finally(() => {
    renderFeatured();
    renderListing();
    updateCart();
  });
})();
