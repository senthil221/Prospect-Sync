import type { CompanyScope } from './workspace-scopes.ts';

// Text-index probes for many descriptions are prepared once by the worker.
// Ordinary indexed filters retain their direct request path.
export function needsCompanyPreparation(scope: CompanyScope | null | undefined) {
  if (!scope) return false;
  let descriptionTerms = 0;
  for (const filter of scope.filters) {
    if (!(filter.field === '__short_description'
      || (filter.field === '__company_keywords' && filter.scopes?.includes('description')))) continue;
    if (!['contains', 'not_contains', 'boolean'].includes(filter.operator)) continue;
    // Boolean expressions travel as one string, both raw in the browser and
    // compiled tsquery on the server. Count lexical terms conservatively in both
    // representations. Never treat a 150-term expression as one cheap value.
    descriptionTerms += filter.operator === 'boolean'
      ? filter.values.reduce((count, expression) => count + (expression.match(/[\p{L}\p{N}]+/gu) ?? [])
        .filter(word => !['AND', 'OR', 'NOT'].includes(word)).length, 0)
      : filter.values.length;
  }
  return descriptionTerms >= 8;
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
  const deadline = performance.now() + (options.deadlineMs ?? 15 * 60_000);
  let delay = options.delayMs ?? 750;
  let refreshes = 0;
  try {
    for (;;) {
      options.signal?.throwIfAborted();
      const response = await request();
      if (response.status !== 202) return response;
      const body = await response.json() as { preparation?: PreparationProgress };
      if (!body.preparation) throw new Error('The server returned an invalid search preparation response.');
      if (body.preparation.status === 'refreshing' && ++refreshes > 1) {
        throw new Error('Company data is changing while this search runs. Please retry after the import or update finishes.');
      }
      options.onProgress?.(body.preparation);
      if (performance.now() >= deadline) throw new Error('This search is still being prepared. Reopen it shortly to check the result.');
      // Jitter prevents several tabs polling the same result in lockstep.
      await pause(Math.min(deadline - performance.now(), delay * (0.85 + Math.random() * 0.3)), options.signal);
      delay = Math.min(4000, Math.round(delay * 1.5));
    }
  } finally { options.onProgress?.(null); }
}
