const endpoint = 'https://happy.mailtester.ninja/ninja';
const accountFailure = /\b(key|quota|subscription|credit|expired|suspend|disabled|unauthor)/i;

export function normalizeMtnKey(value) {
  return String(value ?? '').trim().replace(/^["'{]+|["'}]+$/g, '').trim();
}
const normalized = value => String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
const normalizedEmail = value => String(value ?? '').trim().toLowerCase();

export function classifyMtnResult(code, message) {
  const detail = normalized(message);
  if (accountFailure.test(detail)) return { kind: 'account', reason: String(message ?? '').trim() || 'Account failure' };
  if (detail === 'limited') return { kind: 'transient', reason: 'Limited' };
  if (normalized(code) === 'ok') return { kind: 'result', status: 'valid', reason: String(message ?? '').trim() || 'Accepted' };
  if (normalized(code) === 'ko') return { kind: 'result', status: 'invalid', reason: String(message ?? '').trim() || 'Rejected' };
  if (normalized(code) === 'mb' && detail === 'catch-all') return { kind: 'result', status: 'catch_all', reason: 'Catch-All' };
  if (normalized(code) === 'mb' || ['mx error', 'timeout', 'spam block'].includes(detail)) {
    return { kind: 'transient', reason: String(message ?? '').trim() || 'Unverifiable' };
  }
  if (detail === 'accepted') return { kind: 'result', status: 'valid', reason: 'Accepted' };
  if (['rejected', 'no mx'].includes(detail)) return { kind: 'result', status: 'invalid', reason: String(message).trim() };
  if (detail === 'catch-all') return { kind: 'result', status: 'catch_all', reason: 'Catch-All' };
  return { kind: 'malformed', reason: 'Unrecognized provider response' };
}

export function retryAfterMilliseconds(value, now = Date.now()) {
  if (!value) return 10_000;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(1_000, Math.min(seconds * 1000, 86_400_000));
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(1_000, Math.min(date - now, 86_400_000)) : 10_000;
}

export class MtnRequestError extends Error {
  constructor(code, { retryAfterMs = 0, providerPauseMs = 0 } = {}) {
    super(`Mail verification request failed (${code})`);
    this.name = 'MtnRequestError';
    this.code = code;
    this.retryAfterMs = retryAfterMs;
    this.providerPauseMs = providerPauseMs;
  }
}

export async function verifyWithMtn(email, { apiKey, fetchImpl = fetch, timeoutMs = 45_000 } = {}) {
  const key = normalizeMtnKey(apiKey);
  if (!key) throw new MtnRequestError('not_configured', { providerPauseMs: 3600_000 });
  const expected = normalizedEmail(email);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(expected)) throw new MtnRequestError('malformed_address');
  const url = new URL(endpoint);
  url.searchParams.set('email', expected);
  url.searchParams.set('key', key);
  let response;
  try {
    response = await fetchImpl(url, { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(timeoutMs) });
  } catch (error) {
    const code = error?.name === 'TimeoutError' || error?.name === 'AbortError' ? 'timeout' : 'network';
    throw new MtnRequestError(code);
  }
  if (response.status === 429) {
    throw new MtnRequestError('rate_limited', { retryAfterMs: retryAfterMilliseconds(response.headers.get('retry-after')) });
  }
  if (response.status === 401 || response.status === 403) throw new MtnRequestError('auth', { providerPauseMs: 3600_000 });
  if (!response.ok) throw new MtnRequestError(response.status >= 500 ? 'provider_outage' : 'http_error', {
    providerPauseMs: response.status >= 500 ? 60_000 : 0,
  });
  let body;
  try { body = await response.json(); } catch { throw new MtnRequestError('malformed'); }
  if (!body || typeof body !== 'object' || typeof body.code !== 'string' || typeof body.message !== 'string') {
    throw new MtnRequestError('malformed');
  }
  const classification = classifyMtnResult(body.code, body.message);
  if (classification.kind === 'account') throw new MtnRequestError('account', { providerPauseMs: 3600_000 });
  // Some account-level responses omit the echoed email. Recognize those before
  // the echo check so the provider is paused for human attention; successful
  // or mailbox-level responses still require an exact address match.
  if (normalizedEmail(body.email) !== expected) throw new MtnRequestError('email_mismatch');
  if (classification.kind === 'malformed') throw new MtnRequestError('malformed');
  return classification;
}

export const MTN_ENDPOINT = endpoint;
