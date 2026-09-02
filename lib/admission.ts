// Admission control for the interactive database path.
//
// Measured on production (PostgREST 12.2.12): when the browser gives up on a
// request, PostgREST does NOT cancel the statement it started. An export
// abandoned after 2.1 s kept its backend busy for the full 7.9 s, holding a pool
// connection nobody was waiting for. Reloading a slow page therefore adds a
// connection rather than replacing one, which is how 24 slots disappear.
//
// So the interactive pool has to be protected on the way in, before the request
// reaches a connection it might not give back promptly:
//
//   1. this guard, per application slot, failing fast and legibly
//   2. each function's statement_timeout, which is the real upper bound on how
//      long an abandoned query can hold its slot
//   3. per-role CONNECTION LIMIT in the database, which is the authority
//
// This is only the first. It lives in one process, and blue/green runs two
// slots at once during a deploy, so it can never be more than a fast-fail
// guard - which is why the limit below is sized for two slots running together.
// The database-side limits are what actually bound the system.

// PGRST_DB_POOL is 24. Two application slots overlap during a deploy, and auth,
// storage, meta and the import worker's REST calls also draw from that pool, so
// each slot gets 8: sixteen at the worst moment, with eight slots of headroom.
const maxConcurrentInteractive = Number(process.env.INTERACTIVE_CONCURRENCY ?? 8);

// A burst is not an overload. Waiting briefly absorbs the ordinary case where
// several panels load at once; past this the answer is a refusal, not a queue
// that grows until every request has timed out anyway.
const admissionWaitMs = Number(process.env.INTERACTIVE_ADMISSION_WAIT_MS ?? 2000);

type Waiter = { resolve: (admitted: boolean) => void; timer: ReturnType<typeof setTimeout> };

let inFlight = 0;
const waiting: Waiter[] = [];

function release() {
  const next = waiting.shift();
  if (!next) {
    inFlight -= 1;
    return;
  }
  // The slot passes straight to the next waiter; inFlight does not dip.
  clearTimeout(next.timer);
  next.resolve(true);
}

function acquire(signal?: AbortSignal): Promise<boolean> {
  if (signal?.aborted) return Promise.resolve(false);
  if (inFlight < maxConcurrentInteractive) {
    inFlight += 1;
    return Promise.resolve(true);
  }
  return new Promise<boolean>((resolve) => {
    const waiter: Waiter = {
      resolve,
      timer: setTimeout(() => {
        const index = waiting.indexOf(waiter);
        if (index >= 0) waiting.splice(index, 1);
        resolve(false);
      }, admissionWaitMs),
    };
    waiting.push(waiter);
    // A caller that has already gone away should not hold a place in the queue.
    signal?.addEventListener("abort", () => {
      const index = waiting.indexOf(waiter);
      if (index >= 0) {
        waiting.splice(index, 1);
        clearTimeout(waiter.timer);
        resolve(false);
      }
    }, { once: true });
  });
}

// 503 rather than 429: nothing about this request was excessive, the server is
// simply full. Retry-After is short and the client jitters around it, so a
// refused burst does not come back as a synchronised second burst.
export function overloadedResponse(): Response {
  return Response.json({
    error: "The database is busy right now. This request was refused rather than queued, so nothing is half-done - try again in a moment.",
    retryable: true,
  }, { status: 503, headers: { "Retry-After": "2" } });
}

// Run `work` with an interactive slot held, or answer 503 without touching the
// database. The slot is always given back, including when `work` throws.
export async function withInteractiveSlot(
  request: Request,
  work: () => Promise<Response>,
): Promise<Response> {
  const admitted = await acquire(request.signal);
  if (!admitted) return overloadedResponse();
  try {
    return await work();
  } finally {
    release();
  }
}

// For tests and for the health endpoint: how loaded this slot is right now.
export function admissionState() {
  return { inFlight, waiting: waiting.length, limit: maxConcurrentInteractive };
}
