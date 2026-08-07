import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim().replace(/[,()]/g, " ");
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const pageSize = Math.max(10, Math.min(100, Number(url.searchParams.get("pageSize") ?? 50)));
  const from = (page - 1) * pageSize;
  const supabase = createAdminClient();

  let companiesQuery = supabase.from("company_summaries").select("*", { count: "exact" });
  let coveredQuery = supabase.from("company_summaries").select("id", { count: "exact", head: true }).gt("prospect_count", 0);
  let prospectQuery = supabase.from("prospect_summaries").select("id", { count: "exact", head: true }).not("company_id", "is", null);
  if (search) {
    companiesQuery = companiesQuery.or(`name.ilike.%${search}%,domain.ilike.%${search}%`);
    coveredQuery = coveredQuery.or(`name.ilike.%${search}%,domain.ilike.%${search}%`);
    prospectQuery = prospectQuery.or(`company_name.ilike.%${search}%,company_domain.ilike.%${search}%`);
  }

  const [companies, covered, prospects] = await Promise.all([
    companiesQuery.order("prospect_count", { ascending: false }).order("name").range(from, from + pageSize - 1),
    coveredQuery,
    prospectQuery,
  ]);
  const failure = [companies, covered, prospects].find((result) => result.error)?.error;
  if (failure) return Response.json({ error: failure.message }, { status: 500 });
  return Response.json({
    companies: companies.data ?? [],
    total: Number(companies.count ?? 0),
    covered: Number(covered.count ?? 0),
    prospectTotal: Number(prospects.count ?? 0),
    page,
    pageSize,
  });
}
