import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.75.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, payload: Record<string, unknown>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function textValue(value: unknown, max = 500): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply(405, { error: "Método no permitido." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return reply(500, { error: "El servidor no está configurado correctamente." });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "La solicitud no contiene JSON válido." });
  }

  if (textValue(body.website, 300)) {
    return reply(400, { error: "No se pudo validar la solicitud." });
  }

  const businessId = textValue(body.business_id, 80);
  const customerName = textValue(body.customer_name, 160);
  const customerPhone = textValue(body.customer_phone, 50);
  const customerEmail = textValue(body.customer_email, 254);
  const deliveryAddress = textValue(body.delivery_address, 500);
  const deliveryNotes = textValue(body.delivery_notes, 1000);
  const paymentMethodId = textValue(body.payment_method_id, 80);
  const idempotencyKey = textValue(body.idempotency_key, 80);
  const items = body.items;

  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(businessId)
      || !customerName || !customerPhone || !deliveryAddress
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(paymentMethodId)
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(idempotencyKey)
      || !Array.isArray(items) || items.length < 1 || items.length > 30) {
    return reply(400, { error: "Completa los datos del domicilio y revisa los productos del pedido." });
  }

  const ip = (req.headers.get("cf-connecting-ip")
    ?? req.headers.get("x-forwarded-for")?.split(",")[0]
    ?? "").trim();
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // Leer también métodos desactivados: un reintento idempotente debe poder
    // recuperar un pedido ya creado aunque el negocio haya desactivado el método.
    const { data: enabledMethod, error: methodError } = await admin.from("business_payment_methods")
      .select("id,method_code,display_name,is_enabled")
      .eq("id", paymentMethodId)
      .eq("business_id", businessId)
      .maybeSingle();
    if (methodError) {
      console.error("Payment method validation failed:", methodError);
      return reply(503, { error: "No fue posible validar la forma de pago." });
    }
    if (!enabledMethod) {
      return reply(409, { error: "Esta forma de pago ya no está disponible. Actualiza el carrito e inténtalo de nuevo." });
    }

    const paymentMethod = enabledMethod.method_code;
    const paymentMethodLabel = enabledMethod.display_name;
    const finalDeliveryNotes = [deliveryNotes, `Forma de pago seleccionada: ${paymentMethodLabel}`].filter(Boolean).join(" | ").slice(0, 1000);

    const normalizedItems = items.map((item: any) => ({
      product_id: textValue(item?.product_id, 80),
      quantity: Number(item?.quantity),
    }));

    if (normalizedItems.some((item: any) =>
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(item.product_id)
      || !Number.isInteger(item.quantity) || item.quantity < 1 || item.quantity > 99
    )) {
      return reply(400, { error: "Hay un producto o una cantidad inválidos." });
    }

    const requestArgs = {
      p_idempotency_key: idempotencyKey,
      p_business_id: businessId,
      p_payment_method_id: paymentMethodId,
      p_customer_user_id: null as string | null,
      p_customer_name: customerName,
      p_customer_phone: customerPhone,
      p_customer_email: customerEmail || null,
      p_delivery_address: deliveryAddress,
      p_delivery_notes: finalDeliveryNotes || null,
      p_payment_method: paymentMethod,
      p_items: normalizedItems,
    };

    // Recuperar primero un pedido ya confirmado: los reintentos no consumen
    // nuevamente el límite de solicitudes por IP.
    let customerUserId: string | null = null;
    const authorization = req.headers.get("authorization") || "";
    const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
    const publicKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || "";
    if (bearer && bearer !== publicKey) {
      const { data: authData, error: authError } = await admin.auth.getUser(bearer);
      if (authError || !authData.user) {
        return reply(401, { error: "La sesión del cliente no es válida. Inicia sesión nuevamente." });
      }
      const { data: profile, error: profileError } = await admin.from("profiles")
        .select("is_blocked")
        .eq("id", authData.user.id)
        .maybeSingle();
      if (profileError) {
        console.error("Customer profile validation failed:", profileError);
        return reply(503, { error: "No fue posible validar la cuenta del cliente." });
      }
      if (!profile) {
        return reply(403, { error: "La cuenta no tiene un perfil válido para realizar pedidos." });
      }
      if (profile.is_blocked === true) {
        return reply(403, { error: "Esta cuenta no puede realizar pedidos. Contacta al soporte de MiEje Market." });
      }
      customerUserId = authData.user.id;
    }

    requestArgs.p_customer_user_id = customerUserId;

    const { data: previousOrder, error: lookupError } = await admin.rpc(
      "get_public_order_idempotent",
      requestArgs
    );
    if (lookupError) {
      console.error("Checkout idempotency lookup failed:", lookupError);
      const message = lookupError.message.toLowerCase();
      if (message.includes("clave de este intento ya fue usada")) return reply(409, { error: lookupError.message });
      return reply(503, { error: "No fue posible verificar el intento de compra." });
    }
    if (previousOrder) return reply(200, { ok: true, order: previousOrder });

    // La función SQL idempotente aplica el límite dentro de la misma
    // transacción y solo para una clave nueva. No consumirlo también aquí.
    if (enabledMethod.is_enabled !== true) {
      return reply(409, { error: "Esta forma de pago ya no está habilitada. Selecciona otra forma de pago." });
    }

    if (!ip) {
      return reply(400, { error: "No fue posible validar el origen de la solicitud. Inténtalo nuevamente." });
    }

    const { data, error } = await admin.rpc("create_public_order_idempotent", {
      ...requestArgs,
      p_ip: ip,
    });

    if (error) {
      console.error("Order creation failed:", error);
      const message = error.message.toLowerCase();
      if (message.includes("demasiadas solicitudes") || message.includes("validar el origen")) return reply(429, { error: error.message });
      if (message.includes("clave de este intento ya fue usada")) return reply(409, { error: error.message });
      if (message.includes("inventario") || message.includes("producto no está disponible") || message.includes("negocio no está disponible")) {
        return reply(409, { error: error.message });
      }
      if (message.includes("valor mínimo")) return reply(409, { error: error.message });
      if (message.includes("datos del pedido") || message.includes("cantidad") || message.includes("repite")) {
        return reply(400, { error: error.message });
      }
      return reply(400, { error: "No se pudo crear el pedido. Revisa los datos y vuelve a intentarlo." });
    }

    return reply(201, { ok: true, order: data });
  } catch (error) {
    console.error("create-public-order error:", error);
    return reply(500, { error: "Ocurrió un error al registrar el pedido." });
  }
});
