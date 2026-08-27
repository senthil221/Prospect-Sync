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
  if (!failed.length) return Response.json({ status: "ok", checks: checkStatus }, { headers: noStoreHeaders });
  console.error("Readiness check failed", { failed });
  return Response.json({ status: "unhealthy", checks: checkStatus }, { status: 503, headers: noStoreHeaders });
}
