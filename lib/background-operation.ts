import { api } from "./dashboard-api.ts";
import type { WireFilter } from "./filter-set-client.ts";

// The browser half of background result sets and frozen bulk actions.
//
// Two things the interactive path cannot do, and they are the same shape:
// build the full id list behind a question, and then act on exactly that list.
// Both take longer than a request may last, so both are "ask, then watch".
//
// POLLING OPTS OUT OF THE RESPONSE CACHE. api() caches GETs for five minutes,
// which would make a status poll return the first answer forever. `cache:
// "no-store"` is the documented way out and is not optional here.
//
// THE WAIT IS BOUNDED. A build that never finishes must eventually say so
// rather than spinning until the tab closes. The deadline is generous because
// the work genuinely is minutes long; what it rules out is silence.

export type ResultSetStatus = {
  setId: string;
  status: "pending" | "building" | "ready" | "failed" | string;
  rowCount: number;
  stale?: boolean;
  error?: string | null;
};

export type JobStatus = {
  jobId: string;
  status: "pending" | "frozen" | "running" | "completed" | "failed" | string;
  totalItems: number;
  appliedItems: number;
  excludedCount?: number;
  error?: string | null;
  result?: Record<string, number> | null;
};

export type Progress = {
  phase: "building" | "applying";
  done: number;
  total: number;
};

const firstDelayMs = 600;
const maxDelayMs = 4000;
const defaultDeadlineMs = 15 * 60_000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

class Aborted extends Error {
  constructor() { super("Aborted"); this.name = "AbortError"; }
}

// Grows the gap between polls so a four-minute build is not four hundred
// requests, while a set that is already ready still answers almost at once.
async function poll<T>(
  read: () => Promise<T>,
  finished: (value: T) => boolean,
  options: { signal?: AbortSignal; deadlineMs?: number; onTick?: (value: T) => void },
): Promise<T> {
  const until = Date.now() + (options.deadlineMs ?? defaultDeadlineMs);
  let delay = firstDelayMs;
  for (;;) {
    if (options.signal?.aborted) throw new Aborted();
    const value = await read();
    options.onTick?.(value);
    if (finished(value)) return value;
    if (Date.now() > until) {
      throw new Error("This is taking longer than expected. It is still running - reopen the page later to see the result.");
    }
    await sleep(delay);
    delay = Math.min(maxDelayMs, Math.round(delay * 1.5));
  }
}

// Ask for the ids behind a question and wait until they exist.
//
// A reused set that is already ready comes back on the first poll, so asking
// the same question twice costs one request rather than a second build.
export async function buildResultSet(
  input: { entityType: "prospect" | "company"; clientScope?: string; search: string; filters: WireFilter[] },
  options: { signal?: AbortSignal; onProgress?: (progress: Progress) => void; deadlineMs?: number } = {},
): Promise<ResultSetStatus> {
  const requested = await api<ResultSetStatus>("/api/result-sets", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      entityType: input.entityType,
      clientScope: input.clientScope ?? "",
      search: input.search,
      filters: input.filters,
    }),
    signal: options.signal,
  });
  if (requested.status === "ready") return requested;

  const settled = await poll<ResultSetStatus>(
    () => api<ResultSetStatus>(`/api/result-sets?id=${encodeURIComponent(requested.setId)}`, { cache: "no-store", signal: options.signal }),
    (value) => value.status === "ready" || value.status === "failed",
    {
      signal: options.signal,
      deadlineMs: options.deadlineMs,
      // rowCount climbs as the worker inserts batches, so this is real progress
      // rather than a spinner. The total is not known until it finishes, which
      // is the honest thing to show: a count nobody has finished counting.
      onTick: (value) => options.onProgress?.({ phase: "building", done: value.rowCount, total: 0 }),
    },
  );
  if (settled.status === "failed") {
    throw new Error(settled.error || "That set could not be built. Narrow the filters and try again.");
  }
  return settled;
}

// Run a bulk action over a frozen result set, and wait for the worker to finish
// applying it.
//
// The request id is the caller's, and deliberately so: it belongs to the user's
// intent (lib/request-intent.ts), so a retry of this whole flow after a dropped
// connection is recognised as the same operation rather than run twice.
export async function runFrozenAction(
  input: {
    clientId: string;
    action: string;
    requestId: string;
    resultSetId: string;
    search: string;
    filters: WireFilter[];
    excludedIds: string[];
    dateContacted?: string | null;
  },
  options: { signal?: AbortSignal; onProgress?: (progress: Progress) => void; deadlineMs?: number } = {},
): Promise<JobStatus> {
  const started = await api<{ jobId: string; totalItems: number; result?: Record<string, number> | null; replayed?: boolean }>(
    `/api/clients/${encodeURIComponent(input.clientId)}/prospects`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: input.action,
        requestId: input.requestId,
        resultSetId: input.resultSetId,
        search: input.search,
        filters: input.filters,
        excludedIds: input.excludedIds,
        ...(input.action === "set_date_contacted" ? { dateContacted: input.dateContacted ?? null } : {}),
      }),
      signal: options.signal,
    },
  );

  // A replay of an already-completed operation answers with its recorded result
  // and no job to watch. That is the idempotency working, not a failure.
  if (started.replayed) {
    return { jobId: started.jobId, status: "completed", totalItems: started.totalItems ?? 0, appliedItems: started.totalItems ?? 0, result: started.result ?? null };
  }

  const settled = await poll<JobStatus>(
    () => api<JobStatus>(`/api/operations?jobId=${encodeURIComponent(started.jobId)}`, { cache: "no-store", signal: options.signal }),
    (value) => value.status === "completed" || value.status === "failed",
    {
      signal: options.signal,
      deadlineMs: options.deadlineMs,
      onTick: (value) => options.onProgress?.({ phase: "applying", done: value.appliedItems, total: value.totalItems }),
    },
  );
  if (settled.status === "failed") {
    // Whatever it applied before failing stays applied and is counted, so the
    // message says how far it got rather than implying nothing happened.
    throw new Error(settled.error || `That action stopped after ${settled.appliedItems} of ${settled.totalItems}. Nothing was undone; run it again to continue.`);
  }
  return settled;
}
