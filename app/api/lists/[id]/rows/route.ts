import { authorizeApi } from "../../../../../lib/auth";
import { createAdminClient } from "../../../../../lib/supabase/admin";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 300);
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const limit = 50;
  const { data, error } = await createAdminClient().rpc("list_workspace", {
    p_list_id: id,
    p_search: search,
    p_limit: limit,
    p_offset: (page - 1) * limit,
  });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const summary = Array.isArray(data) ? data[0] : data;
  return Response.json({ rows: summary?.result_rows ?? [], total: Number(summary?.total_count ?? 0), page, limit });
}
