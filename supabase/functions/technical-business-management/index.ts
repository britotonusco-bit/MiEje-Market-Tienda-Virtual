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
    if (found) return found;
    if (users.length < 1000) break;
  }
  return null;
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
    body = await req.json();
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
      }

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: panel === "technical" ? null : businessId,
        actor_id: user.id,
        action: "panel.login",
        entity_type: "panel_session",
        entity_id: user.id,
        details: { panel, email: user.email ?? null, source: "server_verified_session" },
      });
      if (auditError) throw auditError;
      return reply(200, { ok: true, message: "Acceso registrado." });
    }

    if (!isOwner) return reply(403, { error: "Solo el administrador técnico puede realizar esta acción." });

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
        .select("id,business_id,actor_id,action,entity_type,entity_id,details,created_at")
        .order("created_at", { ascending: false })
        .limit(limit);
      if (businessId) query = query.eq("business_id", businessId);
      const { data, error } = await query;
      if (error) throw error;
      return reply(200, { ok: true, audit_logs: data ?? [] });
    }

    if (action === "list_business_members") {
      const businessId = textValue(body.business_id, 80);
      if (!businessId) return reply(400, { error: "Falta el identificador del negocio." });
      const { data, error } = await admin.from("business_memberships")
        .select("id,business_id,user_id,role,status,blocked_reason,created_at,profiles(display_name,phone)")
        .eq("business_id", businessId)
        .order("created_at", { ascending: false });
      if (error) throw error;
      return reply(200, { ok: true, members: data ?? [] });
    }

    if (action === "create_business") {
      const name = textValue(body.name, 160);
      const category = textValue(body.category, 100);
      let slug = textValue(body.slug, 120).toLowerCase();
      if (!slug && name) {
        slug = name.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
          .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 110);
      }
      if (!name || !category || !slug || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) {
        return reply(400, { error: "Nombre, categoría y slug válido son obligatorios." });
      }

      // El panel técnico crea únicamente el registro base del negocio.
      // La descripción, horarios, logo, contacto, pagos y demás datos comerciales
      // se configuran después desde el panel de su administrador.
      const { data: business, error: createError } = await admin.from("businesses").insert({
        name,
        category,
        slug,
        created_by: user.id,
      }).select("id, name, slug, category, status, created_at").single();

      if (createError) {
        if (createError.code === "23505") return reply(409, { error: "Ya existe un negocio con ese slug." });
        throw createError;
      }

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: business.id,
        actor_id: user.id,
        action: "business.created",
        entity_type: "business",
        entity_id: business.id,
        details: { name: business.name, slug: business.slug },
      });
      // El negocio ya fue creado. No responder como si la creación hubiera
      // fallado si únicamente falló el registro de auditoría: eso provocaría
      // reintentos engañosos y errores de slug duplicado.
      if (auditError) {
        console.error("Business created but audit insert failed:", auditError);
        return reply(201, {
          ok: true,
          business,
          audit_warning: "El negocio se creó, pero no se pudo guardar su evento de auditoría. Revisa los registros del servidor.",
        });
      }
      return reply(201, { ok: true, business });
    }

    if (action === "invite_member") {
      const businessId = textValue(body.business_id, 80);
      const email = textValue(body.email, 254).toLowerCase();
      const role = textValue(body.role, 40);
      const displayName = textValue(body.display_name, 160);
      if (!businessId || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !["business_admin", "employee"].includes(role)) {
        return reply(400, { error: "Negocio, correo válido y rol permitido son obligatorios." });
      }

      const { data: business, error: businessError } = await admin
        .from("businesses").select("id, name, status").eq("id", businessId).maybeSingle();
      if (businessError || !business) return reply(404, { error: "El negocio no existe." });
      if (business.status !== "active") return reply(409, { error: "No se pueden asignar usuarios a un negocio suspendido o cerrado." });

      let targetUser = await findUserByEmail(admin, email);

      // Si el usuario ya existe, comprobar la membresía antes de enviar
      // cualquier correo o modificar su perfil. Así evitamos invitaciones
      // duplicadas cuando ya tiene acceso al mismo negocio.
      if (targetUser?.id) {
        const { data: existingMembership, error: existingMembershipError } = await admin.from("business_memberships")
          .select("id, role, status")
          .eq("business_id", businessId)
          .eq("user_id", targetUser.id)
          .maybeSingle();
        if (existingMembershipError) throw existingMembershipError;
        if (existingMembership) {
          return reply(409, {
            error: existingMembership.status === "active"
              ? "Ese usuario ya tiene acceso activo a este negocio."
              : "Ese usuario ya tiene una asignación suspendida. Reactiva su acceso desde la gestión de usuarios.",
          });
        }
      }

      let invitationSent = false;
      if (!targetUser) {
        const { data: inviteData, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
          data: displayName ? { display_name: displayName } : {},
          redirectTo: "https://britotonusco-bit.github.io/MiEje-Market-Tienda-Virtual/aceptar-invitacion.html",
        });
        if (inviteError) {
          console.error("inviteUserByEmail failed:", inviteError);
          return reply(502, {
            error: "Supabase no confirmó el envío de la invitación. No se asignó el acceso. Revisa la configuración de correo y el estado del usuario antes de volver a intentarlo."
          });
        }
        targetUser = inviteData.user;
        invitationSent = true;
      }

      if (!targetUser?.id) return reply(500, { error: "Supabase no devolvió el usuario de destino." });

      const { error: profileUpsertError } = await admin.from("profiles").upsert({
        id: targetUser.id,
        display_name: displayName || null,
      }, { onConflict: "id", ignoreDuplicates: true });
      if (profileUpsertError) throw profileUpsertError;

      const { data: membership, error: membershipError } = await admin.from("business_memberships").insert({
        business_id: businessId,
        user_id: targetUser.id,
        role,
        status: "active",
        created_by: user.id,
      }).select("id, business_id, user_id, role, status").single();
      if (membershipError) {
        if (membershipError.code === "23505") {
          return reply(409, { error: "Ese usuario ya recibió acceso a este negocio. Actualiza la lista de cuentas." });
        }
        throw membershipError;
      }

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: businessId,
        actor_id: user.id,
        action: "business.member_invited",
        entity_type: "business_membership",
        entity_id: membership.id,
        details: { target_user_id: targetUser.id, role, invitation_sent: invitationSent },
      });
      if (auditError) throw auditError;

      return reply(201, {
        ok: true,
        membership,
        invitation_sent: invitationSent,
        message: invitationSent ? "Invitación enviada al correo." : "Usuario existente asignado al negocio.",
      });
    }

    if (action === "set_business_status") {
      const businessId = textValue(body.business_id, 80);
      const status = textValue(body.status, 30);
      const reason = textValue(body.reason, 2000);
      const publicMessage = textValue(body.public_message, 1000);
      if (!businessId || !["active", "suspended", "closed"].includes(status)) {
        return reply(400, { error: "Negocio y estado válido son obligatorios." });
      }
      if (status === "suspended" && !reason) return reply(400, { error: "Indica el motivo de la suspensión." });

      const { data: business, error: updateError } = await admin.from("businesses").update({
        status,
        suspension_reason: status === "suspended" ? reason : null,
        public_suspension_message: status === "suspended" ? (publicMessage || "Este negocio está temporalmente suspendido.") : null,
      }).eq("id", businessId).select("id, name, slug, status, suspension_reason, public_suspension_message").maybeSingle();

      if (updateError) throw updateError;
      if (!business) return reply(404, { error: "El negocio no existe." });

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: businessId,
        actor_id: user.id,
        action: "business.status_changed",
        entity_type: "business",
        entity_id: businessId,
        details: { new_status: status, reason: status === "suspended" ? reason : null },
      });
      if (auditError) throw auditError;
      return reply(200, { ok: true, business });
    }

    if (action === "block_member") {
      const membershipId = textValue(body.membership_id, 80);
      const reason = textValue(body.reason, 2000);
      if (!membershipId || !reason) return reply(400, { error: "La membresía y el motivo son obligatorios." });

      const { data: before, error: readError } = await admin.from("business_memberships")
        .select("id,business_id,user_id,role,status")
        .eq("id", membershipId)
        .maybeSingle();
      if (readError) throw readError;
      if (!before) return reply(404, { error: "No se encontró esa asignación de usuario." });
      if (before.status === "suspended") {
        return reply(200, { ok: true, membership: before, message: "La cuenta ya estaba suspendida en este negocio." });
      }

      if (before.role === "business_admin") {
        const { count, error: adminsError } = await admin.from("business_memberships")
          .select("id", { count: "exact", head: true })
          .eq("business_id", before.business_id)
          .eq("role", "business_admin")
          .eq("status", "active");
        if (adminsError) throw adminsError;
        if ((count ?? 0) <= 1) {
          return reply(409, { error: "No se puede suspender al último administrador activo del negocio. Asigna primero otro administrador." });
        }
      }

      const { data: membership, error: updateError } = await admin.from("business_memberships").update({
        status: "suspended",
        blocked_reason: reason,
      }).eq("id", membershipId).eq("status", "active")
        .select("id, business_id, user_id, role, status").maybeSingle();

      if (updateError) throw updateError;
      if (!membership) return reply(409, { error: "El acceso cambió mientras se procesaba la solicitud. Actualiza la lista e inténtalo de nuevo." });

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: membership.business_id,
        actor_id: user.id,
        action: "business.member_suspended",
        entity_type: "business_membership",
        entity_id: membership.id,
        details: { target_user_id: membership.user_id, role: membership.role, reason },
      });
      if (auditError) throw auditError;
      return reply(200, { ok: true, membership });
    }

    if (action === "unblock_member") {
      const membershipId = textValue(body.membership_id, 80);
      const reason = textValue(body.reason, 2000);
      if (!membershipId || reason.length < 5) {
        return reply(400, { error: "La membresía y un motivo de reactivación son obligatorios." });
      }

      const { data: before, error: readError } = await admin.from("business_memberships")
        .select("id,business_id,user_id,role,status,businesses(status)")
        .eq("id", membershipId)
        .maybeSingle();
      if (readError) throw readError;
      if (!before) return reply(404, { error: "No se encontró esa asignación de usuario." });
      const business = Array.isArray(before.businesses) ? before.businesses[0] : before.businesses;
      if (business?.status !== "active") {
        return reply(409, { error: "Primero debes reactivar el negocio. La cuenta no puede acceder a un negocio suspendido o cerrado." });
      }
      if (before.status === "active") {
        return reply(200, { ok: true, membership: before, message: "La cuenta ya tenía acceso activo." });
      }

      const { data: membership, error: updateError } = await admin.from("business_memberships").update({
        status: "active",
        blocked_reason: null,
      }).eq("id", membershipId).select("id,business_id,user_id,role,status").maybeSingle();
      if (updateError) throw updateError;
      if (!membership) return reply(404, { error: "No se encontró esa asignación de usuario." });

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: membership.business_id,
        actor_id: user.id,
        action: "business.member_reactivated",
        entity_type: "business_membership",
        entity_id: membership.id,
        details: { target_user_id: membership.user_id, role: membership.role, reason },
      });
      if (auditError) throw auditError;
      return reply(200, { ok: true, membership, message: "Acceso reactivado y registrado en auditoría." });
    }

    if (action === "moderate_business_content") {
      const contentId = textValue(body.content_id, 80);
      const decision = textValue(body.decision, 20);
      const moderationNote = textValue(body.moderation_note, 2000);
      if (!contentId || !["approved", "rejected"].includes(decision)) {
        return reply(400, { error: "Publicación y decisión válida son obligatorias." });
      }
      const { data: current, error: readError } = await admin
        .from("business_content_pages")
        .select("id,business_id,title,content_type,moderation_status")
        .eq("id", contentId)
        .maybeSingle();
      if (readError) throw readError;
      if (!current) return reply(404, { error: "No se encontró la publicación." });

      const moderationUpdate: Record<string, unknown> = {
        moderation_status: decision,
        moderation_note: moderationNote || null,
        moderated_by: user.id,
        moderated_at: new Date().toISOString()
      };
      if (decision === "rejected") moderationUpdate.is_published = false;

      const { data: updated, error: updateError } = await admin
        .from("business_content_pages")
        .update(moderationUpdate)
        .eq("id", contentId)
        .select("id,business_id,title,content_type,is_published,moderation_status,moderation_note,moderated_at")
        .single();
      if (updateError) throw updateError;

      const { error: auditError } = await admin.from("audit_logs").insert({
        business_id: current.business_id,
        actor_id: user.id,
        action: decision === "approved" ? "business.content_approved" : "business.content_rejected",
        entity_type: "business_content_page",
        entity_id: current.id,
        details: { title: current.title, content_type: current.content_type, decision, moderation_note: moderationNote || null }
      });
      if (auditError) throw auditError;
      return reply(200, {
        ok: true,
        content: updated,
        message: decision === "approved" ? "Publicación aprobada." : "Publicación rechazada y retirada de la vista pública."
      });
    }

    return reply(400, { error: "Acción no reconocida." });
  } catch (error) {
    console.error("technical-business-management error:", error);
    return reply(500, { error: "La operación no pudo completarse. Revisa los registros de la función." });
  }
});
