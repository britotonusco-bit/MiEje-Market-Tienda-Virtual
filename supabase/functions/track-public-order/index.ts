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
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store, private, max-age=0",
      "Pragma": "no-cache",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: {
      ...corsHeaders,
      "Cache-Control": "no-store, max-age=0",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
    },
  });
  if (req.method !== "POST") return reply(405, { error: "Método no permitido." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return reply(500, { error: "El servidor no está configurado correctamente." });

  let body: Record<string, unknown>;
  try {
    const rawBody = await req.text();
    if (new TextEncoder().encode(rawBody).byteLength > 2048) {
      return reply(413, { error: "La solicitud supera el tamaño permitido." });
    }
    const parsed: unknown = JSON.parse(rawBody);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return reply(400, { error: "La solicitud no contiene un objeto JSON válido." });
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return reply(400, { error: "La solicitud no contiene JSON válido." });
  }

  const token = typeof body.token === "string" ? body.token.trim() : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)) {
    return reply(400, { error: "El código de seguimiento no es válido." });
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await admin
    .from("orders")
    .select("order_number,status,created_at,updated_at,delivery_tracking,businesses(name)")
    .eq("public_tracking_token", token)
    .maybeSingle();

  if (error) {
    console.error("track-public-order query failed:", error);
    return reply(500, { error: "No fue posible consultar el pedido en este momento." });
  }
  if (!data) return reply(404, { error: "No encontramos un pedido con ese código de seguimiento." });

  const business = Array.isArray(data.businesses) ? data.businesses[0] : data.businesses;
  const allowedStatuses = new Set([
    "received", "confirmed", "preparing", "ready", "on_the_way", "delivered", "cancelled",
  ]);
  if (typeof data.status !== "string" || !allowedStatuses.has(data.status)) {
    console.error("track-public-order returned an unsupported order status.");
    return reply(500, { error: "El estado del pedido no está disponible en este momento." });
  }

  // Este campo es texto operativo introducido por el negocio y se muestra
  // públicamente al titular del código. Limpiar controles y limitar longitud;
  // el panel también advierte que no debe incluir datos personales.
  const trackingReference = typeof data.delivery_tracking === "string"
    ? data.delivery_tracking.replace(/[\\u0000-\\u001f\\u007f]/g, " ").trim().slice(0, 500) || null
    : null;

  return reply(200, {
    order: {
      order_number: data.order_number,
      status: data.status,
      created_at: data.created_at,
      updated_at: data.updated_at,
      delivery_tracking: trackingReference,
      business_name: typeof business?.name === "string" ? business.name.slice(0, 160) : null,
    },
  });
});
