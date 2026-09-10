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

// Analytical surfaces - Duplicates, Data Quality, Coverage, Enrichment - are
// not page loads. Measured against real traffic: find_duplicate_candidates
// averages 38.2s and peaks at 60.7s, data_quality_overview averages 12.2s.
// They ran with no admission slot at all until now, which is how one open tab
// became everyone's outage: on 2026-09-10 at 18:00 UTC a Data Quality open ran
// data_quality_overview and prospect_index_drift together, ordinary /api/prospects
// requests went from ~1s to 5-8s under the contention, the interactive queue
// filled, and browsing started returning 503 and 500.
//
// A separate, smaller queue rather than a share of the interactive one, because
// the two failure modes are different. Eight concurrent 38-second queries would
// hold eight of PostgREST's 24 connections for half a minute; two cannot. And
// putting them in the interactive queue would let a report starve the browsing
// it is supposed to sit beside. Worst case is now 8 interactive + 2 analytical
// = 10 of 24, leaving the headroom the pool was sized for.
const analytics = createAdmissionQueue(
  configuredInteger('ANALYTICS_CONCURRENCY', process.env.ANALYTICS_CONCURRENCY, 2, 1, 4),
  configuredInteger('ANALYTICS_MAX_WAITING', process.env.ANALYTICS_MAX_WAITING, 8, 0, 64),
  // Longer than the interactive 2s: a report is worth waiting in line for, and
  // refusing it after two seconds would break a working feature to no purpose.
  configuredInteger('ANALYTICS_ADMISSION_WAIT_MS', process.env.ANALYTICS_ADMISSION_WAIT_MS, 15000, 0, 30000),
);

async function withSlot(queue: { acquire: typeof acquireSlot }, request: Request, work: () => Promise<Response>): Promise<Response> {
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

export async function withInteractiveSlot(request: Request, work: () => Promise<Response>): Promise<Response> {
  return withSlot(queue, request, work);
}

// For the seconds-to-a-minute reports. Same refusal shape as interactive, so a
// caller that already handles 503 needs no change.
export async function withAnalyticsSlot(request: Request, work: () => Promise<Response>): Promise<Response> {
  return withSlot(analytics, request, work);
}

export const admissionState = queue.state;
export const analyticsState = analytics.state;
// Streaming exports acquire one slot per database call, not per slow download.
export const acquireSlot = queue.acquire;
