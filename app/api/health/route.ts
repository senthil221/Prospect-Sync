import { admissionState } from "../../../lib/admission";
import { getAuthorizedUser } from "../../../lib/auth";
import { observabilitySnapshot } from "../../../lib/observability";
import { createAdminClient } from "../../../lib/supabase/admin";

const timeoutMs = 5_000;
const noStoreHeaders = { "Cache-Control": "no-store, max-age=0" };

async function checkAuth() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) throw new Error("Supabase URL is not configured");

  const response = await fetch(`${supabaseUrl.replace(/\/$/, "")}/auth/v1/health`, {
    cache: "no-store",
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Auth health returned HTTP ${response.status}`);
}

async function checkDataApi() {
  const { error } = await createAdminClient()
    .from("clients")
    .select("id")
    .limit(1)
    .abortSignal(AbortSignal.timeout(timeoutMs));
  if (error) throw error;
}

async function checkStorage() {
  const storageUrl = process.env.SUPABASE_STORAGE_URL;
  if (!storageUrl) throw new Error("Storage URL is not configured");
  const response = await fetch(`${storageUrl.replace(/\/$/, "")}/status`, {
    cache: "no-store",
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Storage health returned HTTP ${response.status}`);
}

async function checkImportWorker() {
  const workerUrl = process.env.IMPORT_WORKER_HEALTH_URL;
  if (!workerUrl) throw new Error("Import worker health URL is not configured");
  const response = await fetch(workerUrl, {
    cache: "no-store",
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Import worker health returned HTTP ${response.status}`);
}

export async function GET() {
  const checks = { auth: checkAuth, dataApi: checkDataApi, storage: checkStorage, importWorker: checkImportWorker };
  const results = await Promise.allSettled(Object.values(checks).map((check) => check()));
  const entries = Object.keys(checks).map((name, index) => [name, results[index].status === "fulfilled" ? "ok" : "failed"]);
  const checkStatus = Object.fromEntries(entries);
  const failed = entries.filter(([, status]) => status === "failed").map(([name]) => name);
  // Load and refusal counts ride along with readiness. They are what says
  // whether the interactive guard, the filter caps or the 10s statement ceiling
  // are set right for real traffic - each of which refuses a user silently
  // otherwise. Per-process and reset on deploy: a signal, not an audit.
  //
  // Only for a signed-in user. This endpoint is public by necessity - the deploy
  // smoke test reads its status and X-App-Version from a GitHub runner - and the
  // counters would otherwise tell an anonymous caller the exact concurrency
  // limit, which is the number of slow requests needed to fill the guard.
  // Readiness itself stays public and unchanged.
  const authorized = await getAuthorizedUser().catch(() => null);
  const load = authorized ? { admission: admissionState(), ...observabilitySnapshot() } : undefined;
  if (!failed.length) return Response.json({ status: "ok", checks: checkStatus, load }, { headers: noStoreHeaders });
  console.error("Readiness check failed", { failed });
  return Response.json({ status: "unhealthy", checks: checkStatus, load }, { status: 503, headers: noStoreHeaders });
}
