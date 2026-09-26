// Bounded, privacy-safe worker telemetry.
//
// Workers can execute thousands of units and imports refer to customer-owned
// objects. Logging one line per unit (or including job/import identifiers) turns
// observability into both a load source and an accidental data trail. This
// collector emits at most one aggregate line per configured window. Worker and
// phase names come from code-owned allowlists; durations and unit counts are
// finite non-negative integers.

const outcomes = new Set(['ok', 'empty', 'skipped', 'error']);

function boundedNumber(value, maximum) {
  if (!Number.isFinite(value)) return 0;
  return Math.min(maximum, Math.max(0, Math.round(value)));
}
export function createWorkerPhaseMetrics({ worker, phases, intervalMs = 60_000, now = Date.now,
  write = (entry) => console.log(JSON.stringify(entry)) }) {
  if (!/^[a-z][a-z-]{0,31}$/.test(worker)) throw new Error('Invalid worker metric label.');
  const allowedPhases = new Set(phases);
  if (!allowedPhases.size || [...allowedPhases].some(phase => !/^[a-z][a-z-]{0,31}$/.test(phase))) {
    throw new Error('Invalid worker phase metric label.');
  }
  if (!Number.isInteger(intervalMs) || intervalMs < 1_000 || intervalMs > 15 * 60_000) {
    throw new Error('Worker metric interval must be between 1s and 15min.');
  }

  let windowStartedAt = now();
  const aggregates = new Map();

  function snapshotAndReset(at = now()) {
    const phaseMetrics = {};
    for (const [phase, value] of aggregates) phaseMetrics[phase] = {
      count: value.count,
      outcomes: value.outcomes,
      durationMs: { total: value.durationTotal, max: value.durationMax },
      units: value.units,
    };
    aggregates.clear();
    const windowMs = boundedNumber(at - windowStartedAt, 15 * 60_000);
    windowStartedAt = at;
    return { event: 'worker_phase_metrics', worker, windowMs, phases: phaseMetrics };
  }

  function flush(at = now()) {
    if (!aggregates.size) { windowStartedAt = at; return null; }
    const entry = snapshotAndReset(at);
    write(entry);
    return entry;
  }

  function record(phase, outcome, durationMs, units = 0) {
    if (!allowedPhases.has(phase) || !outcomes.has(outcome)) return false;
    const at = now();
    const value = aggregates.get(phase) ?? {
      count: 0, outcomes: { ok: 0, empty: 0, skipped: 0, error: 0 },
      durationTotal: 0, durationMax: 0, units: 0,
    };
    const duration = boundedNumber(durationMs, 15 * 60_000);
    value.count += 1;
    value.outcomes[outcome] += 1;
    value.durationTotal = boundedNumber(value.durationTotal + duration, Number.MAX_SAFE_INTEGER);
    value.durationMax = Math.max(value.durationMax, duration);
    value.units = boundedNumber(value.units + boundedNumber(units, Number.MAX_SAFE_INTEGER), Number.MAX_SAFE_INTEGER);
    aggregates.set(phase, value);
    if (at - windowStartedAt >= intervalMs) flush(at);
    return true;
  }

  return { record, flush, snapshot: () => snapshotAndReset(now()) };
}
