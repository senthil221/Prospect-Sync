// Process-local burst protection, not a substitute for database resource limits.
export function boundedInteger(value: string | undefined, fallback: number, min: number, max: number) {
  const parsed = value === undefined || value.trim() === '' ? fallback : Number(value);
  return Number.isSafeInteger(parsed) && parsed >= min && parsed <= max ? parsed : fallback;
}

export function configuredInteger(name: string, value: string | undefined, fallback: number, min: number, max: number) {
  if (value === undefined || value.trim() === '') return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    throw new RangeError(`${name} must be an integer from ${min} to ${max}.`);
  }
  return parsed;
}

export function createAdmissionQueue(limit: number, maxWaiting: number, waitMs: number) {
  if (![limit, maxWaiting, waitMs].every(Number.isSafeInteger) || limit < 1 || maxWaiting < 0 || waitMs < 0) {
    throw new RangeError('Invalid admission limits');
  }
  let inFlight = 0;
  const waiting: Array<{ settle: (admitted: boolean) => void }> = [];
  function release() {
    const next = waiting[0];
    if (next) next.settle(true);
    else inFlight--;
  }
  async function acquire(signal?: AbortSignal): Promise<(() => void) | null> {
    if (signal?.aborted) return null;
    let admitted: boolean;
    if (inFlight < limit) { inFlight++; admitted = true; }
    else if (waiting.length >= maxWaiting || waitMs === 0) return null;
    else admitted = await new Promise<boolean>((resolve) => {
      let settled = false;
      const onAbort = () => waiter.settle(false);
      const waiter = { settle(value: boolean) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', onAbort);
        const index = waiting.indexOf(waiter);
        if (index >= 0) waiting.splice(index, 1);
        resolve(value);
      } };
      const timer = setTimeout(() => waiter.settle(false), waitMs);
      waiting.push(waiter);
      signal?.addEventListener('abort', onAbort, { once: true });
      if (signal?.aborted) waiter.settle(false);
    });
    if (!admitted) return null;
    // Abort can race with transfer: return the transferred slot, never leak it.
    if (signal?.aborted) { release(); return null; }
    let released = false;
    return () => { if (!released) { released = true; release(); } };
  }
  return { acquire, state: () => ({ inFlight, waiting: waiting.length, limit, maxWaiting, waitMs }) };
}
