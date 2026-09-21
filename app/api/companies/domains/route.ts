import { authorizeApi, getAuthorizedUser } from "../../../../lib/auth";
import { authorizeFilterSets } from "../../../../lib/filter-sets";
import { filterErrorResponse, parseFilters } from "../../../../lib/prospect-filters";
import { createAdminClient } from "../../../../lib/supabase/admin";
import { parsePeopleScope } from "../../../../lib/workspace-scopes";
import { readBoundedJson } from "../../../../lib/bounded-json";

const missingFunctionCodes = new Set(["PGRST202", "42883"]);

// Copy Domains, for both Company databases. Reuses resolve_company_action_selection_v1
// rather than adding a function of its own - it already does exactly this
// selection (explicit ids, capped to 50,000; or search/filters/peopleScope,
// full-scan, capped to 250,000) for push, tagging and removal, with p_client_id
// null meaning "the master database" built in. The one addition is the cap
// below it: 20,000 domains is already more than a clipboard, an inbox or a
// downstream tool does anything useful with, so the resolver is asked for that
// many rather than its own ceiling.
const maxCopyDomains = 20_000;

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const payload = decoded.value as {
    ids?: unknown;
    allMatching?: unknown;
    search?: unknown;
    filters?: unknown;
    excludedIds?: unknown;
    clientId?: unknown;
    peopleScope?: unknown;
  } | null;
  if (!payload) return Response.json({ error: "Invalid selection." }, { status: 400 });

  const clientId = String(payload.clientId ?? "").trim() || null;
  const ids = Array.isArray(payload.ids)
    ? [...new Set(payload.ids.map((value) => String(value ?? "").trim()).filter(Boolean))]
    : [];
  const excludedIds = Array.isArray(payload.excludedIds)
    ? [...new Set(payload.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))]
    : [];

  if (!ids.length && payload.allMatching !== true) {
    return Response.json({ error: "Select companies, or apply a filter, before copying domains." }, { status: 400 });
  }

  let filters;
  let peopleScope;
  try {
    filters = parseFilters(JSON.stringify(payload.filters ?? []));
    peopleScope = payload.peopleScope ? parsePeopleScope(JSON.stringify(payload.peopleScope)) : null;
  } catch (error) {
    return filterErrorResponse(error, "Invalid company selection.");
  }

  const supabase = createAdminClient();

  // A set id is not authorization: re-check ownership before the filters run,
  // the same guard every other filtered company action makes.
  if (!ids.length) {
    const user = await getAuthorizedUser();
    const setDenial = await authorizeFilterSets(supabase, filters, user?.id ?? "", "company", clientId ?? "",
      peopleScope ? [{ entityType: "prospect", clientScope: clientId ?? "", filters: peopleScope.filters }] : []);
    if (setDenial) return setDenial;
  }

  const { data: resolved, error: resolveError } = await supabase.rpc("resolve_company_action_selection_v1", {
    p_client_id: clientId,
    p_company_ids: ids.length ? ids : null,
    p_search: String(payload.search ?? "").trim().slice(0, 300),
    p_filters: filters,
    p_people_scope: peopleScope,
    p_excluded_ids: excludedIds,
    p_limit: maxCopyDomains,
  });
  if (resolveError) {
    return Response.json({
      error: missingFunctionCodes.has(resolveError.code ?? "") ? "Apply the latest database migration to enable Copy Domains." : resolveError.message,
    }, { status: missingFunctionCodes.has(resolveError.code ?? "") ? 503 : 500 });
  }

  const companyIds = (resolved ?? []).map((row: { company_id: string }) => row.company_id);
  if (!companyIds.length) return Response.json({ domains: [], matched: 0, truncated: false });

  // Batched the same way prospect deletes already are (app/api/prospects/route.ts):
  // an unbatched `.in("id", companyIds)` builds a GET request whose query string
  // grows with every id - past a few hundred UUIDs it blows the URL/header size
  // the proxy in front of PostgREST accepts, and the request fails before a
  // response ever comes back (a raw "TypeError: fetch failed", not a clean
  // error). 20,000 ids unbatched always hit this; 500 stays well under it.
  const domainSet = new Set<string>();
  for (let index = 0; index < companyIds.length; index += 500) {
    const batch = companyIds.slice(index, index + 500);
    const { data: rows, error: domainsError } = await supabase
      .from("companies")
      .select("domain")
      .in("id", batch);
    if (domainsError) return Response.json({ error: domainsError.message }, { status: 500 });
    for (const row of (rows ?? []) as { domain: string | null }[]) {
      const domain = String(row.domain ?? "").trim();
      if (domain) domainSet.add(domain);
    }
  }
  // Blank-free and deduplicated: a company with no recorded website contributes
  // nothing to paste, and two companies sharing a domain should not paste twice.
  const domains = [...domainSet].sort();

  return Response.json({
    domains,
    matched: companyIds.length,
    // The resolver was asked for exactly maxCopyDomains; a full page means there
    // may be more that were not.
    truncated: companyIds.length >= maxCopyDomains,
  });
}
