import { configuredInteger, createAdmissionQueue } from './bounded-admission.ts';
import { recordRequest, routeOf } from './observability.ts';

// PostgREST's pool is 24. Two app slots can overlap during blue/green releases.
// This leaves headroom for other REST callers; Auth and Storage have their own
// database pools. Role connection limits and statement deadlines remain essential:
// abandoning an HTTP request does not reliably cancel its database statement.
// Production measurement: an export abandoned at 2.1s held its backend for 7.9 s.
const queue = createAdmissionQueue(
  configuredInteger('INTERACTIVE_CONCURRENCY', process.env.INTERACTIVE_CONCURRENCY, 8, 1, 8),
  configuredInteger('INTERACTIVE_MAX_WAITING', process.env.INTERACTIVE_MAX_WAITING, 32, 0, 128),
  configuredInteger('INTERACTIVE_ADMISSION_WAIT_MS', process.env.INTERACTIVE_ADMISSION_WAIT_MS, 2000, 0, 5000),
);

export function overloadedResponse(): Response {
  return Response.json({
    error: 'The database is busy right now. Please try again in a moment.',
    code: 'capacity_limited', retryable: true,
  }, { status: 503, headers: { 'Retry-After': '2', 'Cache-Control': 'no-store' } });
}

export async function withInteractiveSlot(request: Request, work: () => Promise<Response>): Promise<Response> {
  const route = routeOf(request.url);
  const requestId = crypto.randomUUID();
  const startedAt = performance.now();
  const release = await queue.acquire(request.signal);
  const admissionMs = performance.now() - startedAt;
  try {
    const response = release ? await work() : overloadedResponse();
    recordRequest(route, response.status, performance.now() - startedAt, { requestId, admissionMs });
    // Preserve streaming bodies, status and cookies; don't buffer an export.
    const headers = new Headers(response.headers);
    headers.set('X-Request-Id', requestId);
    return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
  } catch (error) {
    recordRequest(route, 500, performance.now() - startedAt, { requestId, admissionMs });
    throw error;
  } finally { release?.(); }
}

export const admissionState = queue.state;
// Streaming exports acquire one slot per database call, not per slow download.
export const acquireSlot = queue.acquire;
