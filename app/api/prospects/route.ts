import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim().replace(/[,()]/g, " ");
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const limit = 30;
  const from = (page - 1) * limit;
  let query = createAdminClient().from("prospect_summaries").select("*", { count: "exact" });
  if (search) query = query.or(`full_name.ilike.%${search}%,work_email.ilike.%${search}%,title.ilike.%${search}%,company_name.ilike.%${search}%,company_domain.ilike.%${search}%`);
  const { data, count, error } = await query.order("created_at", { ascending: false }).range(from, from + limit - 1);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ prospects: data ?? [], total: count ?? 0, page, limit });
}
