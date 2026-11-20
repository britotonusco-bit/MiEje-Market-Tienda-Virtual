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
      "Content-Type": "application/json",
      "Cache-Control": "no-store, private",
      "Pragma": "no-cache",
    },
  });
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply(405, { error: "Método no permitido." });

  const authorization = req.headers.get("Authorization") ?? "";
  const accessToken = authorization.replace(/^Bearer\s+/i, "").trim();
  if (!accessToken) return reply(401, { error: "La sesión de invitación no está disponible." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const publicKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!supabaseUrl || !serviceKey || !publicKey) {
    return reply(500, { error: "Falta configuración segura del servidor." });
  }

  let body: Record<string, unknown>;
  try {
    const rawBody = await req.text();
    if (new TextEncoder().encode(rawBody).byteLength > 16384) {
      return reply(413, { error: "La solicitud supera el tamaño permitido." });
    }
    const parsed: unknown = JSON.parse(rawBody);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return reply(400, { error: "El cuerpo de la solicitud debe ser un objeto JSON." });
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return reply(400, { error: "El cuerpo de la solicitud no es JSON válido." });
  }

  const invitationId = typeof body.invitation_id === "string" ? body.invitation_id.trim() : "";
  const rawInvitationToken = typeof body.invitation_token === "string" ? body.invitation_token : "";
  const password = typeof body.password === "string" ? body.password : "";
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidPattern.test(invitationId)
      || !/^[A-Za-z0-9_-]{43}$/.test(rawInvitationToken)
      || password.length < 10
      || password.length > 128) {
    return reply(400, { error: "La invitación o la contraseña no cumplen los requisitos." });
  }

  const userClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser(accessToken);
  const user = authData?.user;
  if (authError || !user) return reply(401, { error: "La sesión no es válida o ha vencido." });
  if (!user.email || !user.email_confirmed_at) {
    return reply(403, { error: "Primero debes verificar el correo de la invitación." });
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: invitation, error: invitationError } = await admin
    .from("business_invitations")
    .select("id,business_id,user_id,email_normalized,status,token_hash,expires_at,membership_id")
    .eq("id", invitationId)
    .maybeSingle();

  if (invitationError) {
    console.error("Invitation lookup failed:", invitationError);
    return reply(503, { error: "No fue posible validar la invitación. Inténtalo de nuevo." });
  }
  if (!invitation) return reply(404, { error: "La invitación no existe o ya no está disponible." });

  const suppliedHash = await sha256Hex(rawInvitationToken);
  if (invitation.status !== "pending"
      || invitation.user_id !== user.id
      || invitation.email_normalized !== user.email.toLowerCase()
      || !constantTimeEqual(invitation.token_hash, suppliedHash)) {
    return reply(403, { error: "La invitación no corresponde a esta cuenta o ya fue utilizada/revocada." });
  }

  if (Date.parse(invitation.expires_at) <= Date.now()) {
    const { error: expireError } = await admin.rpc("expire_business_invitation", {
      p_invitation_id: invitationId,
    });
    if (expireError) console.error("Invitation expiry update failed:", expireError);
    return reply(410, { error: "La invitación venció. Solicita al propietario técnico que genere una nueva." });
  }

  // La contraseña se establece desde el servidor. Si la RPC posterior falla,
  // la membresía sigue suspendida y el mismo enlace permite reintentar.
  const { error: passwordError } = await admin.auth.admin.updateUserById(user.id, { password });
  if (passwordError) {
    console.error("Invitation password update failed:", passwordError);
    return reply(400, { error: "No se pudo guardar la contraseña. Verifica los requisitos e inténtalo de nuevo." });
  }

  const { data: accepted, error: acceptError } = await admin.rpc("accept_business_invitation", {
    p_invitation_id: invitationId,
    p_user_id: user.id,
    p_token_hash: suppliedHash,
  });

  if (acceptError) {
    console.error("Invitation acceptance RPC failed:", acceptError);
    return reply(503, {
      error: "La contraseña quedó guardada, pero no se pudo finalizar el acceso al negocio. La membresía continúa bloqueada; vuelve a intentar con el mismo enlace.",
      retryable: true,
    });
  }

  if (!accepted?.ok || accepted.status !== "accepted") {
    return reply(410, { error: "La invitación venció o dejó de estar disponible. Solicita una nueva invitación." });
  }

  return reply(200, {
    ok: true,
    invitation_id: invitationId,
    business_id: invitation.business_id,
    membership_id: accepted.membership_id,
    status: "accepted",
  });
});
