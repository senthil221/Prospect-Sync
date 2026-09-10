// How a failing readiness check gets recorded, and how often.
//
// Two problems with logging every failure at error level, both visible in the
// Server logs tab already:
//
//   1. EVERY DEPLOY PRODUCES ONE. update.sh restarts the import worker partway
//      through a rollout and waits for it to come back before starting the new
//      app, so the app still serving traffic correctly reports the worker as
//      down for a few seconds. That is the check working, not a fault - but it
//      lands as a red row, and a red row that always appears and never means
//      anything teaches you to skim past the tab.
//   2. THE HEALTHCHECK POLLS EVERY 10 SECONDS. A real outage would write six
//      rows a minute, 360 an hour, burying whatever else happened that hour
//      under duplicates of a thing you already know.
//
// So: a failure starts as a warning, becomes an error once it has lasted long
// enough that a restart cannot explain it, and repeats at most every five
// minutes while it persists. A deploy blip leaves exactly one warn row. A dead
// worker still escalates to error, on its own, without anyone watching.
//
// State is per-process and resets on deploy, like the rest of lib/observability.
// That is the right shape here: a fresh container genuinely does not know
// whether the previous one was already failing, and claiming otherwise would be
// worse than starting the clock again.

export type ReadinessDecision = { level: "warn" | "error"; log: boolean };

// Longer than a worker restart (measured: the import worker is back within
// ~40s of update.sh recreating it), short enough that a genuine failure is
// escalated well inside the window anyone would notice it.
export const sustainedFailureMs = 60_000;
const repeatEveryMs = 5 * 60_000;

let current: { signature: string; since: number; loggedAt: number; escalated: boolean } | null = null;

export function readinessLogDecision(failed: string[], now: number = Date.now()): ReadinessDecision {
  if (failed.length === 0) {
    current = null;
    return { level: "warn", log: false };
  }

  // Which checks are failing, not how many: worker-down and worker-down-plus-
  // storage-down are different incidents and each deserves its own first row.
  const signature = [...failed].sort().join(",");

  if (!current || current.signature !== signature) {
    current = { signature, since: now, loggedAt: now, escalated: false };
    return { level: "warn", log: true };
  }

  if (!current.escalated && now - current.since >= sustainedFailureMs) {
    current.escalated = true;
    current.loggedAt = now;
    return { level: "error", log: true };
  }

  if (now - current.loggedAt >= repeatEveryMs) {
    current.loggedAt = now;
    return { level: current.escalated ? "error" : "warn", log: true };
  }

  return { level: current.escalated ? "error" : "warn", log: false };
}

// Tests only: the module-level clock is deliberate everywhere else.
export function resetReadinessLog() {
  current = null;
}
