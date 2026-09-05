export type OperationsHealth = { status: 'ok' | 'unavailable' | 'not_configured' };

// One bounded probe per process/TTL, not one network call per browser poll.
// Missing configuration fails closed for NEW work; ready results remain usable.
export function createOperationsHealthProbe(fetcher: typeof fetch = fetch, ttlMs = 5000) {
  let cached: OperationsHealth | undefined;
  let expiresAt = 0;
  let pending: Promise<OperationsHealth> | undefined;
  let lastUrl: string | undefined;
  return function probe(url: string | undefined): Promise<OperationsHealth> {
    if (!url) return Promise.resolve({ status: 'not_configured' });
    if (lastUrl !== url) { cached = undefined; expiresAt = 0; }
    if (lastUrl === url && cached && performance.now() < expiresAt) return Promise.resolve(cached);
    if (lastUrl === url && pending) return pending;
    lastUrl = url;
    const current = (async (): Promise<OperationsHealth> => {
      try {
        const response = await fetcher(url, { cache: 'no-store', signal: AbortSignal.timeout(1000) });
        const body = response.ok ? await response.json() : null;
        return body?.status === 'ok' ? { status: 'ok' } : { status: 'unavailable' };
      } catch { return { status: 'unavailable' }; }
    })();
    pending = current;
    void current.then(result => {
      if (pending !== current) return;
      cached = result; expiresAt = performance.now() + ttlMs; pending = undefined;
    });
    return current;
  };
}

const probe = createOperationsHealthProbe();
export const operationsHealth = () => probe(process.env.OPERATIONS_WORKER_HEALTH_URL);
