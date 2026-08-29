import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

function isMissing(error: { code?: string } | null | undefined) {
  return Boolean(error?.code && missingFunctionCodes.has(error.code));
}

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const [quality, drift] = await Promise.all([
    supabase.rpc("data_quality_overview"),
    supabase.rpc("prospect_index_drift"),
  ]);
  if (quality.error) return Response.json({ error: quality.error.message }, { status: 500 });
  // Drift reporting is additive: an older database still returns the quality
  // overview rather than failing the whole page.
  return Response.json({
    quality: quality.data ?? {},
    drift: drift.error ? null : drift.data ?? null,
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
