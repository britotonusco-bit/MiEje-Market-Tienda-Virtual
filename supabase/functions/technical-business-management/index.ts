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

async function findUserByEmail(admin: any, email: string) {
  for (let page = 1; page <= 20; page++) {
    const result = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (result.error) throw result.error;
    const users = result.data?.users ?? [];
    const found = users.find((item: any) => (item.email ?? "").toLowerCase() === email.toLowerCase());
    if (found) return { user: found, complete: true };
    if (users.length < 1000) return { user: null, complete: true };
  }

  // No asumir que el correo no existe si se alcanzó el límite de páginas.
  return { user: null, complete: false };
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

  const authorization = req.headers.get("Authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "").trim();
  if (!token) return reply(401, { error: "Debes iniciar sesión." });

  const userClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user) return reply(401, { error: "Sesión inválida o vencida." });

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("id, platform_role, is_blocked")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError || !profile || profile.is_blocked) {
    return reply(403, { error: "El perfil no existe o está bloqueado." });
  }

  let body: Record<string, unknown>;
  try {
    const rawBody = await req.text();
    if (new TextEncoder().encode(rawBody).byteLength > 65536) {
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

  const action = textValue(body.action, 60);
  const isOwner = profile.platform_role === "platform_owner";

  // El propietario necesita completar MFA antes de usar cualquier acción técnica.
  // getAuthenticatorAssuranceLevel(jwt) valida el token y consulta el nivel real de Auth.
  if (isOwner) {
    const { data: assurance, error: assuranceError } =
      await userClient.auth.mfa.getAuthenticatorAssuranceLevel(token);
    if (assuranceError) {
      return reply(401, { error: "No fue posible validar el nivel de seguridad de la sesión." });
    }
    if (assurance?.currentLevel !== "aal2") {
      return reply(403, {
        code: "MFA_REQUIRED",
        error: "Debes completar la verificación en dos pasos para usar el panel técnico.",
      });
    }
  }

  try {
    if (action === "log_login") {
      const panel = textValue(body.panel, 30);
      const businessId = textValue(body.business_id, 80) || null;
      if (!["technical", "business_admin", "employee"].includes(panel)) {
        return reply(400, { error: "Tipo de panel no válido." });
      }

      if (panel === "technical") {
        if (!isOwner) return reply(403, { error: "Este usuario no tiene acceso al panel técnico." });
      } else {
        if (!businessId) return reply(400, { error: "Falta el negocio para registrar el acceso." });
        const expectedRole = panel;
        const { data: membership, error: membershipError } = await admin
          .from("business_memberships")
          .select("id, role, status, business_id")
          .eq("business_id", businessId)
          .eq("user_id", user.id)
          .maybeSingle();

        if (membershipError || !membership || membership.status !== "active" || membership.role !== expectedRole) {
          return reply(403, { error: "No tienes permiso para entrar a este panel." });
        }

        const { data: business, error: businessError } = await admin
          .from("businesses")
          .select("id,status")
          .eq("id", businessId)
          .maybeSingle();
        if (businessError) throw businessError;
        if (!business || business.status !== "active") {
          return reply(403, { error: "El negocio no está activo. No se puede registrar un acceso válido al panel." });
        }
      }

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: panel === "technical" ? null : businessId,
        actor_id: user.id,
        action: "panel.login",
        entity_type: "panel_session",
        entity_id: user.id,
        details: { panel, source: "server_verified_session" },
      });
      if (auditError) throw auditError;
      return reply(200, { ok: true, message: "Acceso registrado." });
    }

    if (!isOwner) return reply(403, { error: "Solo el administrador técnico puede realizar esta acción." });

    if (action === "list_platform_finance") {
      const [financeResult, payrollResult] = await Promise.all([
        admin.from("platform_financial_records")
          .select("id,business_id,record_type,description,amount,currency,occurred_at,reference,created_at")
          .order("occurred_at", { ascending: false }).limit(100),
        admin.from("payroll_records")
          .select("id,business_id,payee_name,description,amount,currency,status,due_date,paid_at,payment_reference,created_at,updated_at")
          .order("created_at", { ascending: false }).limit(100),
      ]);
      if (financeResult.error) throw financeResult.error;
      if (payrollResult.error) throw payrollResult.error;
      return reply(200, {
        ok: true,
        financial_records: financeResult.data ?? [],
        payroll_records: payrollResult.data ?? [],
      });
    }

    if (action === "create_platform_financial_record") {
      const recordType = textValue(body.record_type, 20);
      const description = textValue(body.description, 500);
      const amount = Number(body.amount);
      const currency = (textValue(body.currency, 3) || "COP").toUpperCase();
      const reference = textValue(body.reference, 160) || null;
      const businessId = textValue(body.business_id, 80) || null;
      const occurredAtInput = textValue(body.occurred_at, 40);
      const allowedTypes = ["income", "expense", "refund", "adjustment"];
      if (!allowedTypes.includes(recordType)) return reply(400, { error: "Tipo de movimiento no válido." });
      if (description.length < 3 || !Number.isFinite(amount) || amount <= 0) {
        return reply(400, { error: "La descripción debe tener al menos 3 caracteres y el importe debe ser mayor que cero." });
      }
      if (!/^[A-Z]{3}$/.test(currency)) return reply(400, { error: "La moneda debe usar un código de tres letras, por ejemplo COP." });
      if (businessId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(businessId)) {
        return reply(400, { error: "Identificador de negocio no válido." });
      }
      if (occurredAtInput && Number.isNaN(Date.parse(occurredAtInput))) {
        return reply(400, { error: "La fecha del movimiento no es válida." });
      }
      const occurredAt = occurredAtInput ? new Date(occurredAtInput).toISOString() : new Date().toISOString();
      const { data, error } = await admin.rpc("create_platform_financial_record_transactional", {
        p_business_id: businessId,
        p_record_type: recordType,
        p_description: description,
        p_amount: amount,
        p_currency: currency,
        p_occurred_at: occurredAt,
        p_reference: reference,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "23503") return reply(404, { error: "El negocio indicado no existe." });
        if (error.code === "42501") return reply(403, { error: "La cuenta técnica no está autorizada para registrar movimientos." });
        if (error.code === "22023") return reply(400, { error: "Los datos del movimiento financiero no son válidos." });
        console.error("Platform financial record RPC failed:", error);
        throw error;
      }
      const result = data as Record<string, any> | null;
      if (!result?.record) throw new Error("La RPC financiera no devolvió el movimiento.");
      return reply(201, { ok: true, record: result.record });
    }

    if (action === "create_payroll_record") {
      const payeeName = textValue(body.payee_name, 160);
      const description = textValue(body.description, 500);
      const amount = Number(body.amount);
      const currency = (textValue(body.currency, 3) || "COP").toUpperCase();
      const businessId = textValue(body.business_id, 80) || null;
      const dueDate = textValue(body.due_date, 10) || null;
      if (payeeName.length < 2 || description.length < 3 || !Number.isFinite(amount) || amount <= 0) {
        return reply(400, { error: "Beneficiario, descripción e importe son obligatorios; el importe debe ser mayor que cero." });
      }
      if (!/^[A-Z]{3}$/.test(currency)) return reply(400, { error: "La moneda debe usar un código de tres letras, por ejemplo COP." });
      if (businessId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(businessId)) {
        return reply(400, { error: "Identificador de negocio no válido." });
      }
      if (dueDate) {
        const parsedDueDate = new Date(dueDate + "T00:00:00.000Z");
        if (!/^\d{4}-\d{2}-\d{2}$/.test(dueDate) || Number.isNaN(parsedDueDate.getTime()) || parsedDueDate.toISOString().slice(0, 10) !== dueDate) {
          return reply(400, { error: "La fecha límite no es válida." });
        }
      }
      const { data, error } = await admin.rpc("create_platform_payroll_record_transactional", {
        p_business_id: businessId,
        p_payee_name: payeeName,
        p_description: description,
        p_amount: amount,
        p_currency: currency,
        p_due_date: dueDate,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "23503") return reply(404, { error: "El negocio indicado no existe." });
        if (error.code === "42501") return reply(403, { error: "La cuenta técnica no está autorizada para crear registros de nómina." });
        if (error.code === "22023") return reply(400, { error: "Los datos del registro de nómina no son válidos." });
        console.error("Platform payroll creation RPC failed:", error);
        throw error;
      }
      const result = data as Record<string, any> | null;
      if (!result?.record) throw new Error("La RPC de nómina no devolvió el registro.");
      return reply(201, { ok: true, record: result.record });
    }

    if (action === "resolve_payroll_record") {
      const recordId = textValue(body.record_id, 80);
      const decision = textValue(body.decision, 20);
      const paymentReference = textValue(body.payment_reference, 160) || null;
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(recordId)) {
        return reply(400, { error: "Identificador de nómina no válido." });
      }
      if (!["paid", "cancelled"].includes(decision)) return reply(400, { error: "Estado de nómina no válido." });
      const { data, error } = await admin.rpc("resolve_platform_payroll_record", {
        p_record_id: recordId,
        p_decision: decision,
        p_payment_reference: paymentReference,
        p_actor_id: user.id,
      });
      if (error) {
        const message = error.message || "No se pudo resolver el registro de nómina.";
        if (message.includes("ya fue resuelto")) return reply(409, { error: message });
        if (message.includes("no existe")) return reply(404, { error: message });
        throw error;
      }
      return reply(200, {
        ok: true,
        record: data?.payroll ?? null,
        financial_record_id: data?.financial_record_id ?? null,
        message: decision === "paid"
          ? "Pago marcado en el control interno y gasto financiero registrado de forma conjunta."
          : "Registro de nómina cancelado.",
      });
    }

    if (action === "get_platform_public_settings") {
      const { data, error } = await admin.from("platform_public_settings")
        .select("site_name,site_description,logo_url,hero_image_url,support_whatsapp,updated_at")
        .eq("id", true).maybeSingle();
      if (error) throw error;
      return reply(200, { ok: true, settings: data ?? {} });
    }

    if (action === "get_platform_ai_settings") {
      const { data, error } = await admin.from("platform_ai_settings")
        .select("enabled,assistant_name,system_instructions,updated_at")
        .eq("id", true).maybeSingle();
      if (error) throw error;
      return reply(200, { ok: true, settings: data ?? {
        enabled: false,
        assistant_name: "Asistente general de MiEje Market",
        system_instructions: "",
      } });
    }

    if (action === "update_platform_ai_settings") {
      if (typeof body.enabled !== "boolean") {
        return reply(400, { error: "Indica si la configuración del asistente general estará habilitada." });
      }
      const assistantName = textValue(body.assistant_name, 120);
      const instructions = textValue(body.system_instructions, 8000);
      if (assistantName.length < 2) {
        return reply(400, { error: "El nombre del asistente debe tener al menos dos caracteres." });
      }
      const { data, error } = await admin.rpc("update_platform_ai_settings_transactional", {
        p_enabled: body.enabled,
        p_assistant_name: assistantName,
        p_system_instructions: instructions,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "42501") return reply(403, { error: "La cuenta técnica no está autorizada para modificar esta configuración." });
        if (error.code === "22023") return reply(400, { error: "Los datos de configuración de IA no son válidos." });
        console.error("Platform AI settings RPC failed:", error);
        throw error;
      }
      const result = data as Record<string, any> | null;
      if (!result?.settings) throw new Error("La RPC de configuración de IA no devolvió los ajustes.");
      return reply(200, {
        ok: true,
        settings: result.settings,
        message: "Configuración del asistente general guardada. Esto no activa por sí solo un proveedor de IA.",
      });
    }

    if (action === "update_platform_public_settings") {
      const siteName = textValue(body.site_name, 120);
      const siteDescription = textValue(body.site_description, 2000);
      const logoUrl = textValue(body.logo_url, 2048);
      const heroImageUrl = textValue(body.hero_image_url, 2048);
      const supportWhatsapp = textValue(body.support_whatsapp, 30).replace(/[^0-9]/g, "").slice(0, 18);
      const validImageUrl = (value: string) => {
        if (!value) return true;
        try { return new URL(value).protocol === "https:"; } catch { return false; }
      };
      if (!siteName || !validImageUrl(logoUrl) || !validImageUrl(heroImageUrl) || (supportWhatsapp && supportWhatsapp.length < 10)) {
        return reply(400, { error: "Revisa el nombre, las direcciones HTTPS de las imágenes y el número de WhatsApp." });
      }
      const { data, error } = await admin.rpc("update_platform_public_settings_transactional", {
        p_site_name: siteName,
        p_site_description: siteDescription,
        p_logo_url: logoUrl || null,
        p_hero_image_url: heroImageUrl || null,
        p_support_whatsapp: supportWhatsapp || null,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "42501") return reply(403, { error: "La cuenta técnica no está autorizada para modificar la configuración pública." });
        if (error.code === "22023") return reply(400, { error: "Los datos de configuración pública no son válidos." });
        console.error("Platform public settings RPC failed:", error);
        throw error;
      }
      const result = data as Record<string, any> | null;
      if (!result?.settings) throw new Error("La RPC de configuración pública no devolvió los ajustes.");
      return reply(200, { ok: true, settings: result.settings, message: "Configuración pública de MiEje Market guardada." });
    }

    if (action === "list_businesses") {
      const { data, error } = await admin.from("businesses")
        .select("id,name,slug,category,status,suspension_reason,public_suspension_message,created_at")
        .order("created_at", { ascending: false });
      if (error) throw error;
      return reply(200, { ok: true, businesses: data ?? [] });
    }

    if (action === "list_audit_logs") {
      const businessId = textValue(body.business_id, 80);
      const limitValue = Number(body.limit ?? 100);
      const limit = Number.isInteger(limitValue) ? Math.min(Math.max(limitValue, 1), 500) : 100;
      let query = admin.from("audit_logs")
        .select("id,business_id,actor_id,action,entity_type,entity_id,details,created_at", { count: "exact" })
        .order("created_at", { ascending: false })
        .limit(limit);
      if (businessId) query = query.eq("business_id", businessId);
      const { data, error, count } = await query;
      if (error) throw error;

      const actorIds = [...new Set((data ?? []).map((row: any) => row.actor_id).filter(Boolean))];
      const actorNames = new Map<string, string>();
      if (actorIds.length) {
        const { data: profiles, error: profilesError } = await admin.from("profiles")
          .select("id,display_name")
          .in("id", actorIds);
        if (profilesError) throw profilesError;
        for (const profile of profiles ?? []) {
          actorNames.set(profile.id, profile.display_name ?? "");
        }
      }
      const auditLogs = (data ?? []).map((row: any) => ({
        ...row,
        actor_name: actorNames.get(row.actor_id) || null,
      }));
      return reply(200, { ok: true, audit_logs: auditLogs, audit_count: count ?? auditLogs.length });
    }

    if (action === "list_content_moderation") {
      const limitValue = Number(body.limit ?? 100);
      const limit = Number.isInteger(limitValue) ? Math.min(Math.max(limitValue, 1), 100) : 100;
      const { data, error } = await admin.from("business_content_pages")
        .select("id,business_id,content_type,title,body,is_published,moderation_status,created_at,businesses(name)")
        .order("created_at", { ascending: false })
        .limit(limit);
      if (error) throw error;
      return reply(200, { ok: true, contents: data ?? [] });
    }

    if (action === "list_business_members") {
      const businessId = textValue(body.business_id, 80);
      if (!businessId) return reply(400, { error: "Falta el identificador del negocio." });
      const { data, error } = await admin.from("business_memberships")
        .select("id,business_id,user_id,role,status,job_title,blocked_reason,created_at,profiles(display_name,avatar_url,phone)")
        .eq("business_id", businessId)
        .order("created_at", { ascending: false });
      if (error) throw error;
      const members = await Promise.all((data ?? []).map(async (membership: any) => {
        const { data: authUser } = await admin.auth.admin.getUserById(membership.user_id);
        return { ...membership, email: authUser?.user?.email ?? null };
      }));
      return reply(200, { ok: true, members });
    }

    if (action === "create_business") {
      const name = textValue(body.name, 160);
      const category = textValue(body.category, 100);
      let slug = textValue(body.slug, 120).toLowerCase();
      if (!slug && name) {
        slug = name.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
          .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 110);
      }
      if (name.length < 2 || category.length < 2 || !slug || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) {
        return reply(400, { error: "Nombre, categoría y slug válido son obligatorios." });
      }

      // El panel técnico crea únicamente el registro base. La configuración
      // comercial queda a cargo del administrador de ese negocio.
      const { data, error } = await admin.rpc("create_technical_business_transactional", {
        p_name: name,
        p_category: category,
        p_slug: slug,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "23505") return reply(409, { error: "Ya existe un negocio con ese slug." });
        if (error.code === "42501") return reply(403, { error: "La cuenta técnica no está autorizada para crear negocios." });
        if (error.code === "22023") return reply(400, { error: "Nombre, categoría o slug no válido." });
        console.error("Transactional business creation failed:", error);
        throw error;
      }

      const result = data as Record<string, any> | null;
      if (!result?.business) throw new Error("La RPC de creación no devolvió el negocio.");
      return reply(201, { ok: true, business: result.business });
    }

    if (action === "invite_member") {
      const businessId = textValue(body.business_id, 80);
      const email = textValue(body.email, 254).toLowerCase();
      const role = textValue(body.role, 40);
      const displayName = textValue(body.display_name, 160);
      const jobTitle = textValue(body.job_title, 100) || (role === "business_admin" ? "Administrador del negocio" : "");
      const redirectTo = "https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/aceptar-invitacion.html";

      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(businessId)
          || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
          || !["business_admin", "employee"].includes(role)
          || displayName.length < 3
          || jobTitle.length < 2) {
        return reply(400, { error: "Negocio, nombre completo, correo, rol y cargo válido son obligatorios." });
      }

      const { data: business, error: businessError } = await admin
        .from("businesses").select("id, name, status").eq("id", businessId).maybeSingle();
      if (businessError) throw businessError;
      if (!business) return reply(404, { error: "El negocio no existe." });
      if (business.status !== "active") {
        return reply(409, { error: "No se pueden asignar usuarios a un negocio suspendido o cerrado." });
      }

      const lookup = await findUserByEmail(admin, email);
      if (!lookup.complete && !lookup.user) {
        return reply(503, {
          error: "No se pudo completar la búsqueda de la cuenta. No se envió ningún correo ni se asignó acceso. Inténtalo más tarde o revisa el usuario desde Auth.",
        });
      }

      let targetUser = lookup.user;
      let invitationSent = false;

      if (!targetUser) {
        const { data: inviteData, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
          data: { display_name: displayName },
          redirectTo,
        });
        if (inviteError) {
          console.error("inviteUserByEmail failed:", inviteError);
          return reply(502, {
            error: "Supabase no confirmó el envío. No se creó la asignación. Si Auth alcanzó a crear la cuenta, vuelve a intentar: se detectará como existente y se podrá reenviar la confirmación.",
            invitation_sent: false,
          });
        }
        targetUser = inviteData?.user ?? null;
        invitationSent = true;
      }

      if (!targetUser?.id) {
        return reply(502, {
          error: "Auth no devolvió el identificador de la cuenta. No se creó la asignación.",
          invitation_sent: invitationSent,
        });
      }

      // Una cuenta preexistente sin correo confirmado no debe recibir una
      // membresía nueva. El alta de cuentas nuevas sigue el flujo de invitación.
      // No se intenta reenviar un enlace automáticamente: requiere un flujo
      // explícito y limitado de reenvío desde Auth.
      if (lookup.user && !targetUser.email_confirmed_at) {
        return reply(409, {
          error: "La cuenta ya existe, pero su correo todavía no está confirmado. El usuario debe completar la verificación de correo antes de que se le asigne acceso a este negocio.",
          invitation_sent: false,
          requires_email_confirmation: true,
          assignment_created: false,
        });
      }

      // La RPC comprueba el bloqueo global, el negocio activo, la membresía
      // duplicada y registra la membresía junto con su auditoría atómicamente.
      // El trigger on_auth_user_created ya crea profiles para usuarios nuevos.
      const { data, error } = await admin.rpc("create_business_membership_assignment", {
        p_business_id: businessId,
        p_user_id: targetUser.id,
        p_role: role,
        p_job_title: jobTitle,
        p_display_name: displayName,
        p_actor_id: user.id,
        p_invitation_sent: invitationSent,
      });

      if (error) {
        if (error.code === "P0002") return reply(404, { error: "No se encontró el negocio.", invitation_sent: invitationSent });
        if (error.code === "42501") return reply(403, { error: "La cuenta técnica no está autorizada o el usuario de destino tiene un bloqueo global.", invitation_sent: invitationSent });
        if (error.code === "23503") return reply(409, { error: "La cuenta de Auth existe, pero no tiene un perfil asociado. No se asignó acceso; requiere revisión técnica.", invitation_sent: invitationSent });
        if (error.code === "23514") return reply(409, { error: error.message, invitation_sent: invitationSent });
        if (error.code === "22023") return reply(400, { error: "Los datos de la asignación no son válidos.", invitation_sent: invitationSent });
        console.error("Business membership assignment RPC failed:", error);
        return reply(503, {
          error: invitationSent
            ? "El correo fue enviado, pero la asignación no pudo finalizarse. No vuelvas a crear otra cuenta: reintenta la misma asignación para completar el acceso."
            : "No se pudo completar la asignación. No se modificó la membresía ni su auditoría.",
          invitation_sent: invitationSent,
          retryable: true,
        });
      }

      const result = data as Record<string, any> | null;
      if (!result?.membership) throw new Error("La RPC de asignación no devolvió la membresía.");
      const requiresEmailConfirmation = !targetUser.email_confirmed_at;
      if (result.already_assigned) {
        return reply(409, {
          error: result.membership.status === "active"
            ? "Ese usuario ya tiene acceso a este negocio."
            : "Ese usuario ya tiene una asignación suspendida. Reactiva su acceso desde la gestión de usuarios.",
          membership: result.membership,
          invitation_sent: invitationSent,
          requires_email_confirmation: requiresEmailConfirmation,
        });
      }

      return reply(201, {
        ok: true,
        membership: result.membership,
        invitation_sent: invitationSent,
        requires_email_confirmation: requiresEmailConfirmation,
        message: invitationSent
          ? "Correo de invitación enviado y acceso asignado."
          : requiresEmailConfirmation
            ? "Asignación creada. La cuenta todavía debe confirmar su correo antes de poder iniciar sesión; no se envió otro mensaje."
            : "Cuenta existente asignada al negocio.",
      });
    }

    if (action === "update_member_assignment") {
      const membershipId = textValue(body.membership_id, 80);
      const role = textValue(body.role, 40);
      const jobTitle = textValue(body.job_title, 100);
      if (!membershipId || !["business_admin", "employee"].includes(role) || jobTitle.length < 2) {
        return reply(400, { error: "Selecciona una membresía, un rol válido y un cargo de al menos dos caracteres." });
      }

      const { data, error } = await admin.rpc("update_business_membership_assignment", {
        p_membership_id: membershipId,
        p_role: role,
        p_job_title: jobTitle,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "P0002") return reply(404, { error: "No se encontró la membresía." });
        if (error.code === "42501") return reply(403, { error: "La operación no está autorizada para esta cuenta o el usuario de destino está bloqueado." });
        if (error.code === "23514" || error.code === "40001") return reply(409, { error: error.message });
        if (error.code === "22023") return reply(400, { error: "Los datos del rol o cargo no son válidos." });
        console.error("Membership assignment RPC failed:", error);
        throw error;
      }

      const result = data as Record<string, any> | null;
      if (!result?.membership) throw new Error("La RPC de asignación no devolvió la membresía actualizada.");
      return reply(200, {
        ok: true,
        membership: result.membership,
        message: result.unchanged
          ? "El rol y el cargo ya tenían esos valores."
          : "Rol y cargo actualizados y registrados en auditoría.",
      });
    }

    if (action === "set_business_status") {
      const businessId = textValue(body.business_id, 80);
      const status = textValue(body.status, 30);
      const reason = textValue(body.reason, 2000);
      const publicMessage = textValue(body.public_message, 1000);
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(businessId)
          || !["active", "suspended", "closed"].includes(status)) {
        return reply(400, { error: "Negocio y estado válido son obligatorios." });
      }
      if (status === "suspended" && !reason) return reply(400, { error: "Indica el motivo de la suspensión." });

      const { data, error } = await admin.rpc("set_technical_business_status", {
        p_business_id: businessId,
        p_status: status,
        p_reason: reason,
        p_public_message: publicMessage,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "P0002") return reply(404, { error: "No se encontró el negocio." });
        if (error.code === "42501") return reply(403, { error: "La operación no está autorizada para esta cuenta." });
        if (error.code === "22023") return reply(400, { error: "Los datos del estado o del motivo no son válidos." });
        console.error("Business status RPC failed:", error);
        throw error;
      }

      const result = data as Record<string, any> | null;
      if (!result?.business) throw new Error("La RPC de estado no devolvió el negocio actualizado.");
      return reply(200, {
        ok: true,
        business: result.business,
        message: result.unchanged
          ? "El negocio ya tenía ese estado y esos datos."
          : "Estado del negocio actualizado y registrado en auditoría.",
      });
    }

    if (action === "block_member") {
      const membershipId = textValue(body.membership_id, 80);
      const reason = textValue(body.reason, 2000);
      if (!membershipId || !reason) return reply(400, { error: "La membresía y el motivo son obligatorios." });

      const { data, error } = await admin.rpc("suspend_business_membership", {
        p_membership_id: membershipId,
        p_reason: reason,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "P0002") return reply(404, { error: "No se encontró la membresía o su negocio." });
        if (error.code === "42501") return reply(403, { error: "La operación no está autorizada para esta cuenta." });
        if (error.code === "23514" || error.code === "40001") return reply(409, { error: error.message });
        if (error.code === "22023") return reply(400, { error: "La membresía y un motivo válido son obligatorios." });
        console.error("Membership suspension RPC failed:", error);
        throw error;
      }

      const result = data as Record<string, any> | null;
      if (!result?.membership) throw new Error("La RPC de suspensión no devolvió la membresía.");
      return reply(200, {
        ok: true,
        membership: result.membership,
        message: result.already_suspended
          ? "La cuenta ya estaba suspendida en este negocio."
          : "Acceso suspendido y registrado en auditoría.",
      });
    }

    if (action === "unblock_member") {
      const membershipId = textValue(body.membership_id, 80);
      const reason = textValue(body.reason, 2000);
      if (!membershipId || reason.length < 5) {
        return reply(400, { error: "La membresía y un motivo de reactivación son obligatorios." });
      }

      const { data, error } = await admin.rpc("reactivate_business_membership", {
        p_membership_id: membershipId,
        p_reason: reason,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "P0002") return reply(404, { error: "No se encontró la membresía o su negocio." });
        if (error.code === "42501") return reply(403, { error: "La cuenta no está autorizada para esta operación o el usuario de destino está bloqueado." });
        if (error.code === "23514" || error.code === "40001") return reply(409, { error: error.message });
        if (error.code === "22023") return reply(400, { error: "El motivo de reactivación debe tener al menos cinco caracteres." });
        console.error("Membership reactivation RPC failed:", error);
        throw error;
      }

      const result = data as Record<string, any> | null;
      if (!result?.membership) throw new Error("La RPC de reactivación no devolvió la membresía.");
      return reply(200, {
        ok: true,
        membership: result.membership,
        message: result.already_active
          ? "La cuenta ya tenía acceso activo."
          : "Acceso reactivado y registrado en auditoría.",
      });
    }

    if (action === "moderate_business_content") {
      const contentId = textValue(body.content_id, 80);
      const decision = textValue(body.decision, 20);
      const moderationNote = textValue(body.moderation_note, 2000);
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(contentId)
          || !["approved", "rejected"].includes(decision)) {
        return reply(400, { error: "Publicación y decisión válida son obligatorias." });
      }

      const { data, error } = await admin.rpc("moderate_business_content_transactionally", {
        p_content_id: contentId,
        p_decision: decision,
        p_moderation_note: moderationNote,
        p_actor_id: user.id,
      });
      if (error) {
        if (error.code === "P0002") return reply(404, { error: "No se encontró la publicación." });
        if (error.code === "42501") return reply(403, { error: "La operación no está autorizada para esta cuenta." });
        if (error.code === "22023") return reply(400, { error: "Los datos de moderación no son válidos." });
        console.error("Business content moderation RPC failed:", error);
        throw error;
      }

      const result = data as Record<string, any> | null;
      if (!result?.content) throw new Error("La RPC de moderación no devolvió el contenido actualizado.");
      return reply(200, {
        ok: true,
        content: result.content,
        message: result.unchanged
          ? "La publicación ya tenía esa decisión de moderación."
          : decision === "approved"
            ? "Publicación aprobada y registrada en auditoría."
            : "Publicación rechazada, retirada de la vista pública y registrada en auditoría.",
      });
    }

    if (action === "list_block_requests") {
      if (!isOwner) return reply(403, { error: "Solo el propietario técnico puede consultar estas solicitudes." });
      const { data: requests, error: requestError } = await admin
        .from("access_block_requests")
        .select("id,business_id,requested_by,target_user_id,reason,status,technician_note,resolved_by,resolved_at,created_at,businesses(name)")
        .order("created_at", { ascending: false })
        .limit(100);
      if (requestError) throw requestError;

      const userIds = [...new Set((requests ?? []).flatMap((request: any) =>
        [request.requested_by, request.target_user_id].filter(Boolean)
      ))];
      const { data: profiles, error: profilesError } = userIds.length
        ? await admin.from("profiles").select("id,display_name").in("id", userIds)
        : { data: [], error: null };
      if (profilesError) throw profilesError;
      const names = new Map((profiles ?? []).map((profile: any) => [profile.id, profile.display_name]));

      return reply(200, {
        ok: true,
        requests: (requests ?? []).map((request: any) => ({
          ...request,
          requested_by_name: names.get(request.requested_by) ?? null,
          target_user_name: names.get(request.target_user_id) ?? null,
        })),
      });
    }

    if (action === "resolve_block_request") {
      if (!isOwner) return reply(403, { error: "Solo el propietario técnico puede resolver estas solicitudes." });
      const requestId = textValue(body.request_id, 80);
      const decision = textValue(body.decision, 20);
      const technicianNote = textValue(body.technician_note, 2000);
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId)
          || !["approved", "rejected"].includes(decision)) {
        return reply(400, { error: "Solicitud y decisión válida son obligatorias." });
      }

      const { data: result, error: resolveError } = await admin.rpc("resolve_access_block_request", {
        p_request_id: requestId,
        p_decision: decision,
        p_technician_note: technicianNote,
        p_technician_id: user.id,
      });
      if (resolveError) {
        console.error("Access block request resolution failed:", resolveError);
        const message = resolveError.message || "No se pudo resolver la solicitud.";
        const status = resolveError.code === "42501"
          ? 403
          : resolveError.code === "22023"
            ? 400
            : ["P0002", "40001", "23505"].includes(resolveError.code ?? "")
              || /no se encontró|ya fue resuelta|último administrador|membresía activa|cambió durante|negocio de la solicitud ya no existe/i.test(message)
                ? 409
                : 400;
        return reply(status, { error: message });
      }

      return reply(200, {
        ok: true,
        result,
        message: decision === "approved"
          ? "Solicitud aprobada. Se suspendió el acceso de esa cuenta únicamente en el negocio indicado."
          : "Solicitud rechazada. El acceso de la cuenta no fue modificado.",
      });
    }

    return reply(400, { error: "Acción no reconocida." });
  } catch (error) {
    console.error("technical-business-management error:", error);
    return reply(500, { error: "La operación no pudo completarse. Revisa los registros de la función." });
  }
});
