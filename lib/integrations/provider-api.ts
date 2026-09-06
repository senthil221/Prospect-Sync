import type { Provider } from './credentials.ts';

export class ProviderError extends Error {
  readonly status: number;
  readonly retryAfter: number;
  constructor(status: number, message: string, retryAfter = 0) {
    super(message); this.status = status; this.retryAfter = retryAfter;
  }
}

export type Campaign = { id: number; name: string; status: string; clientId: number | null };
export function parseCampaigns(value: unknown): Campaign[] {
  if (!Array.isArray(value) || value.length > 10000) throw new ProviderError(502, 'Unexpected Smartlead campaign response.');
  const seen = new Set<number>();
  return value.map(row => {
    if (!row || typeof row !== 'object' || !Number.isSafeInteger(row.id) || row.id < 1
      || typeof row.name !== 'string' || typeof row.status !== 'string'
      || (row.client_id != null && (!Number.isSafeInteger(row.client_id) || row.client_id < 1))
      || seen.has(row.id)) throw new ProviderError(502, 'Unexpected Smartlead campaign response.');
    seen.add(row.id);
    return { id: row.id, name: row.name.slice(0, 300), status: row.status.slice(0, 40), clientId: row.client_id ?? null };
  });
}

export function retryDelay(value: string | null, now = Date.now()) {
  if (!value) return 60;
  const seconds = /^\d+$/.test(value) ? Number(value) : Math.ceil((Date.parse(value) - now) / 1000);
  return Number.isFinite(seconds) ? Math.min(86400, Math.max(1, seconds)) : 60;
}

export async function providerRead(provider: Provider, secret: string, fetcher: typeof fetch = fetch): Promise<unknown> {
  const url = provider === 'smartlead'
    ? new URL('https://server.smartlead.ai/api/v1/campaigns/')
    : new URL('https://app.betterlanebase.link/api/integration/v1/capabilities');
  if (provider === 'smartlead') url.searchParams.set('api_key', secret);
  try {
    const response = await fetcher(url, {
      headers: provider === 'verifier' ? { Authorization: `Bearer ${secret}`, Accept: 'application/json' } : { Accept: 'application/json' },
      method: 'GET', redirect: 'error', cache: 'no-store', signal: AbortSignal.timeout(12000),
    });
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      if (response.status === 401 || response.status === 403) throw new ProviderError(422, 'The provider rejected this credential.');
      if (response.status === 429) throw new ProviderError(429, 'Provider rate limit reached. Try again after the cooldown.', retryDelay(response.headers.get('retry-after')));
      throw new ProviderError(502, 'The provider is unavailable or its integration API is not installed.');
    }
    if (!response.headers.get('content-type')?.includes('application/json')) {
      void response.body?.cancel().catch(() => {});
      throw new ProviderError(502, 'The provider did not return a supported API response.');
    }
    const reader = response.body?.getReader();
    if (!reader) throw new ProviderError(502, 'Empty provider response.');
    const chunks: Uint8Array[] = []; let size = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 4 * 1024 * 1024) throw new ProviderError(502, 'Provider response exceeds the safe size limit.');
        chunks.push(value);
      }
    } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (error) {
    if (error instanceof ProviderError) throw error;
    // Never echo fetch errors: Smartlead credentials live in the URL.
    throw new ProviderError(502, 'Unable to read the provider API. No leads were sent.');
  }
}

export async function checkProvider(provider: Provider, secret: string, fetcher: typeof fetch = fetch) {
  const value = await providerRead(provider, secret, fetcher);
  if (provider === 'smartlead') return { campaigns: parseCampaigns(value) };
  if (!value || typeof value !== 'object' || !('version' in value) || value.version !== 1
    || !('service' in value) || value.service !== 'no2ninja-verifier') {
    throw new ProviderError(502, 'Unsupported verifier integration API version.');
  }
  return { campaigns: [] as Campaign[] };
}
