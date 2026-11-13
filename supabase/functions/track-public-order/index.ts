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

  const token = typeof body.token === "string" ? body.token.trim() : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)) {
    return reply(400, { error: "El código de seguimiento no es válido." });
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await admin
    .from("orders")
    .select("order_number,status,created_at,updated_at,delivery_tracking,total,businesses(name)")
    .eq("public_tracking_token", token)
    .maybeSingle();

  if (error) {
    console.error("track-public-order query failed:", error);
    return reply(500, { error: "No fue posible consultar el pedido en este momento." });
  }
  if (!data) return reply(404, { error: "No encontramos un pedido con ese código de seguimiento." });

  const business = Array.isArray(data.businesses) ? data.businesses[0] : data.businesses;
  return reply(200, {
    order: {
      order_number: data.order_number,
      status: data.status,
      created_at: data.created_at,
      updated_at: data.updated_at,
      delivery_tracking: data.delivery_tracking,
      total: data.total,
      business_name: business?.name ?? null,
    },
  });
});
