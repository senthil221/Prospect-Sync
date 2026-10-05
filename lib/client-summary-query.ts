import { isClientDisconnect, isStatementTimeout, type DatabaseError } from "./api-errors.ts";
import {
  recordClientSummaryPhase,
  type ClientSummaryPhase,
  type ClientSummaryScope,
  type QueryPhaseOutcome,
} from "./observability.ts";

export const clientSummaryDeadlineMs = 35_000;

export function clientSummarySignals(callerSignal: AbortSignal, timeoutMs = clientSummaryDeadlineMs) {
  const deadlineSignal = AbortSignal.timeout(timeoutMs);
  return {
    callerSignal,
    deadlineSignal,
    signal: AbortSignal.any([callerSignal, deadlineSignal]),
  };
}

export function clientSummaryPhaseOutcome(
  error: DatabaseError | unknown,
  callerSignal: AbortSignal,
  deadlineSignal: AbortSignal,
): QueryPhaseOutcome {
  if (callerSignal.aborted) return "cancelled";
  if (deadlineSignal.aborted || isStatementTimeout(error as DatabaseError)) return "timed_out";
  if (isClientDisconnect(error)) return "cancelled";
  return error ? "error" : "ok";
}

type QueryResult = { data?: unknown; error?: DatabaseError };

// Supabase builders are PromiseLike rather than native promises. Keeping that
// contract here lets both routes measure their real awaited database work while
// exposing only fixed scope/phase labels.
export async function observeClientSummaryQuery<Result extends QueryResult>(
  scope: ClientSummaryScope,
  phase: ClientSummaryPhase,
  query: PromiseLike<Result>,
  callerSignal: AbortSignal,
  deadlineSignal: AbortSignal,
): Promise<Result> {
  const startedAt = performance.now();
  try {
    const result = await query;
    recordClientSummaryPhase(
      scope,
      phase,
      clientSummaryPhaseOutcome(result.error, callerSignal, deadlineSignal),
      performance.now() - startedAt,
      Array.isArray(result.data) ? result.data.length : undefined,
    );
    return result;
  } catch (error) {
    recordClientSummaryPhase(
      scope,
      phase,
      clientSummaryPhaseOutcome(error, callerSignal, deadlineSignal),
      performance.now() - startedAt,
    );
    throw error;
  }
}
