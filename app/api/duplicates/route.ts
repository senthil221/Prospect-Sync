import { authorizeApi } from "../../../lib/auth";
import { reindexProspects } from "../../../lib/reindex";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { data, error } = await createAdminClient().rpc("find_duplicate_candidates", { p_limit: 100 });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const result = Array.isArray(data) ? data[0] : data;
  return Response.json({ candidates: result?.result_rows ?? [] });
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
  await reindexProspects(supabase, [keepId]);
  return Response.json({ result: data });
}
