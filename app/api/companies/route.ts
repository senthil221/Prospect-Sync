import { acquireSlot, withInteractiveSlot } from "../../../lib/admission";
import { authorizeFilterSets } from "../../../lib/filter-sets";
import { isStatementTimeout, statementTimeoutResponse } from "../../../lib/api-errors";
import { authorizeApi, getAuthorizedUser } from "../../../lib/auth";
import { companyExportColumns } from "../../../lib/company-export";
import { csvHeaderLine, csvRowsBody, type ProspectRow } from "../../../lib/prospect-export";
import { createAdminClient } from "../../../lib/supabase/admin";
import { filterErrorResponse, parseFilters, type ProspectFilter } from "../../../lib/prospect-filters";
import { parsePeopleScope, type PeopleScope } from "../../../lib/workspace-scopes";
import { needsCompanyPreparation } from "../../../lib/prepared-search";
import { prepareCompanyScope, preparationResponse } from "../../../lib/prepare-company-scope";
import { ownerIdentity } from "../../../lib/result-sets";

// One keyset page. It was 1,000 when each page was a fresh OFFSET scan and
// making them larger made the quadratic worse; a keyset page costs the same
// whether it is the first or the hundredth, so bigger means fewer round trips.
const exportBatchSize = 5000;
const missingCompanyValidationCodes = new Set(["PGRST205", "42P01"]);
const missingCompanyExportCodes = new Set(["PGRST202", "42883", "42P01"]);
const BOM = "﻿";
const CRLF = "\r\n";
// A page refused by the admission guard waits and asks again rather than
// breaking a download that has already started; see the prospect export route.
const slotRetries = 8;
const slotRetryMs = 2500;

async function withClientIcpValidation(
  supabase: ReturnType<typeof createAdminClient>,
  rows: Array<Record<string, unknown>>,
  clientId: string,
) {
  if (!clientId || !rows.length) return rows;
  const ids = rows.map((company) => String(company.id ?? "")).filter(Boolean);
  const result = await supabase
    .from("client_company_icp_validations")
    .select("company_id")
    .eq("client_id", clientId)
    .in("company_id", ids);
  if (result.error) {
    if (result.error.code && missingCompanyValidationCodes.has(result.error.code)) {
      return rows.map((company) => ({ ...company, icp_validated: false }));
    }
    throw new Error(result.error.message);
  }
  const validatedIds = new Set((result.data ?? []).map((item) => item.company_id));
  return rows.map((company) => ({ ...company, icp_validated: validatedIds.has(String(company.id ?? "")) }));
}

// The company export, as a keyset stream.
//
// What it replaces paged public.companies with OFFSET - `offset += 1000` with
// no upper bound - and pushed every row into one string before writing a byte.
// Both halves of that are what section 9.4 rules out: a deep OFFSET re-reads
// and discards the whole prefix on every page, so the hundredth page costs a
// hundred times the first, and the accumulated string is the whole file held in
// the application while the user waits with no sign of progress.
//
// search_company_export_v1 walks (lower(name), id) instead, which is total,
// indexed, and stable while companies are being inserted underneath it. Pages
// are rendered and dropped as they arrive, so nothing here grows with the size
// of the export.
async function streamCompanyExport(
  search: string,
  websitesOnly: boolean,
  filters: ProspectFilter[],
  peopleScope: PeopleScope | null,
  signal?: AbortSignal,
) {
  const supabase = createAdminClient();
  type Row = { id?: string; name?: string | null; domain?: string | null; sort_name?: string | null };
  type Cursor = { name: string; id: string } | null;

  async function readPage(cursor: Cursor) {
    // One admission slot per page rather than one for the whole download: the
    // time between pages is the client reading, and holding an interactive slot
    // through that would take it out of circulation for minutes.
    let release: (() => void) | null = null;
    for (let attempt = 0; attempt <= slotRetries && !release; attempt += 1) {
      release = await acquireSlot(signal);
      if (!release && attempt < slotRetries) await new Promise((resolve) => setTimeout(resolve, slotRetryMs));
    }
    if (!release) throw new Error("The database stayed busy for too long, so this export stopped rather than queueing behind it.");
    try {
      return await supabase.rpc("search_company_export_v1", {
        p_search: search,
        p_filters: filters,
        p_people_scope: peopleScope,
        p_websites_only: websitesOnly,
        p_after_name: cursor?.name ?? null,
        p_after_id: cursor?.id ?? null,
        p_limit: exportBatchSize,
      }).abortSignal(signal ?? AbortSignal.timeout(120_000));
    } finally {
      release();
    }
  }

  const rowsOf = (data: unknown): Row[] => {
    const summary = Array.isArray(data) ? data[0] : data;
    const rows = (summary as { result_rows?: unknown } | null)?.result_rows;
    return Array.isArray(rows) ? rows.filter((row): row is Row => Boolean(row) && typeof row === "object") : [];
  };

  // The first page runs before a byte is sent, so a missing migration or a
  // timeout is still a status code and a message rather than an empty file.
  let first;
  try { first = await readPage(null); }
  catch (error) { return { response: Response.json({ error: error instanceof Error ? error.message : "Unable to export companies." }, { status: 503 }) }; }
  if (first.error) {
    if (missingCompanyExportCodes.has(first.error.code ?? "")) {
      return { response: Response.json({ error: "Apply the latest database migration to enable company exports." }, { status: 503 }) };
    }
    return { response: Response.json({ error: first.error.message }, { status: 500 }) };
  }

  const cursorAfter = (rows: Row[], previous: Cursor): Cursor => {
    const last = rows.at(-1);
    // sort_name is lower(name) as PostgreSQL computed it. Lower-casing the name
    // here instead would be a different function under a different collation,
    // and a cursor that disagrees with the ORDER BY skips or repeats rows.
    return last ? { name: String(last.sort_name ?? ""), id: String(last.id ?? "") } : previous;
  };

  let pending: Row[] | null = rowsOf(first.data);
  let cursor: Cursor = cursorAfter(pending, null);
  let exhausted = pending.length < exportBatchSize;
  let written = 0;
  const encoder = new TextEncoder();

  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (pending === null) {
        if (exhausted) { controller.close(); return; }
        const page = await readPage(cursor);
        if (page.error) throw new Error(page.error.message);
        const rows = rowsOf(page.data);
        cursor = cursorAfter(rows, cursor);
        exhausted = rows.length < exportBatchSize;
        pending = rows;
      }
      const rows = pending;
      pending = null;
      const head = written === 0 ? BOM + csvHeaderLine(companyExportColumns) + CRLF : "";
      const body = rows.length ? (written === 0 ? "" : CRLF) + csvRowsBody(rows as ProspectRow[], companyExportColumns) : "";
      written += rows.length;
      if (head || body) controller.enqueue(encoder.encode(head + body));
      if (exhausted) controller.close();
    },
  });

  return { response: new Response(stream, {
    status: 200,
    headers: {
      "Cache-Control": "no-store",
      "Content-Disposition": `attachment; filename="prospect-sync-companies-${websitesOnly ? "with-websites-" : "all-"}${new Date().toISOString().slice(0, 10)}.csv"`,
      "Content-Type": "text/csv; charset=utf-8",
      "X-Accel-Buffering": "no",
    },
  }) };
}

export async function DELETE(request: Request) {
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
    peopleScope?: unknown;
    clientId?: unknown;
  } | null;
  if (!payload) return Response.json({ error: "Invalid delete request." }, { status: 400 });
  const supabase = createAdminClient();
  const missing = (error: { code?: string } | null) => error?.code === "PGRST202" || error?.code === "42883";

  if (Array.isArray(payload.ids) && payload.ids.length) {
    const ids = [...new Set(payload.ids.map((id) => String(id).trim()).filter(Boolean))].slice(0, 50000);
    if (!ids.length) return Response.json({ error: "No companies to delete." }, { status: 400 });
    const { data, error } = await supabase.rpc("delete_companies_by_ids_v1", { p_ids: ids });
    if (error) return Response.json({ error: missing(error) ? "Apply the latest database migration to enable company delete." : error.message }, { status: missing(error) ? 503 : 500 });
    return Response.json({ deleted: Number(data ?? 0) });
  }

  if (payload.allMatching === true) {
    if (payload.peopleScope || payload.clientId) return Response.json({ error: 'Delete selected IDs for a scoped view. Global all-matching deletion cannot discard a pivot or client scope.' }, { status: 400 });
    const search = String(payload.search ?? "").trim().replace(/[,()]/g, " ");
    let filters: ProspectFilter[];
    try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
    catch (error) { return filterErrorResponse(error, "Invalid company filters."); }
    const setDenial = await authorizeFilterSets(supabase, filters, (await getAuthorizedUser())?.id ?? '', 'company', '');
    if (setDenial) return setDenial;
    const excludedIds = Array.isArray(payload.excludedIds) ? [...new Set(payload.excludedIds.map((id) => String(id).trim()).filter(Boolean))].slice(0, 50000) : [];
    const { data, error } = await supabase.rpc("delete_companies_matching_v1", { p_search: search, p_filters: filters, p_excluded_ids: excludedIds });
    if (error) return Response.json({ error: missing(error) ? "Apply the latest database migration to enable company delete." : error.message }, { status: missing(error) ? 503 : 500 });
    return Response.json({ deleted: Number(data ?? 0) });
  }

  return Response.json({ error: "Nothing selected to delete." }, { status: 400 });
}

// Shared by GET and POST. The query is identical either way; only how it arrives
// differs, because a filter set can be far too large to survive a request line.
async function respondToCompanyQuery(params: URLSearchParams, signal?: AbortSignal) {
  const url = { searchParams: params };
  const search = (url.searchParams.get("search") ?? "").trim().replace(/[,()]/g, " ");
  const clientId = (url.searchParams.get("clientId") ?? "").trim();
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const pageSize = Math.max(10, Math.min(100, Number(url.searchParams.get("pageSize") ?? 50)));
  const from = (page - 1) * pageSize;
  const exportCsv = url.searchParams.get("export") === "csv";
  const websitesOnly = url.searchParams.get("website") === "required";

  let filters: ProspectFilter[];
  try { filters = parseFilters(url.searchParams.get("filters")); }
  catch (error) { return filterErrorResponse(error, "Invalid company filters."); }

  let peopleScope: PeopleScope | null;
  try { peopleScope = parsePeopleScope(url.searchParams.get("peopleScope")); }
  catch (error) { return filterErrorResponse(error, "Invalid people navigation scope."); }

  // Opaque to this route: handed back to the database, which compares it with
  // the live vector and recounts if they differ. A malformed value never
  // matches, which recounts - the safe direction.
  let knownVersions: Record<string, number> | null = null;
  try {
    const raw = url.searchParams.get("knownVersions");
    const parsed = raw ? JSON.parse(raw) as unknown : null;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) knownVersions = parsed as Record<string, number>;
  } catch { knownVersions = null; }

  // A set id is not authorization: re-check ownership on every use.
  const setDenial = await authorizeFilterSets(createAdminClient(), filters, (await getAuthorizedUser())?.id ?? "", "company", clientId,
    peopleScope ? [{ entityType: 'prospect', clientScope: clientId, filters: peopleScope.filters }] : []);
  if (setDenial) return setDenial;

  if (exportCsv) {
    if (clientId) return Response.json({ error: "Client-scoped company export is not available." }, { status: 400 });
    const { response } = await streamCompanyExport(search, websitesOnly, filters, peopleScope, signal);
    return response;
  }

  const supabase = createAdminClient();

  if (clientId) {
    const { data, error } = await supabase.rpc("client_company_workspace_v2", {
      p_client_id: clientId,
      p_search: search,
      p_filters: filters,
      p_people_scope: peopleScope,
      p_limit: pageSize,
      p_offset: from,
    });
    if (error) return Response.json({ error: error.code === "PGRST202" || error.code === "42883" ? "Apply the latest database migration to enable client company memberships." : error.message }, { status: error.code === "PGRST202" || error.code === "42883" ? 503 : 500 });
    const summary = Array.isArray(data) ? data[0] : data;
    let companies;
    try { companies = await withClientIcpValidation(supabase, summary?.result_rows ?? [], clientId); }
    catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Unable to load company verification." }, { status: 500 }); }
    return Response.json({ companies, total: Number(summary?.total_count ?? 0), totalCapped: Boolean(summary?.total_capped), covered: Number(summary?.covered_count ?? 0), prospectTotal: Number(summary?.prospect_count ?? 0), page, pageSize });
  }

  // Company-column filters (and the People-DB pivot scope) run through
  // filter_companies_v4, which also handles client scoping via p_client_id -- so a
  // filtered client-company view goes here too, while the unfiltered client view
  // keeps its dedicated RPC.
  if (filters.length || peopleScope) {
    let preparedSetId: string | null = null;
    const owner = ownerIdentity(await getAuthorizedUser());
    const scope = { search, filters, limit: 250000 };
    if (!peopleScope && needsCompanyPreparation(scope)) {
      const prepared = await prepareCompanyScope(supabase, owner, scope, signal);
      if (prepared.response) return prepared.response;
      preparedSetId = prepared.scope?._prepared_set_id ?? null;
    }
    const listing = preparedSetId ? supabase.rpc('prepared_company_listing_v1', {
      p_owner_id: owner, p_set_id: preparedSetId, p_search: search, p_filters: filters,
      p_limit: pageSize, p_offset: from, p_known_versions: knownVersions,
    }) : supabase.rpc("filter_companies_v4", {
      p_search: search,
      p_filters: filters,
      p_client_id: clientId || null,
      p_people_scope: peopleScope,
      p_limit: pageSize,
      p_offset: from,
      p_known_versions: knownVersions,
    });
    const { data, error } = await listing.abortSignal(signal ?? AbortSignal.timeout(40_000));
    if (preparedSetId && (error?.code === '40001' || error?.code === 'P0002')) return preparationResponse('refreshing');
    if (isStatementTimeout(error)) {
      return statementTimeoutResponse("This filter combination", "Narrow it - fewer filters, or a search term alongside them - or export the full set instead.");
    }
    if (error) {
      const migrationMissing = error.code === "PGRST202" || error.code === "42883";
      return Response.json({ error: migrationMissing ? "Apply the latest database migration to enable company filters." : error.message }, { status: migrationMissing ? 503 : 500 });
    }
    const summary = Array.isArray(data) ? data[0] : data;
    let companies;
    try { companies = await withClientIcpValidation(supabase, summary?.result_rows ?? [], clientId); }
    catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Unable to load company validation." }, { status: 500 }); }
    // Counting companies is exact now, not capped at 50,000, so the answer is
    // worth reusing: null means "you already have this count and the data has
    // not moved", and the client fills it from its own cache. Only null when the
    // caller sent a version vector that still matches.
    const counted = summary?.total_count !== null && summary?.total_count !== undefined;
    return Response.json({
      companies,
      total: counted ? Number(summary?.total_count) : null,
      totalCapped: Boolean(summary?.total_capped),
      covered: counted ? Number(summary?.covered_count ?? 0) : null,
      prospectTotal: counted ? Number(summary?.prospect_total ?? 0) : null,
      versions: summary?.data_versions ?? null,
      page,
      pageSize,
    });
  }

  let companiesQuery = supabase.from("company_summaries").select("*", { count: "exact" });
  let coveredQuery = supabase.from("company_summaries").select("id", { count: "exact", head: true }).gt("prospect_count", 0);
  if (search) {
    companiesQuery = companiesQuery.or(`name.ilike.%${search}%,domain.ilike.%${search}%`);
    coveredQuery = coveredQuery.or(`name.ilike.%${search}%,domain.ilike.%${search}%`);
  }

  // prospect_summaries is a live aggregating view - it joins lists and clients and
  // computes count(DISTINCT ...) per prospect - so counting rows through it re-ran
  // that aggregation for all 674,804 prospects to produce one number: 26.1s cold,
  // 10.7s mean warm, on every unfiltered page load. prospect_index is the
  // denormalized form of the same data and answers it in 321ms.
  const [companies, covered, prospects] = await Promise.all([
    companiesQuery.order("prospect_count", { ascending: false }).order("name").range(from, from + pageSize - 1),
    coveredQuery,
    supabase.rpc("linked_prospect_total_v1", { p_search: search }),
  ]);
  const failure = [companies, covered, prospects].find((result) => result.error)?.error;
  if (isStatementTimeout(failure)) {
    return statementTimeoutResponse("The company directory", "Search for a name or domain to narrow it.");
  }
  if (failure) return Response.json({ error: failure.message }, { status: 500 });
  return Response.json({
    companies: companies.data ?? [],
    total: Number(companies.count ?? 0),
    covered: Number(covered.count ?? 0),
    prospectTotal: Number(prospects.data ?? 0),
    page,
    pageSize,
  });
}

// A listing is one query and takes a slot for its whole life. An export is
// dozens of queries with bytes going to the client in between, and takes a slot
// per page instead - holding one for the whole download would remove it from
// the interactive pool for as long as the browser takes to write the file.
function answerCompanyQuery(request: Request, params: URLSearchParams) {
  if (params.get("export") === "csv") return respondToCompanyQuery(params, request.signal);
  return withInteractiveSlot(request, () => respondToCompanyQuery(params, request.signal));
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  return answerCompanyQuery(request, new URL(request.url).searchParams);
}

// Same query, carried in the body.
//
// Bulk domains pastes up to maxFilterValues values into the __website
// filter, and companyApiPath puts the whole filter set in the query string.
// Measured against production: 400 domains is a 12.9KB URL and is accepted, 600
// is 19.3KB and Node answers 431 Request Header Fields Too Large before any of
// our code runs. So every bulk paste past roughly 450 domains failed -- which is
// most of the point of the feature.
//
// Raising Node's --max-http-header-size would only move the wall; a request line
// is the wrong place for kilobytes of filter values. The client switches to this
// once the URL would get close to the limit.
export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const body = decoded.value as Record<string, unknown> | null;
  if (!body || typeof body !== "object") {
    return Response.json({ error: "Invalid company query." }, { status: 400 });
  }
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(body)) {
    if (value === null || value === undefined) continue;
    params.set(key, typeof value === "string" ? value : JSON.stringify(value));
  }
  return answerCompanyQuery(request, params);
}
import { readBoundedJson } from "../../../lib/bounded-json";
