import type { CompanyScope } from './workspace-scopes.ts';

// Text-index probes for many descriptions are prepared once by the worker.
// Ordinary indexed filters retain their direct request path.
export function needsCompanyPreparation(scope: CompanyScope | null | undefined) {
  if (!scope) return false;
  return scope.filters.some(filter =>
    (filter.field === '__short_description'
      || (filter.field === '__company_keywords' && filter.scopes?.includes('description')))
    && ['contains', 'not_contains', 'boolean'].includes(filter.operator)
    && filter.values.length >= 8);
}

export type PreparationProgress = { status: string; message: string; matchedCompanies: number };

function pause(ms: number, signal?: AbortSignal | null) {
  return new Promise<void>((resolve, reject) => {
    if (signal?.aborted) { reject(signal.reason ?? new DOMException('Aborted', 'AbortError')); return; }
    const abort = () => { clearTimeout(timer); reject(signal?.reason ?? new DOMException('Aborted', 'AbortError')); };
    const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, ms);
    signal?.addEventListener('abort', abort, { once: true });
  });
}

// Poll only an explicit 202 preparation response. No failed query or mutation
// is retried here. Cancellation stops both network activity and the wait.
export async function awaitPreparedSearch(
  request: () => Promise<Response>,
  options: { signal?: AbortSignal | null; onProgress?: (progress: PreparationProgress | null) => void; deadlineMs?: number; delayMs?: number } = {},
) {
  const deadline = Date.now() + (options.deadlineMs ?? 15 * 60_000);
  let delay = options.delayMs ?? 750;
  try {
    for (;;) {
      options.signal?.throwIfAborted();
      const response = await request();
      if (response.status !== 202) return response;
      const body = await response.json() as { preparation?: PreparationProgress };
      if (!body.preparation) throw new Error('The server returned an invalid search preparation response.');
      options.onProgress?.(body.preparation);
      if (Date.now() >= deadline) throw new Error('This search is still being prepared. Reopen it shortly to check the result.');
      await pause(delay, options.signal);
      delay = Math.min(4000, Math.round(delay * 1.5));
    }
  } finally { options.onProgress?.(null); }
}
