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
  if (!supabaseUrl || !serviceKey) return reply(500, { error: "Falta configuración segura del servidor." });

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await admin.from("platform_public_settings")
    .select("site_name,site_description,logo_url,hero_image_url,support_whatsapp")
    .eq("id", true).maybeSingle();

  if (error) {
    console.error("get-platform-public-settings:", error);
    return reply(500, { error: "No fue posible cargar la configuración pública de MiEje Market." });
  }
  return reply(200, { ok: true, settings: data ?? {
    site_name: "MiEje Market",
    site_description: "",
    logo_url: null,
    hero_image_url: null,
    support_whatsapp: null,
  } });
});
