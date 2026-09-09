import { createAdminClient } from "./supabase/admin.ts";

export type ServerLogLevel = "info" | "warn" | "error";
export type ServerLogEntry = {
  level: ServerLogLevel;
  source: string;
  message: string;
  route?: string;
  statusCode?: number;
  durationMs?: number;
  requestId?: string;
  detail?: unknown;
};

// Best-effort and fire-and-forget: a failure to record a log line must never
// break the request that triggered it. Callers keep their existing
// console.error/warn alongside this - the DB row is the durable history,
// the console line is still what a live `docker logs`/deploy log shows.
export function logServerEvent(entry: ServerLogEntry) {
  void persist(entry).catch(() => {});
}

async function persist(entry: ServerLogEntry) {
  const supabase = createAdminClient();
  await supabase.from("system_event_log").insert({
    level: entry.level,
    source: entry.source,
    message: entry.message.slice(0, 2000),
    route: entry.route ?? null,
    status_code: entry.statusCode ?? null,
    duration_ms: entry.durationMs ?? null,
    request_id: entry.requestId ?? null,
    detail: serializeDetail(entry.detail),
  });
  // Cheap, unscheduled retention: about one insert in 200 also sweeps rows
  // older than 30 days. No pg_cron job exists in this project to hang a
  // scheduled purge off of, and running it on every insert would double the
  // write cost of every logged event for no benefit.
  if (Math.random() < 0.005) await supabase.rpc("purge_system_event_log_v1");
}

function serializeDetail(detail: unknown): Record<string, unknown> {
  if (!detail) return {};
  if (detail instanceof Error) return { name: detail.name, message: detail.message, stack: detail.stack };
  if (typeof detail === "object") {
    try { return JSON.parse(JSON.stringify(detail)); } catch { return { value: String(detail) }; }
  }
  return { value: String(detail) };
}
