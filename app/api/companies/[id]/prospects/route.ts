import { authorizeApi } from "../../../../../lib/auth";
import { createAdminClient } from "../../../../../lib/supabase/admin";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const url = new URL(request.url);
  const limit = Math.max(1, Math.min(100, Number(url.searchParams.get("limit") ?? 50)));
  const { data, error, count } = await createAdminClient()
    .from("prospect_summaries")
    .select("*", { count: "exact" })
    .eq("company_id", id)
    .order("full_name")
    .limit(limit);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ prospects: data ?? [], total: Number(count ?? 0), limit });
}
