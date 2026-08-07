import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const search = (new URL(request.url).searchParams.get("search") ?? "").trim().replace(/[,()]/g, " ");
  let query = createAdminClient().from("company_summaries").select("*");
  if (search) query = query.or(`name.ilike.%${search}%,domain.ilike.%${search}%`);
  const { data, error } = await query.order("prospect_count", { ascending: false }).order("name").limit(100);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ companies: data ?? [] });
}
