import { admissionState } from "../../../lib/admission";
import { getAuthorizedUser } from "../../../lib/auth";
import { observabilitySnapshot } from "../../../lib/observability";
import { operationsHealth } from "../../../lib/operations-health";
import { createAdminClient } from "../../../lib/supabase/admin";
import { backgroundAlerts } from '../../../lib/background-health';
import { logServerEvent } from '../../../lib/server-log';
import { readinessLogDecision } from '../../../lib/readiness-log';

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
  // Core: what this container needs in order to answer a request at all. The
  // app router reads this endpoint (health_uri /api/health, health_status 200)
  // and drops the slot when it is not 200, so ONLY these may decide the status.
  const coreChecks = { auth: checkAuth, dataApi: checkDataApi, storage: checkStorage };
  // The import worker is a background job runner, in the same category as the
  // operations worker below: browsing, searching and exporting all work while
  // it is down. It used to sit in `checks` and therefore 503'd this endpoint,
  // which took the whole site out of the load balancer every time a rollout
  // restarted it - one warn row per deploy in the server log was the visible
  // half of that. Reported and escalated here, never served as unhealthy.
  const workerChecks = { importWorker: checkImportWorker };
  const [coreResults, workerResults, operations] = await Promise.all([
    Promise.allSettled(Object.values(coreChecks).map((check) => check())),
    Promise.allSettled(Object.values(workerChecks).map((check) => check())),
    operationsHealth(),
  ]);
  const statusEntries = (names: string[], results: PromiseSettledResult<void>[]) =>
    names.map((name, index) => [name, results[index].status === "fulfilled" ? "ok" : "failed"] as const);
  const coreEntries = statusEntries(Object.keys(coreChecks), coreResults);
  const workerEntries = statusEntries(Object.keys(workerChecks), workerResults);
  // The payload keeps every check in one place, so nothing reading it has to
  // know which of them is allowed to take the container out of service.
  const checkStatus = Object.fromEntries([...coreEntries, ...workerEntries]);
  // Feature readiness is separate from core health: a stopped search worker
  // must not take ordinary browsing out of the load balancer.
  const features = { preparedSearch: operations.status, backgroundOperations: operations.status, importWorker: checkStatus.importWorker };
  const failed = coreEntries.filter(([, status]) => status === "failed").map(([name]) => name);
  const degraded = workerEntries.filter(([, status]) => status === "failed").map(([name]) => name);
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
  let background: unknown;
  if (authorized) {
    try {
      const sample = await createAdminClient().rpc('background_health_v1').abortSignal(AbortSignal.timeout(timeoutMs));
      background = sample.error ? null : sample.data;
    } catch { background = null; } // Telemetry loss must not hide core readiness.
  }
  const load = authorized ? { admission: admissionState(), ...observabilitySnapshot(),
    background, alerts: backgroundAlerts(background) } : undefined;
  // Everything that is away, whether or not it can take this container out of
  // service - a dead import worker still has to escalate to an error row on
  // its own. Only the first poll differs: a core failure is news immediately,
  // a worker alone is not, because every rollout restarts one.
  //
  // Escalation, the five-minute repeat and the clearing of the clock on
  // recovery are all in readinessLogDecision; it is called on the healthy path
  // too, which is what resets it.
  const unavailable = [...failed, ...degraded];
  const readiness = readinessLogDecision(unavailable, Date.now(), failed.length > 0);
  if (readiness.log) {
    const summary = `${failed.length ? "Readiness check failed" : "Background worker unavailable"}: ${unavailable.join(", ")}`;
    console[readiness.level === "error" ? "error" : "warn"](summary, { failed, degraded });
    logServerEvent({ level: readiness.level, source: "health", statusCode: failed.length ? 503 : 200, message: summary, detail: { failed, degraded, checks: checkStatus } });
  }
  if (!failed.length) return Response.json({ status: degraded.length ? "degraded" : "ok", checks: checkStatus, load, features }, { headers: noStoreHeaders });
  return Response.json({ status: "unhealthy", checks: checkStatus, load, features }, { status: 503, headers: noStoreHeaders });
}
