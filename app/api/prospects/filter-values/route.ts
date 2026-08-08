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

  const { data, error } = await createAdminClient().rpc("prospect_filter_values", {
    p_field: field,
    p_search: search,
    p_client_id: clientId,
    p_limit: limit,
  });

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
