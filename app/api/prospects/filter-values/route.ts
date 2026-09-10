import { withInteractiveSlot } from "../../../../lib/admission";
import { isStatementTimeout, statementTimeoutResponse } from "../../../../lib/api-errors";
import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  return withInteractiveSlot(request, () => suggestValues(request));
}

// Typing in a filter box is the highest-frequency database call there is, so it
// is admitted through the same guard as everything else rather than being
// treated as free.
async function suggestValues(request: Request) {

  const url = new URL(request.url);
  const field = (url.searchParams.get("field") ?? "").trim().slice(0, 160);
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 160);
  const clientId = (url.searchParams.get("clientId") ?? "").trim() || null;
  const limit = Math.max(1, Math.min(100, Number(url.searchParams.get("limit") ?? 50) || 50));
  if (!field) return Response.json({ error: "Choose a filter field." }, { status: 400 });

  const supabase = createAdminClient();
  const missing = (result: { error?: { code?: string } | null }) => result.error?.code === "PGRST202" || result.error?.code === "42883";

  // The three job-title classifier fields have their own values function. They live
  // on prospect_index only -- prospect_filter_values_* reads the prospect_summaries
  // view, whose fixed column list predates them.
  if (["__title_department", "__title_sub_department", "__title_seniority_tier"].includes(field)) {
    const classified = await supabase.rpc("title_class_filter_values_v1", {
      p_field: field,
      p_search: search,
      p_client_id: clientId,
      p_limit: limit,
    }).abortSignal(request.signal ?? AbortSignal.timeout(30_000));
    if (classified.error) {
      const migrationMissing = missing(classified);
      return Response.json(
        { error: migrationMissing ? "Apply the latest database migration to enable job title classifier filters." : classified.error.message },
        { status: migrationMissing ? 503 : 500 },
      );
    }
    return Response.json({
      values: (classified.data ?? []).map((item: { value: unknown; match_count: unknown }) => ({ value: String(item.value), count: Number(item.match_count ?? 0) })),
    });
  }

  // v3 reads the flat prospect_index. It has no fallback: update.sh applies
  // migrations before the candidate app container starts, and a rollback
  // deliberately does not undo them, so a deployed app never runs against a
  // database without v3. The v2 and v1 chains that used to be here could only
  // fire in a state that cannot occur, and both carried a predicate that a
  // generic plan turns into a full scan - see 20260910150000.
  const result = await supabase.rpc("prospect_filter_values_v3", {
    p_field: field,
    p_search: search,
    p_client_id: clientId,
    p_limit: limit,
  }).abortSignal(request.signal ?? AbortSignal.timeout(30_000));

  const { data, error } = result;

  if (isStatementTimeout(error)) {
    return statementTimeoutResponse("Loading values for this field", "Type a few more characters to narrow the list, or enter the value directly.");
  }
  if (error) {
    const migrationMissing = error.code === "PGRST202" || error.code === "42883";
    return Response.json(
      { error: migrationMissing ? "Apply the latest database migration to enable database-wide filter values." : error.message },
      { status: migrationMissing ? 503 : 500 },
    );
  }

  return Response.json({
    values: (data ?? []).map((item: { value: unknown; match_count: unknown }) => ({ value: String(item.value), count: Number(item.match_count ?? 0) })),
  });
}
