// Visit each class once per round even if earlier queues remain busy or fail.
// runUnit must execute one atomic resumable database unit, not drain a job.
export function createFairScheduler({ classes, runUnit, onError, stopping = () => false }) {
  let next = 0;
  return async function round() {
    let progressed = false;
    for (let visited = 0; visited < classes.length && !stopping(); visited++) {
      const kind = classes[next];
      next = (next + 1) % classes.length;
      try { progressed = (await runUnit(kind)) || progressed; }
      catch (error) { await onError(kind, error); }
    }
    return progressed;
  };
}
export function integerSetting(value, fallback, min, max, name) {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) throw new Error(`${name} must be an integer from ${min} to ${max}.`);
  return parsed;
}
