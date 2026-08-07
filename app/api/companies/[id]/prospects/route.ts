import { authorizeApi } from "../../../../../lib/auth";
import { createAdminClient } from "../../../../../lib/supabase/admin";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const url = new URL(request.url);
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const pageSize = Math.max(10, Math.min(100, Number(url.searchParams.get("pageSize") ?? 50)));
  const from = (page - 1) * pageSize;
  const { data, error, count } = await createAdminClient()
    .from("prospect_summaries")
    .select("*", { count: "exact" })
    .eq("company_id", id)
    .order("full_name")
    .range(from, from + pageSize - 1);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ prospects: data ?? [], total: Number(count ?? 0), page, pageSize });
}
