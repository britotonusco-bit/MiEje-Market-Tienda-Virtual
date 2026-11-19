import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.75.0";

const BUCKET = "job-applications-private";
const REQUIRED_PRIVACY_CONSENT_VERSION = "job-application-2026-11-19-v1";
const MAX_FILE_SIZE = 5 * 1024 * 1024;
const ALLOWED: Record<string, { mime: string; extension: string }> = {
  "application/pdf": { mime: "application/pdf", extension: "pdf" },
  "application/msword": { mime: "application/msword", extension: "doc" },
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": {
    mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    extension: "docx",
  },
};
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
      "Cache-Control": "no-store, private, max-age=0",
      "Pragma": "no-cache",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
function value(input: unknown, max: number): string {
  return typeof input === "string" ? input.trim().slice(0, max) : "";
}
function isUuid(input: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input);
}
async function sha256(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply(405, { error: "Método no permitido." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return reply(500, { error: "El servicio no está configurado." });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "La solicitud no contiene JSON válido." });
  }

  if (value(body.website, 200)) {
    return reply(400, { error: "No fue posible procesar la solicitud." });
  }

  // Confiar solo en la IP que el proxy de borde establece. El valor
  // izquierdo de X-Forwarded-For puede ser controlado por el solicitante y
  // permitiría evadir el límite por IP si se usa como fallback.
  const ip = (req.headers.get("cf-connecting-ip") ?? "").trim();
  if (!ip) return reply(400, { error: "No fue posible validar la solicitud." });

  const action = value(body.action, 30);
  if (action !== "request_upload" && action !== "submit") {
    return reply(400, { error: "Acción no válida." });
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // Cada etapa tiene su propio contador: preparar una carga y enviar la
    // postulación son dos peticiones legítimas de una misma solicitud.
    const ipHash = await sha256(ip + ":" + serviceKey + ":" + action);
    const { data: allowed, error: rateError } = await admin.rpc(
      "consume_job_application_rate_limit",
      { p_ip_hash: ipHash },
    );
    if (rateError) {
      console.error("Job application rate-limit failed:", rateError);
      return reply(503, { error: "No fue posible validar la solicitud." });
    }
    if (allowed !== true) return reply(429, { error: "Se recibieron demasiadas solicitudes. Inténtalo más tarde." });

    const businessId = value(body.business_id, 80);
    const contentPageId = value(body.content_page_id, 80);
    if (!isUuid(businessId) || !isUuid(contentPageId)) {
      return reply(400, { error: "La vacante indicada no es válida." });
    }

    const { data: business, error: businessError } = await admin
      .from("businesses")
      .select("id,status")
      .eq("id", businessId)
      .maybeSingle();
    if (businessError) throw businessError;
    if (!business || business.status !== "active") {
      return reply(404, { error: "La vacante no está disponible." });
    }

    const { data: page, error: pageError } = await admin
      .from("business_content_pages")
      .select("id,business_id,content_type,is_published,moderation_status")
      .eq("id", contentPageId)
      .eq("business_id", businessId)
      .maybeSingle();
    if (pageError) throw pageError;
    if (!page || page.content_type !== "job_form" || !page.is_published || page.moderation_status !== "approved") {
      return reply(404, { error: "La vacante no está disponible." });
    }

    if (action === "request_upload") {
      // No emitir un token de carga ni recibir una hoja de vida antes de que
      // la persona acepte el aviso de tratamiento en el servidor.
      if (body.privacy_consent !== true || body.privacy_consent_version !== REQUIRED_PRIVACY_CONSENT_VERSION) {
        return reply(400, { error: "Autoriza el tratamiento de datos antes de adjuntar tu hoja de vida." });
      }
      const fileName = value(body.file_name, 180);
      const contentType = value(body.content_type, 120).toLowerCase();
      const fileSize = Number(body.file_size);
      const fileType = ALLOWED[contentType];
      const originalExtension = fileName.includes(".") ? fileName.split(".").pop()!.toLowerCase() : "";
      if (!fileType || originalExtension !== fileType.extension
          || !Number.isInteger(fileSize) || fileSize < 1 || fileSize > MAX_FILE_SIZE) {
        return reply(400, { error: "Adjunta un PDF, DOC o DOCX de máximo 5 MB." });
      }

      const applicationId = crypto.randomUUID();
      const objectName = crypto.randomUUID() + "." + fileType.extension;
      const path = businessId + "/" + applicationId + "/" + objectName;
      const expiresAt = new Date(Date.now() + 30 * 60 * 1000).toISOString();

      const { error: sessionError } = await admin.from("job_application_upload_sessions").insert({
        id: applicationId,
        business_id: businessId,
        content_page_id: contentPageId,
        resume_path: path,
        expires_at: expiresAt,
      });
      if (sessionError) throw sessionError;

      const { data: signed, error: signedError } = await admin.storage
        .from(BUCKET)
        .createSignedUploadUrl(path, { upsert: false });
      if (signedError || !signed) {
        await admin.from("job_application_upload_sessions").delete().eq("id", applicationId);
        throw signedError ?? new Error("No se pudo preparar la carga.");
      }

      return reply(200, {
        ok: true,
        application_id: applicationId,
        resume_path: path,
        upload_token: signed.token,
        expires_at: expiresAt,
      });
    }

    if (action === "submit") {
      const applicantName = value(body.applicant_name, 120);
      const applicantContact = value(body.applicant_contact, 180);
      const applicantMessage = value(body.applicant_message, 2000);
      const privacyConsent = body.privacy_consent === true
        && body.privacy_consent_version === REQUIRED_PRIVACY_CONSENT_VERSION;
      const formResponses = body.form_responses && typeof body.form_responses === "object"
        && !Array.isArray(body.form_responses) ? body.form_responses : {};
      const responseEntries = Object.entries(formResponses);
      const responseBytes = new TextEncoder().encode(JSON.stringify(formResponses)).byteLength;
      const validResponses = responseEntries.length <= 20
        && responseEntries.every(([key, item]) =>
          key.length <= 80 && typeof item === "string" && item.length <= 500
        );
      const applicationIdInput = value(body.application_id, 80);
      const resumePath = value(body.resume_path, 500) || null;

      if (!applicantName || !applicantContact || !privacyConsent) {
        return reply(400, { error: "Completa tus datos y autoriza el tratamiento de datos." });
      }
      if (!validResponses || responseBytes > 16 * 1024) {
        return reply(400, { error: "Las respuestas del formulario superan los límites permitidos." });
      }

      const applicationId = resumePath
        ? applicationIdInput
        : (isUuid(applicationIdInput) ? applicationIdInput : crypto.randomUUID());
      if (!isUuid(applicationId)) return reply(400, { error: "La carga de la hoja de vida no es válida." });

      if (resumePath) {
        const { data: session, error: sessionError } = await admin
          .from("job_application_upload_sessions")
          .select("id,resume_path,expires_at,consumed_at")
          .eq("id", applicationId)
          .eq("business_id", businessId)
          .eq("content_page_id", contentPageId)
          .eq("resume_path", resumePath)
          .maybeSingle();
        if (sessionError) throw sessionError;
        if (!session || session.consumed_at || new Date(session.expires_at).getTime() <= Date.now()) {
          return reply(400, { error: "La hoja de vida no se cargó correctamente o el enlace venció." });
        }

        const parts = resumePath.split("/");
        const folder = parts.slice(0, 2).join("/");
        const fileName = parts[2];
        const { data: files, error: listError } = await admin.storage.from(BUCKET).list(folder, { search: fileName });
        if (listError) throw listError;
        const uploaded = (files ?? []).find((file: any) => file.name === fileName);
        if (!uploaded || Number(uploaded.metadata?.size ?? 0) < 1
            || Number(uploaded.metadata?.size ?? 0) > MAX_FILE_SIZE) {
          return reply(400, { error: "No encontramos el archivo adjunto o supera el límite permitido." });
        }

        // La extensión y el MIME del navegador no prueban el formato real.
        // Comprobar la firma binaria básica antes de guardar la postulación.
        const { data: resumeBlob, error: downloadError } = await admin.storage.from(BUCKET).download(resumePath);
        if (downloadError || !resumeBlob) throw downloadError ?? new Error("No se pudo verificar el archivo.");
        const header = new Uint8Array(await resumeBlob.slice(0, 8).arrayBuffer());
        const isPdf = resumePath.toLowerCase().endsWith(".pdf")
          && header.length >= 5 && String.fromCharCode(...header.slice(0, 5)) === "%PDF-";
        const isDoc = resumePath.toLowerCase().endsWith(".doc")
          && header.length >= 8
          && [0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1].every((byte, index) => header[index] === byte);
        const isDocx = resumePath.toLowerCase().endsWith(".docx")
          && header.length >= 4 && header[0] === 0x50 && header[1] === 0x4b
          && header[2] === 0x03 && header[3] === 0x04;
        if (!(isPdf || isDoc || isDocx)) {
          await admin.storage.from(BUCKET).remove([resumePath]);
          await admin.from("job_application_upload_sessions").delete().eq("id", applicationId);
          return reply(400, { error: "El archivo no coincide con un PDF, DOC o DOCX válido." });
        }
      }

      const { data: applicationIdResult, error: submitError } = await admin.rpc(
        "submit_public_job_application",
        {
          p_application_id: applicationId,
          p_business_id: businessId,
          p_content_page_id: contentPageId,
          p_applicant_name: applicantName,
          p_applicant_contact: applicantContact,
          p_applicant_message: applicantMessage,
          p_form_responses: formResponses,
          p_privacy_consent: privacyConsent,
          p_privacy_consent_version: REQUIRED_PRIVACY_CONSENT_VERSION,
          p_resume_path: resumePath,
        },
      );
      if (submitError) {
        console.error("Job application submission failed:", submitError);
        return reply(400, { error: "No se pudo registrar la postulación. Verifica los datos y vuelve a intentarlo." });
      }
      return reply(201, { ok: true, application_id: applicationIdResult });
    }

    return reply(400, { error: "Acción no válida." });
  } catch (error) {
    console.error("create-job-application error:", error);
    return reply(500, { error: "Ocurrió un error al procesar la postulación." });
  }
});
