import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const workspace = await supabase.rpc("dashboard_workspace");
  if (!workspace.error) {
    const row = Array.isArray(workspace.data) ? workspace.data[0] : workspace.data;
    return Response.json(row?.result ?? { stats: {}, recentImports: [] });
  }
  if (workspace.error.code !== "PGRST202" && workspace.error.code !== "42883") {
    return Response.json({ error: workspace.error.message }, { status: 500 });
  }

  // Keep older environments usable until the performance migration is applied.
  const [prospects, companies, clients, lists, importTotals, recentProspects, recentCompanies] = await Promise.all([
    supabase.from("prospects").select("id", { count: "exact", head: true }),
    supabase.from("companies").select("id", { count: "exact", head: true }),
    supabase.from("clients").select("id", { count: "exact", head: true }),
    supabase.from("lists").select("id", { count: "exact", head: true }),
    supabase.from("imports").select("processed_rows, duplicates_linked"),
    supabase.from("imports").select("id,file_name,data_source,status,processed_rows,unique_added,duplicates_linked,created_at,client:clients(name),list:lists(name)").eq("status", "completed").order("created_at", { ascending: false }).limit(12),
    supabase.from("company_imports").select("id,file_name,data_source,status,processed_rows,added_count,updated_count,skipped_count,created_at").eq("status", "completed").order("created_at", { ascending: false }).limit(12),
  ]);
  const companyImportsUnavailable = recentCompanies.error?.code === "PGRST205" || recentCompanies.error?.code === "42P01";
  const failure = [prospects, companies, clients, lists, importTotals, recentProspects, ...(companyImportsUnavailable ? [] : [recentCompanies])].find((result) => result.error)?.error;
  if (failure) return Response.json({ error: failure.message }, { status: 500 });
  const totals = (importTotals.data ?? []).reduce((acc, item) => ({
    rows: acc.rows + Number(item.processed_rows ?? 0), duplicates: acc.duplicates + Number(item.duplicates_linked ?? 0),
  }), { rows: 0, duplicates: 0 });
  const prospectImports = (recentProspects.data ?? []).map((item) => {
    const client = item.client as unknown as { name?: string } | Array<{ name?: string }> | null;
    const list = item.list as unknown as { name?: string } | Array<{ name?: string }> | null;
    return {
      ...item,
      kind: "prospects" as const,
      client_name: Array.isArray(client) ? client[0]?.name : client?.name,
      list_name: Array.isArray(list) ? list[0]?.name : list?.name,
    };
  });
  const companyImports = (recentCompanies.data ?? []).map((item) => ({ ...item, kind: "companies" as const }));
  const recentImports = [...prospectImports, ...companyImports]
    .sort((left, right) => Date.parse(right.created_at) - Date.parse(left.created_at))
    .slice(0, 12);
  return Response.json({
    stats: { prospects: prospects.count ?? 0, companies: companies.count ?? 0, clients: clients.count ?? 0, lists: lists.count ?? 0, rowsImported: totals.rows, duplicatesDetected: totals.duplicates },
    recentImports,
  });
}
