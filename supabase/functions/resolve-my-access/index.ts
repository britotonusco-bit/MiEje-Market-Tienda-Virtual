import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.119.0";

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
  const publicKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!supabaseUrl || !serviceKey || !publicKey) {
    return reply(500, { error: "Falta configuración segura del servidor." });
  }

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return reply(401, { error: "Debes iniciar sesión." });

  const userClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user) return reply(401, { error: "La sesión no es válida o ha vencido." });

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("id, display_name, avatar_url, platform_role, is_blocked")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError) {
    console.error("resolve-my-access profile query:", profileError);
    return reply(500, { error: "No fue posible verificar el perfil." });
  }
  if (!profile || profile.is_blocked) return reply(403, { error: "El perfil no existe o está bloqueado." });

  const { data: memberships, error: membershipError } = await admin
    .from("business_memberships")
    .select("id, business_id, role, status, job_title, businesses(id, name, slug, status)")
    .eq("user_id", user.id)
    .order("created_at", { ascending: true });

  if (membershipError) {
    console.error("resolve-my-access memberships query:", membershipError);
    return reply(500, { error: "No fue posible consultar los negocios asignados." });
  }

  const activeMemberships = (memberships ?? []).filter((membership: any) => {
    const business = Array.isArray(membership.businesses) ? membership.businesses[0] : membership.businesses;
    return membership.status === "active" && business?.status === "active";
  }).map((membership: any) => {
    const business = Array.isArray(membership.businesses) ? membership.businesses[0] : membership.businesses;
    return {
      membership_id: membership.id,
      business_id: membership.business_id,
      role: membership.role,
      panel_name: membership.role === "business_admin" ? "Panel de administrador" : "Panel de empleados",
      role_label: membership.role === "business_admin" ? "Administrador del negocio" : "Empleado",
      job_title: membership.job_title ?? null,
      business: business ? { id: business.id, name: business.name, slug: business.slug } : null,
    };
  }).filter((membership: any) => membership.business !== null);

  return reply(200, {
    ok: true,
    user: { id: user.id, email: user.email ?? null },
    profile: { id: profile.id, display_name: profile.display_name ?? null, avatar_url: profile.avatar_url ?? null, platform_role: profile.platform_role ?? null, panel_name: profile.platform_role === "platform_owner" ? "Panel técnico superior" : "Panel de cliente" },
    is_platform_owner: profile.platform_role === "platform_owner",
    memberships: activeMemberships,
  });
});
