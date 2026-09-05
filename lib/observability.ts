// Make the failure modes visible.
//
// Releases 1A-1C added three ways a request can be refused that did not exist
// before: 413 when a filter set is over cap, 503 when the interactive guard is
// full, 504 when a statement passes its timeout. Each of them is the right
// answer, and each of them is invisible - a user hits it, retries, and nobody
// ever learns that the cap or the concurrency limit or the 10s ceiling is set
// wrong for real traffic.
//
// Section 3.1 of the plan asks for route logs carrying request id, route, query
// family, duration, rows and outcome. This is the small version of that: enough
// to answer "is anything being refused, and how often", without pretending to be
// a metrics stack. It is per-process and resets on deploy, which is fine for
// what it is for - two application slots overlap during a release, so these
// numbers are a signal, never an audit.

type Outcome = "ok" | "pending" | "client_error" | "over_cap" | "overloaded" | "timed_out" | "server_error";

const counters = new Map<string, number>();
const slowest = new Map<string, number>();
const histogramBounds = [100, 250, 500, 1000, 2000, 3000, 5000, 10000, 30000, 120000];
const histograms = new Map<string, number[]>();
const routeFamilies = new Set(['prospects', 'companies', 'clients', 'lists', 'imports', 'company-imports',
  'filter-sets', 'result-sets', 'operations', 'exports', 'coverage', 'data-quality', 'health', 'dashboard', 'search']);
let logWindow = 0;
let logCount = 0;
let suppressedLogs = 0;
let started = Date.now();

function bump(key: string, by = 1) {
  counters.set(key, (counters.get(key) ?? 0) + by);
}

export function outcomeFor(status: number): Outcome {
  if (status === 202) return "pending";
  if (status === 413) return "over_cap";
  if (status === 503 || status === 429) return "overloaded";
  if (status === 504) return "timed_out";
  if (status >= 500) return "server_error";
  if (status >= 400) return "client_error";
  return "ok";
}

// Route rather than full URL: the path identifies the query family, and the
// query string can carry a filter set of thousands of values.
export function routeOf(url: string) {
  try { return routeFamily(new URL(url).pathname); } catch { return "unknown"; }
}

function routeFamily(path: string) {
  const [, api, family] = path.split('/');
  return api === 'api' && routeFamilies.has(family) ? `/api/${family}` : 'unknown';
}

export function recordRequest(route: string, status: number, durationMs: number,
  context?: { requestId: string; admissionMs: number }) {
  route = routeFamily(route); // Bounded labels even for direct callers and arbitrary IDs.
  durationMs = Number.isFinite(durationMs) ? Math.max(0, durationMs) : 0;
  const outcome = outcomeFor(status);
  bump(`total`);
  bump(`outcome:${outcome}`);
  bump(`route:${route}:${outcome}`);
  const previous = slowest.get(route) ?? 0;
  if (durationMs > previous) slowest.set(route, Math.round(durationMs));
  const histogramKey = `${route}:${outcome}`;
  const buckets = histograms.get(histogramKey) ?? Array(histogramBounds.length + 1).fill(0);
  const index = histogramBounds.findIndex(bound => durationMs <= bound);
  buckets[index < 0 ? histogramBounds.length : index]++;
  histograms.set(histogramKey, buckets);

  // A refusal is worth a line each; a success is not, or the log becomes the
  // load. Slow successes are logged too, because a request approaching the 10s
  // ceiling is the early warning for one that crosses it.
  if ((outcome !== "ok" && outcome !== "pending") || durationMs > 5_000 || (counters.get('total') ?? 0) % 100 === 0) {
    const window = Math.floor(Date.now() / 60000);
    if (window !== logWindow) { logWindow = window; logCount = 0; }
    if (logCount++ >= 120) { suppressedLogs++; return; }
    console.warn(JSON.stringify({
      at: new Date().toISOString(),
      route,
      status,
      outcome,
      durationMs: Math.round(durationMs),
      requestId: context?.requestId,
      admissionMs: context ? Math.round(context.admissionMs) : undefined,
    }));
  }
}

export function observabilitySnapshot() {
  const outcomes: Record<string, number> = {};
  const routes: Record<string, Record<string, number>> = {};
  for (const [key, value] of counters) {
    if (key.startsWith("outcome:")) outcomes[key.slice("outcome:".length)] = value;
    else if (key.startsWith("route:")) {
      const rest = key.slice("route:".length);
      const split = rest.lastIndexOf(":");
      const route = rest.slice(0, split);
      const outcome = rest.slice(split + 1);
      (routes[route] ??= {})[outcome] = value;
    }
  }
  return {
    sinceMinutes: Math.round((Date.now() - started) / 60_000),
    requests: counters.get("total") ?? 0,
    outcomes,
    routes,
    slowestMs: Object.fromEntries(slowest),
    latency: { boundsMs: [...histogramBounds, '+Inf'], buckets: Object.fromEntries(histograms) },
    suppressedLogs,
  };
}

// Tests only: the counters are process-global by design.
export function resetObservability() {
  counters.clear();
  slowest.clear();
  histograms.clear();
  logCount = 0;
  suppressedLogs = 0;
  started = Date.now();
}
