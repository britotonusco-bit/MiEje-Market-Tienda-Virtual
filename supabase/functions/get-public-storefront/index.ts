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

  let body: Record<string, unknown>;
  try { body = await req.json(); }
  catch { return reply(400, { error: "Solicitud inválida." }); }

  const ids = body.business_ids;
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > 200 ||
      ids.some(id => typeof id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))) {
    return reply(400, { error: "Lista de negocios inválida." });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(500, { error: "El servidor no está configurado correctamente." });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: businesses, error: businessError } = await admin.from("businesses")
    .select("id,status")
    .in("id", ids)
    .eq("status", "active");
  if (businessError) return reply(503, { error: "No se pudo consultar la tienda." });

  const activeIds = (businesses || []).map(row => row.id);
  if (!activeIds.length) return reply(200, { ok: true, payment_methods: [] });

  const { data, error } = await admin.from("business_payment_methods")
    .select("id,business_id,method_code,display_name,public_instructions,sort_order")
    .in("business_id", activeIds)
    .eq("is_enabled", true)
    .order("sort_order", { ascending: true });
  if (error) return reply(503, { error: "No se pudieron consultar las formas de pago." });

  return reply(200, {
    ok: true,
    payment_methods: (data || []).map(method => ({
      id: method.id,
      business_id: method.business_id,
      method_code: method.method_code,
      display_name: method.display_name,
      public_instructions: method.public_instructions || null,
      sort_order: method.sort_order,
    })),
  });
});
