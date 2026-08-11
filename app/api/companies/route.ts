import { authorizeApi } from "../../../lib/auth";
import { csvDocument } from "../../../lib/csv";
import { normalizeDomain } from "../../../db/normalize";
import { createAdminClient } from "../../../lib/supabase/admin";

function parseList(raw: string | null, transform: (value: string) => string = (value) => value.trim()) {
  const seen = new Set<string>();
  const values: string[] = [];
  for (const part of (raw ?? "").split(",")) {
    const value = transform(part);
    if (!value) continue;
    const key = value.toLocaleLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    values.push(value);
  }
  return values;
}

const exportBatchSize = 1000;

function websiteUrl(domain: string) {
  return /^https?:\/\//i.test(domain) ? domain : `https://${domain}`;
}

async function exportCompanies(search: string, websitesOnly: boolean, domains: string[], seniority: string[], locations: string[]) {
  const supabase = createAdminClient();
  const rows: Array<{ name: string; domain: string }> = [];
  const hasFilters = domains.length > 0 || seniority.length > 0 || locations.length > 0;
  let offset = 0;

  for (;;) {
    let rawCount: number;
    let batch: Array<{ name?: string | null; domain?: string | null }>;
    if (hasFilters) {
      // Honour the on-screen filters by paging through the same function the UI uses.
      const { data, error } = await supabase.rpc("filter_companies", {
        p_search: search, p_domains: domains, p_seniority: seniority, p_locations: locations,
        p_client_id: null, p_limit: exportBatchSize, p_offset: offset,
      });
      if (error) return { error: error.message, csv: "", count: 0 };
      const summary = Array.isArray(data) ? data[0] : data;
      const page = (summary?.result_rows ?? []) as Array<{ name?: string | null; domain?: string | null }>;
      rawCount = page.length;
      batch = websitesOnly ? page.filter((company) => String(company.domain ?? "").trim()) : page;
    } else {
      let query = supabase
        .from("companies")
        .select("id,name,domain")
        .order("name", { ascending: true })
        .order("id", { ascending: true })
        .range(offset, offset + exportBatchSize - 1);
      if (websitesOnly) query = query.neq("domain", "");
      if (search) query = query.or(`name.ilike.%${search}%,domain.ilike.%${search}%`);
      const result = await query;
      if (result.error) return { error: result.error.message, csv: "", count: 0 };
      rawCount = (result.data ?? []).length;
      batch = websitesOnly ? (result.data ?? []).filter((company) => String(company.domain ?? "").trim()) : (result.data ?? []);
    }
    rows.push(...batch.map((company) => ({ name: String(company.name ?? ""), domain: String(company.domain ?? "").trim() })));
    if (rawCount < exportBatchSize) break;
    offset += exportBatchSize;
  }

  const csv = csvDocument(
    ["Company Name", "Website"],
    rows.map((company) => [company.name || company.domain || "Unnamed company", company.domain ? websiteUrl(company.domain) : ""]),
  );
  return { error: "", csv, count: rows.length };
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim().replace(/[,()]/g, " ");
  const clientId = (url.searchParams.get("clientId") ?? "").trim();
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const pageSize = Math.max(10, Math.min(100, Number(url.searchParams.get("pageSize") ?? 50)));
  const from = (page - 1) * pageSize;
  const exportCsv = url.searchParams.get("export") === "csv";
  const websitesOnly = url.searchParams.get("website") === "required";
  const domains = parseList(url.searchParams.get("domains"), (value) => normalizeDomain(value));
  const seniority = parseList(url.searchParams.get("seniority"));
  const locations = parseList(url.searchParams.get("locations"));

  if (exportCsv) {
    if (clientId) return Response.json({ error: "Client-scoped company export is not available." }, { status: 400 });
    const result = await exportCompanies(search, websitesOnly, domains, seniority, locations);
    if (result.error) return Response.json({ error: result.error }, { status: 500 });
    return new Response(result.csv, {
      headers: {
        "Cache-Control": "no-store",
        "Content-Disposition": `attachment; filename="prospect-sync-companies-${websitesOnly ? "with-websites-" : "all-"}${new Date().toISOString().slice(0, 10)}.csv"`,
        "Content-Type": "text/csv; charset=utf-8",
        "X-Exported-Rows": String(result.count),
      },
    });
  }

  const supabase = createAdminClient();

  // Domain / seniority / location filters run through filter_companies, which
  // also handles client scoping via p_client_id — so a filtered client-company
  // view goes here too, while the unfiltered client view keeps its dedicated RPC.
  if (domains.length || seniority.length || locations.length) {
    const { data, error } = await supabase.rpc("filter_companies", {
      p_search: search,
      p_domains: domains,
      p_seniority: seniority,
      p_locations: locations,
      p_client_id: clientId || null,
      p_limit: pageSize,
      p_offset: from,
    });
    if (error) {
      const migrationMissing = error.code === "PGRST202" || error.code === "42883";
      return Response.json({ error: migrationMissing ? "Apply the latest database migration to enable company filters." : error.message }, { status: migrationMissing ? 503 : 500 });
    }
    const summary = Array.isArray(data) ? data[0] : data;
    return Response.json({
      companies: summary?.result_rows ?? [],
      total: Number(summary?.total_count ?? 0),
      covered: Number(summary?.covered_count ?? 0),
      prospectTotal: Number(summary?.prospect_total ?? 0),
      page,
      pageSize,
    });
  }

  if (clientId) {
    const { data, error } = await supabase.rpc("client_company_workspace", {
      p_client_id: clientId,
      p_search: search,
      p_limit: pageSize,
      p_offset: from,
    });
    if (error) return Response.json({ error: error.code === "PGRST202" || error.code === "42883" ? "Apply the latest database migration to enable client workspaces." : error.message }, { status: error.code === "PGRST202" || error.code === "42883" ? 503 : 500 });
    const summary = Array.isArray(data) ? data[0] : data;
    return Response.json({
      companies: summary?.result_rows ?? [],
      total: Number(summary?.total_count ?? 0),
      covered: Number(summary?.covered_count ?? 0),
      prospectTotal: Number(summary?.prospect_count ?? 0),
      page,
      pageSize,
    });
  }

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
