import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.75.0";

const BUCKET = "job-applications-private";
const BATCH_SIZE = 100;
const RATE_LIMIT_BATCH_SIZE = 500;
const RATE_LIMIT_WINDOW_MS = 15 * 60 * 1000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EXTENSIONS = new Set(["pdf", "doc", "docx"]);

function reply(status: number, payload: Record<string, unknown>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store, private, max-age=0",
      "Pragma": "no-cache",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function constantTimeEqual(a: string, b: string): boolean {
  const length = Math.max(a.length, b.length);
  let difference = a.length ^ b.length;
  for (let i = 0; i < length; i++) {
    difference |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return difference === 0;
}

function validSessionPath(session: {
  id: string;
  business_id: string;
  resume_path: string;
}): boolean {
  if (!UUID.test(session.id) || !UUID.test(session.business_id)) return false;
  const parts = session.resume_path.split("/");
  if (parts.length !== 3 || parts[0] !== session.business_id || parts[1] !== session.id) return false;
  const match = /^([0-9a-f-]{36})\.([a-z0-9]+)$/i.exec(parts[2]);
  return Boolean(match && UUID.test(match[1]) && EXTENSIONS.has(match[2].toLowerCase()));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { error: "Método no permitido." });

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const cleanupSecret = Deno.env.get("JOB_APPLICATION_CLEANUP_SECRET") ?? "";
  const suppliedSecret = req.headers.get("x-cleanup-secret") ?? "";
  if (!serviceKey || !cleanupSecret || !suppliedSecret
      || !constantTimeEqual(cleanupSecret, suppliedSecret)) {
    return reply(401, { error: "No autorizado." });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  if (!supabaseUrl) return reply(500, { error: "Configuración incompleta." });

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const now = new Date();
  const nowIso = now.toISOString();
  const expiredBefore = nowIso;
  const rateLimitCutoff = new Date(now.getTime() - RATE_LIMIT_WINDOW_MS).toISOString();
  let sessionsRemoved = 0;
  let objectsRemoved = 0;
  let sessionsWithApplication = 0;
  let sessionsSkipped = 0;
  let sessionErrors = 0;

  try {
    const { data: sessions, error: sessionsError } = await admin.rpc(
      "list_expired_job_application_upload_sessions",
      { p_limit: BATCH_SIZE },
    );
    if (sessionsError) throw sessionsError;

    for (const session of sessions ?? []) {
      try {
        if (!validSessionPath(session)) {
          sessionsSkipped++;
          continue;
        }

        const { data: application, error: applicationError } = await admin
          .from("job_applications")
          .select("id")
          .eq("id", session.id)
          .eq("business_id", session.business_id)
          .eq("content_page_id", session.content_page_id)
          .eq("resume_path", session.resume_path)
          .maybeSingle();
        if (applicationError) throw applicationError;

        // La postulación conserva su CV. Solo se retira la sesión temporal.
        if (application) {
          const { data: deletedSession, error: deleteSessionError } = await admin
            .from("job_application_upload_sessions")
            .delete()
            .eq("id", session.id)
            .eq("business_id", session.business_id)
            .eq("resume_path", session.resume_path)
            .is("consumed_at", null)
            .lte("expires_at", expiredBefore)
            .select("id");
          if (deleteSessionError) throw deleteSessionError;
          if ((deletedSession ?? []).length > 0) sessionsRemoved++;
          sessionsWithApplication++;
          continue;
        }

        const folder = session.business_id + "/" + session.id;
        const fileName = session.resume_path.split("/")[2];
        const { data: files, error: listError } = await admin.storage
          .from(BUCKET)
          .list(folder, { limit: 100 });
        if (listError) throw listError;

        const objectExists = (files ?? []).some((file: any) => file.name === fileName);
        if (objectExists) {
          const { error: removeError } = await admin.storage
            .from(BUCKET)
            .remove([session.resume_path]);
          if (removeError) throw removeError;
          objectsRemoved++;
        }

        // Si Storage falla, la fila se conserva para que el siguiente lote reintente.
        const { data: deletedRows, error: deleteError } = await admin
          .from("job_application_upload_sessions")
          .delete()
          .eq("id", session.id)
          .eq("business_id", session.business_id)
          .eq("resume_path", session.resume_path)
          .is("consumed_at", null)
          .lte("expires_at", expiredBefore)
          .select("id");
        if (deleteError) throw deleteError;
        if ((deletedRows ?? []).length > 0) sessionsRemoved++;
      } catch (error) {
        sessionErrors++;
        console.error("Upload-session cleanup item failed:", error);
      }
    }

    // La ventana del limitador es de 15 minutos. Se vuelve a comprobar el
    // timestamp al borrar para no eliminar un contador que se haya renovado
    // entre la lectura y la eliminación.
    const { data: staleLimits, error: limitsReadError } = await admin
      .from("job_application_rate_limits")
      .select("ip_hash")
      .lte("window_started_at", rateLimitCutoff)
      .limit(RATE_LIMIT_BATCH_SIZE);
    if (limitsReadError) throw limitsReadError;

    let rateLimitRowsRemoved = 0;
    const hashes = (staleLimits ?? []).map((row: any) => row.ip_hash).filter(Boolean);
    if (hashes.length > 0) {
      const { data: deletedLimits, error: limitsDeleteError } = await admin
        .from("job_application_rate_limits")
        .delete()
        .in("ip_hash", hashes)
        .lte("window_started_at", rateLimitCutoff)
        .select("ip_hash");
      if (limitsDeleteError) throw limitsDeleteError;
      rateLimitRowsRemoved = (deletedLimits ?? []).length;
    }

    return reply(sessionErrors > 0 ? 500 : 200, {
      ok: sessionErrors === 0,
      sessionsRemoved,
      objectsRemoved,
      sessionsWithApplication,
      sessionsSkipped,
      sessionErrors,
      rateLimitRowsRemoved,
      hasMoreUploadSessions: (sessions ?? []).length === BATCH_SIZE,
      hasMoreRateLimitRows: hashes.length === RATE_LIMIT_BATCH_SIZE,
    });
  } catch (error) {
    console.error("Job-application cleanup failed:", error);
    return reply(500, { error: "No se pudo completar la limpieza." });
  }
});
