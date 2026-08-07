import { authorizeApi } from "../../../lib/auth";
import { normalizeDomain, normalizeText } from "../../../db/normalize";
import { createAdminClient } from "../../../lib/supabase/admin";

type IncomingCompany = { name?: string; domain?: string; row?: number };

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json() as { companies?: IncomingCompany[] };
  const incoming = (payload.companies ?? []).slice(0, 5000).map((company, index) => ({
    row: Number(company.row ?? index + 2),
    name: String(company.name ?? "").trim(),
    domain: normalizeDomain(String(company.domain ?? "")),
    normalizedName: normalizeText(String(company.name ?? "")),
  })).filter((company) => company.domain || company.normalizedName);
  if (!incoming.length) return Response.json({ error: "No usable company names or domains were found." }, { status: 400 });

  const supabase = createAdminClient();
  const domainValues = [...new Set(incoming.map((company) => company.domain).filter(Boolean))];
  const nameValues = [...new Set(incoming.map((company) => company.normalizedName).filter(Boolean))];
  const found: Array<{ id: string; name: string; domain: string; normalized_domain: string; normalized_name: string }> = [];
  for (let index = 0; index < domainValues.length; index += 400) {
    const result = await supabase.from("companies").select("id,name,domain,normalized_domain,normalized_name").in("normalized_domain", domainValues.slice(index, index + 400));
    if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
    found.push(...(result.data ?? []));
  }
  for (let index = 0; index < nameValues.length; index += 400) {
    const result = await supabase.from("companies").select("id,name,domain,normalized_domain,normalized_name").in("normalized_name", nameValues.slice(index, index + 400));
    if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
    found.push(...(result.data ?? []));
  }
  const uniqueFound = [...new Map(found.map((company) => [company.id, company])).values()];
  const summaries = uniqueFound.length ? await supabase.from("company_summaries").select("id,prospect_count,client_count").in("id", uniqueFound.map((company) => company.id)) : { data: [], error: null };
  if (summaries.error) return Response.json({ error: summaries.error.message }, { status: 500 });
  const counts = new Map((summaries.data ?? []).map((summary) => [summary.id, summary]));
  const byDomain = new Map(uniqueFound.filter((company) => company.normalized_domain).map((company) => [company.normalized_domain, company]));
  const byName = new Map(uniqueFound.filter((company) => company.normalized_name).map((company) => [company.normalized_name, company]));
  const rows = incoming.map((company) => {
    const match = (company.domain && byDomain.get(company.domain)) || byName.get(company.normalizedName);
    const summary = match ? counts.get(match.id) : undefined;
    return { ...company, status: match ? "known" : "new", matchedBy: match ? (company.domain && match.normalized_domain === company.domain ? "domain" : "name") : "", matchedCompany: match?.name ?? "", prospectCount: Number(summary?.prospect_count ?? 0), clientCount: Number(summary?.client_count ?? 0) };
  });
  return Response.json({
    rows,
    summary: { total: rows.length, known: rows.filter((row) => row.status === "known").length, new: rows.filter((row) => row.status === "new").length, covered: rows.filter((row) => row.prospectCount > 0).length, existingProspects: rows.reduce((total, row) => total + row.prospectCount, 0) },
  });
}
