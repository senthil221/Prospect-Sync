import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

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
    });
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

  // v3 reads the flat prospect_index; v2 (identical semantics) is the fallback before migration.
  let result = await supabase.rpc("prospect_filter_values_v3", {
    p_field: field,
    p_search: search,
    p_client_id: clientId,
    p_limit: limit,
  });
  if (missing(result)) {
    result = await supabase.rpc("prospect_filter_values_v2", {
      p_field: field,
      p_search: search,
      p_client_id: clientId,
      p_limit: limit,
    });
  }

  const requiresV2 = field.startsWith("custom:") || ["__first_name", "__last_name", "__keywords", "__person_location", "__company_location", "__company_city", "__company_state", "__company_country"].includes(field);
  if (!requiresV2 && missing(result)) {
    result = await supabase.rpc("prospect_filter_values", {
      p_field: field,
      p_search: search,
      p_client_id: clientId,
      p_limit: limit,
    });
  }
  const { data, error } = result;

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
