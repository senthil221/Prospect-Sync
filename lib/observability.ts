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

type Outcome = "ok" | "client_error" | "over_cap" | "overloaded" | "timed_out" | "server_error";

const counters = new Map<string, number>();
const slowest = new Map<string, number>();
let started = Date.now();

function bump(key: string, by = 1) {
  counters.set(key, (counters.get(key) ?? 0) + by);
}

export function outcomeFor(status: number): Outcome {
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
  try { return new URL(url).pathname; } catch { return "unknown"; }
}

export function recordRequest(route: string, status: number, durationMs: number) {
  const outcome = outcomeFor(status);
  bump(`total`);
  bump(`outcome:${outcome}`);
  bump(`route:${route}:${outcome}`);
  const previous = slowest.get(route) ?? 0;
  if (durationMs > previous) slowest.set(route, Math.round(durationMs));

  // A refusal is worth a line each; a success is not, or the log becomes the
  // load. Slow successes are logged too, because a request approaching the 10s
  // ceiling is the early warning for one that crosses it.
  if (outcome !== "ok" || durationMs > 5_000) {
    console.warn(JSON.stringify({
      at: new Date().toISOString(),
      route,
      status,
      outcome,
      durationMs: Math.round(durationMs),
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
  };
}

// Tests only: the counters are process-global by design.
export function resetObservability() {
  counters.clear();
  slowest.clear();
  started = Date.now();
}
