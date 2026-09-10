import { withAnalyticsSlot } from "../../../lib/admission";
import { authorizeApi } from "../../../lib/auth";
import { isStatementTimeout, statementTimeoutResponse } from "../../../lib/api-errors";
import { indexNotice, reindexProspects } from "../../../lib/reindex.ts";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  // The heaviest query in the application: a self-join of prospect_summaries on
  // an unindexed lower(trim(full_name)). Bounded here so it cannot take the
  // connection pool, and by a statement timeout so it cannot run unbounded.
  return withAnalyticsSlot(request, async () => {
    const { data, error } = await createAdminClient()
      .rpc("find_duplicate_candidates", { p_limit: 100 })
      .abortSignal(request.signal ?? AbortSignal.timeout(120_000));
    if (isStatementTimeout(error)) {
      return statementTimeoutResponse("Finding duplicates", "Try again when imports have finished.");
    }
    if (error) return Response.json({ error: error.message }, { status: 500 });
    const result = Array.isArray(data) ? data[0] : data;
    return Response.json({ candidates: result?.result_rows ?? [] });
  });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { keepId, mergeId } = await request.json() as { keepId?: string; mergeId?: string };
  if (!keepId || !mergeId || keepId === mergeId) return Response.json({ error: "Choose two different prospects." }, { status: 400 });
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("merge_prospects", { p_keep_id: keepId, p_merge_id: mergeId });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  // The merged prospect is removed (cascades out of the index); refresh the survivor.
  const outcome = await reindexProspects(supabase, [keepId]);
  return Response.json({ result: data, notice: indexNotice(outcome) });
}
