// Measure the user's wait through every 202, not the enqueue response latency.
// Match the application's read-only POST transport for large query payloads.
// Otherwise the over-cap test measures a proxy's 431, not the API's 413.
export function readJourneyRequest(path) {
  if (!path.startsWith('/api/')) throw new Error('A load journey must use a relative API path');
  const url = new URL(path, 'https://load.invalid');
  if (url.origin !== 'https://load.invalid') throw new Error('Invalid load path');
  if (path.length > 6000 && ['/api/prospects', '/api/companies'].includes(url.pathname)) {
    return {method:'POST',path:url.pathname,data:Object.fromEntries(url.searchParams)};
  }
  return {method:'GET',path};
}

export async function runReadJourney(send, { deadlineMs = 150000, pause = ms => new Promise(r => setTimeout(r, ms)), now = () => performance.now() } = {}) {
  const started = now();
  let pendingResponses = 0;
  for (;;) {
    const remaining = deadlineMs - (now() - started);
    if (remaining <= 0) return { status: 0, durationMs: now() - started, pendingResponses, deadlineExceeded: true };
    const response = await send(Math.min(60000, remaining));
    const status = response.status();
    if (status !== 202) return { status, durationMs: now() - started, pendingResponses, deadlineExceeded: false };
    pendingResponses++;
    const body = await response.json();
    if (!body?.preparation?.status) throw new Error('Unexpected 202 without preparation state');
    const retry = Number(response.headers()['retry-after']);
    const delay = Number.isFinite(retry) && retry > 0 ? Math.min(retry * 1000, 5000) : 1000;
    await pause(Math.max(0, Math.min(delay, deadlineMs - (now() - started))));
  }
}

export function expectedStatus(status, expected = 200, overloadTest = false) {
  return status === expected || (overloadTest && status === 503);
}

export function validateLoadTarget(baseURL, allowRemote) {
  const url = new URL(baseURL);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Load target must be HTTP(S)');
  if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) && !allowRemote) {
    throw new Error('Remote load tests require LOAD_ALLOW_REMOTE=1 and an explicitly approved staging/test target.');
  }
}
