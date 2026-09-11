import { withAnalyticsSlot } from "../../../lib/admission";
import { isStatementTimeout, statementTimeoutResponse } from "../../../lib/api-errors";
import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

function isMissing(error: { code?: string } | null | undefined) {
  return Boolean(error?.code && missingFunctionCodes.has(error.code));
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  return withAnalyticsSlot(request, () => qualitySummary(request));
}

async function qualitySummary(request: Request) {
  const supabase = createAdminClient();
  const signal = request.signal ?? AbortSignal.timeout(120_000);
  // Read, do not compute. Both of these scan the whole database - 12.2s and
  // 13.3s today, and past their own ceilings at 10M rows - so the operations
  // worker computes them once per data version and this reads one row each.
  const [quality, drift] = await Promise.all([
    supabase.rpc("dashboard_snapshot_v1", { p_key: "dataQuality" }).abortSignal(signal),
    supabase.rpc("dashboard_snapshot_v1", { p_key: "indexDrift" }).abortSignal(signal),
  ]);
  if (isStatementTimeout(quality.error)) {
    return statementTimeoutResponse("The data quality summary", "Try again when imports have finished.");
  }
  if (quality.error) return Response.json({ error: quality.error.message }, { status: 500 });
  // Drift reporting is additive: an older database still returns the quality
  // overview rather than failing the whole page.
  const snapshot = (result: { data?: unknown }) => (result.data as { payload?: unknown } | null)?.payload ?? null;
  const computedAt = (result: { data?: unknown }) => (result.data as { computedAt?: string } | null)?.computedAt ?? null;
  return Response.json({
    quality: snapshot(quality) ?? {},
    drift: drift.error ? null : snapshot(drift),
    // Said plainly rather than implied: after an import these lag by one
    // refresh cycle, and the tab can show as-of rather than pretending it is live.
    computedAt: computedAt(quality),
    current: (quality.data as { current?: boolean } | null)?.current ?? null,
  });
}

// Drain the re-index backlog. Loops until the queue empties or the budget runs
// out, so one click clears a backlog rather than nibbling at it.
export async function POST() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const deadline = Date.now() + 45_000;
  let processed = 0;
  let remaining = 0;

  for (let pass = 0; pass < 25; pass += 1) {
    const { data, error } = await supabase.rpc("drain_reindex_backlog", { p_limit: 2000 });
    if (error) {
      return Response.json(
        { error: isMissing(error) ? "Apply the latest database migration to enable re-index recovery." : error.message },
        { status: isMissing(error) ? 503 : 500 },
      );
    }
    const row = Array.isArray(data) ? data[0] : data;
    const done = Number(row?.processed ?? 0);
    remaining = Number(row?.remaining ?? 0);
    processed += done;
    // No progress means the queue is empty, or every row in it is failing -
    // either way, stop rather than spinning.
    if (!done || !remaining || Date.now() > deadline) break;
  }

  return Response.json({ processed, remaining });
}
