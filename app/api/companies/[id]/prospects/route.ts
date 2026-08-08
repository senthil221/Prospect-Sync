import { authorizeApi } from "../../../../../lib/auth";
import { createAdminClient } from "../../../../../lib/supabase/admin";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const url = new URL(request.url);
  const clientId = (url.searchParams.get("clientId") ?? "").trim();
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const pageSize = Math.max(10, Math.min(100, Number(url.searchParams.get("pageSize") ?? 50)));
  const from = (page - 1) * pageSize;
  const supabase = createAdminClient();
  if (clientId) {
    const { data, error } = await supabase.rpc("client_company_prospects", {
      p_client_id: clientId,
      p_company_id: id,
      p_limit: pageSize,
      p_offset: from,
    });
    if (error) return Response.json({ error: error.code === "PGRST202" || error.code === "42883" ? "Apply the latest database migration to enable client workspaces." : error.message }, { status: error.code === "PGRST202" || error.code === "42883" ? 503 : 500 });
    const summary = Array.isArray(data) ? data[0] : data;
    return Response.json({ prospects: summary?.result_rows ?? [], total: Number(summary?.total_count ?? 0), page, pageSize });
  }
  const { data, error, count } = await supabase
    .from("prospect_summaries")
    .select("*", { count: "exact" })
    .eq("company_id", id)
    .order("full_name")
    .range(from, from + pageSize - 1);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ prospects: data ?? [], total: Number(count ?? 0), page, pageSize });
}
