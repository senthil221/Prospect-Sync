import { withInteractiveSlot } from "../../../lib/admission";
import { authorizeFilterSets } from "../../../lib/filter-sets";
import { databaseErrorResponse, isClientDisconnect, isStatementTimeout, statementTimeoutResponse } from "../../../lib/api-errors";
import { authorizeApi, getAuthorizedUser } from "../../../lib/auth";
import { filterErrorResponse, parseFilters, type ProspectFilter } from "../../../lib/prospect-filters";
import { createAdminClient } from "../../../lib/supabase/admin";
import { parseCompanyScope, type CompanyScope } from "../../../lib/workspace-scopes";
import { needsCompanyPreparation } from "../../../lib/prepared-search";
import { ownerIdentity } from "../../../lib/result-sets";
import { prepareCompanyScope, preparationResponse } from "../../../lib/prepare-company-scope";
import { prospectQueryFamily, recordQueryPhase, type QueryPhaseOutcome } from "../../../lib/observability";

type WorkspaceQuery = {
  search: string;
  filters: ProspectFilter[];
  sort: string;
  direction: string;
  limit: number;
  offset: number;
  clientId: string | null;
  companyScope: (CompanyScope & { _prepared_set_id?: string; _prepared_owner?: string }) | null;
  withTotal: boolean;
  knownVersions: Record<string, number> | null;
  signal: AbortSignal | undefined;
};

const missingFunctionCodes = new Set(["PGRST202", "42883"]);

function isMissingFunction(error: { code?: string } | null | undefined) {
  return Boolean(error?.code && missingFunctionCodes.has(error.code));
}

// One current function, no version ladder. Deploys run migrations before the app
// starts (deploy/scripts/update.sh), so a missing function means the database is
// behind - which the caller surfaces as a 503 telling the operator to migrate,
// rather than silently degrading to an older filter contract.
async function runProspectWorkspace(supabase: ReturnType<typeof createAdminClient>, query: WorkspaceQuery) {
  const workspace = await supabase.rpc("search_prospect_workspace_v13", {
    p_search: query.search,
    p_filters: query.filters,
    p_sort: query.sort,
    p_direction: query.direction,
    p_limit: query.limit,
    p_offset: query.offset,
    p_client_id: query.clientId,
    p_company_scope: query.companyScope ?? {},
    p_with_total: query.withTotal,
    p_known_versions: query.knownVersions,
  }).abortSignal(query.signal ?? AbortSignal.timeout(30_000));
  return { ...workspace, version: "v13" };
}

function workspaceSummary(data: unknown) {
  const summary = Array.isArray(data) ? data[0] : data;
  return summary && typeof summary === "object" ? summary as { result_rows?: unknown; total_count?: unknown; scope_capped?: unknown; total_capped?: unknown; data_versions?: unknown } : {};
}

function queryPhaseOutcome(error: unknown): QueryPhaseOutcome {
  if (!error) return "ok";
  if (isStatementTimeout(error as { code?: string })) return "timed_out";
  if (isClientDisconnect(error)) return "cancelled";
  return "error";
}

function queryPhaseResponseOutcome(response: Response | null | undefined): QueryPhaseOutcome {
  if (!response) return "ok";
  if (response.status === 202) return "pending";
  if (response.status >= 500) return response.status === 504 ? "timed_out" : "error";
  return response.status >= 400 ? "client_error" : "ok";
}

// Shared by GET and POST. Same query either way; only the transport differs,
// because a pasted filter list can be far too large for a request line.
async function respondToProspectQuery(params: URLSearchParams, signal?: AbortSignal) {
  const url = { searchParams: params };
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 300);
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const sort = ["created_at", "name", "company", "title", "last_contacted"].includes(url.searchParams.get("sort") ?? "") ? String(url.searchParams.get("sort")) : "created_at";
  const direction = url.searchParams.get("direction") === "asc" ? "asc" : "desc";
  const clientId = (url.searchParams.get("clientId") ?? "").trim() || null;
  let companyScope: CompanyScope | null;
  try { companyScope = parseCompanyScope(url.searchParams.get("companyScope")); }
  catch (error) { return filterErrorResponse(error, "Invalid company navigation scope."); }
  const includeFields = url.searchParams.get("includeFields") !== "0";
  const withTotal = url.searchParams.get("withTotal") === null ? page === 1 : url.searchParams.get("withTotal") !== "0";
  // Opaque to this route: it is handed back to the database, which compares it
  // with the live vector and recounts if they differ. A malformed value simply
  // never matches, which recounts -- the safe direction.
  let knownVersions: Record<string, number> | null = null;
  try {
    const raw = url.searchParams.get("knownVersions");
    const parsed = raw ? JSON.parse(raw) as unknown : null;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) knownVersions = parsed as Record<string, number>;
  } catch { knownVersions = null; }
  const limit = 50;
  let filters: ProspectFilter[];
  try { filters = parseFilters(url.searchParams.get("filters")); }
  catch (error) { return filterErrorResponse(error, "Invalid Boolean filter."); }
  const queryFamily = prospectQueryFamily({ search, filters, clientId, companyScope });
  const supabase = createAdminClient();

  // A set id is not authorization: re-check ownership on every use, before the
  // query that would read the set runs (section 4.1).
  const authorizationStarted = performance.now();
  let user: Awaited<ReturnType<typeof getAuthorizedUser>>;
  let setDenial: Response | null;
  try {
    user = await getAuthorizedUser();
    setDenial = await authorizeFilterSets(supabase, filters, user?.id ?? "", "prospect", clientId ?? "",
      companyScope ? [{ entityType: 'company', clientScope: clientId ?? '', filters: companyScope.filters }] : []);
    recordQueryPhase(queryFamily, "authorization", queryPhaseResponseOutcome(setDenial),
      performance.now() - authorizationStarted);
  } catch (error) {
    recordQueryPhase(queryFamily, "authorization", queryPhaseOutcome(error), performance.now() - authorizationStarted);
    throw error;
  }
  if (setDenial) return setDenial;

  let resolvedScope: WorkspaceQuery['companyScope'] = companyScope;
  if (companyScope && needsCompanyPreparation(companyScope)) {
    const owner = ownerIdentity(user);
    const preparationStarted = performance.now();
    let prepared: Awaited<ReturnType<typeof prepareCompanyScope>>;
    try {
      prepared = await prepareCompanyScope(supabase, owner, companyScope, signal);
      recordQueryPhase(queryFamily, "preparation", queryPhaseResponseOutcome(prepared.response),
        performance.now() - preparationStarted);
    } catch (error) {
      recordQueryPhase(queryFamily, "preparation", queryPhaseOutcome(error), performance.now() - preparationStarted);
      throw error;
    }
    if (prepared.response) return prepared.response;
    resolvedScope = prepared.scope ?? companyScope;
  }

  const workspaceRequest = (async () => {
    const started = performance.now();
    try {
      const result = await runProspectWorkspace(supabase, {
        search,
        filters,
        sort,
        direction,
        limit,
        offset: (page - 1) * limit,
        clientId,
        companyScope: resolvedScope,
        withTotal,
        knownVersions,
        signal,
      });
      const rows = workspaceSummary(result.data).result_rows;
      recordQueryPhase(queryFamily, "workspace", queryPhaseOutcome(result.error), performance.now() - started,
        Array.isArray(rows) ? rows.length : undefined);
      return result;
    } catch (error) {
      recordQueryPhase(queryFamily, "workspace", queryPhaseOutcome(error), performance.now() - started);
      throw error;
    }
  })();
  const fieldsRequest = (async () => {
    const started = performance.now();
    if (!includeFields) return { data: [] as Array<{ field_name: string }>, error: null };
    try {
      const result = await supabase.from("prospect_fields").select("field_name").order("field_name").limit(500);
      recordQueryPhase(queryFamily, "metadata", queryPhaseOutcome(result.error), performance.now() - started,
        result.data?.length);
      return result;
    } catch (error) {
      recordQueryPhase(queryFamily, "metadata", queryPhaseOutcome(error), performance.now() - started);
      throw error;
    }
  })();
  const [workspace, fields] = await Promise.all([workspaceRequest, fieldsRequest]);
  if (isMissingFunction(workspace.error)) {
    return Response.json({ error: "Apply the latest database migration to enable the new prospect filters." }, { status: 503 });
  }
  const error = workspace.error ?? fields.error;
  if (resolvedScope?._prepared_set_id && (error?.code === '40001' || error?.code === 'P0002')) {
    return preparationResponse('refreshing', 0);
  }
  if (isStatementTimeout(error)) {
    return statementTimeoutResponse("This filter combination", "Narrow it - fewer filters, or a search term alongside them - or export the full set instead.");
  }
  if (error) return databaseErrorResponse("The prospect listing", error);
  const summary = workspaceSummary(workspace.data);
  return Response.json({
    prospects: summary.result_rows ?? [],
    total: summary.total_count === null || summary.total_count === undefined ? null : Number(summary.total_count),
    // Every People count is now an exact one, the unscoped whole-database total
    // included: 20260902000260 replaced pg_class.reltuples with count(*) after
    // measuring it at 175-234 ms. The field stays on the wire because the grid
    // still branches on it, and because "this number is an estimate" is a state
    // worth being able to express again if a future total ever has to be one.
    totalEstimated: false,
    // True when the company scope matched more companies than its own cap, so the
    // people shown are drawn from a truncated set. The UI says so rather than
    // presenting a short list as the whole answer.
    scopeCapped: summary.scope_capped === true,
    // The count stopped at its cap, so `total` is a floor and the UI shows
    // "50,000+" rather than presenting a bounded number as an exact one.
    totalCapped: summary.total_capped === true,
    // The vector this answer was computed at. Cache the total against it and
    // send it back; the next request recounts only if something moved.
    versions: summary.data_versions ?? null,
    page,
    limit,
    fields: (fields.data ?? []).map((item) => item.field_name),
  });
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
    companyScope?: unknown;
    clientId?: unknown;
  } | null;
  if (!payload) return Response.json({ error: "Invalid delete request." }, { status: 400 });
  const supabase = createAdminClient();

  // Explicit picks: delete the exact ids (batched so a big `in (...)` never blows the URL).
  if (Array.isArray(payload.ids) && payload.ids.length) {
    const ids = [...new Set(payload.ids.map((id) => String(id).trim()).filter(Boolean))].slice(0, 50000);
    if (!ids.length) return Response.json({ error: "No prospects to delete." }, { status: 400 });
    let deleted = 0;
    for (let index = 0; index < ids.length; index += 500) {
      const batch = ids.slice(index, index + 500);
      const { error, count } = await supabase.from("prospects").delete({ count: "exact" }).in("id", batch);
      if (error) return Response.json({ error: error.message }, { status: 500 });
      deleted += Number(count ?? batch.length);
    }
    return Response.json({ deleted });
  }

  // Everything matching the current search/filters across all pages.
  if (payload.allMatching === true) {
    if (payload.companyScope || payload.clientId) return Response.json({ error: 'Delete selected IDs for a scoped view. Global all-matching deletion cannot discard a pivot or client scope.' }, { status: 400 });
    const search = String(payload.search ?? "").trim().slice(0, 300);
    let filters: ProspectFilter[];
    try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
    catch (error) { return filterErrorResponse(error, "Invalid filter."); }
    const setDenial = await authorizeFilterSets(supabase, filters, (await getAuthorizedUser())?.id ?? '', 'prospect', '');
    if (setDenial) return setDenial;
    const excludedIds = Array.isArray(payload.excludedIds) ? [...new Set(payload.excludedIds.map((id) => String(id).trim()).filter(Boolean))].slice(0, 50000) : [];
    const { data, error } = await supabase.rpc("delete_prospects_matching_v2", {
      p_search: search,
      p_filters: filters,
      p_excluded_ids: excludedIds,
    });
    if (error) {
      return Response.json({ error: isMissingFunction(error) ? "Apply the latest database migration to enable bulk delete." : error.message }, { status: isMissingFunction(error) ? 503 : 500 });
    }
    return Response.json({ deleted: Number(data ?? 0) });
  }

  return Response.json({ error: "Nothing selected to delete." }, { status: 400 });
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  return withInteractiveSlot(request, () => respondToProspectQuery(new URL(request.url).searchParams, request.signal));
}

// Same query, carried in the body.
//
// The People filters accept a pasted list up to maxFilterValues, and
// prospectApiPath puts the whole set in the query string. Node answers 431
// Request Header Fields Too Large once the request line passes its 16KB budget,
// before any application code runs -- measured at roughly 450 values. This is
// the same failure Bulk domains hit on the Company DB, and the same remedy.
export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const body = decoded.value as Record<string, unknown> | null;
  if (!body || typeof body !== "object") {
    return Response.json({ error: "Invalid prospect query." }, { status: 400 });
  }
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(body)) {
    if (value === null || value === undefined) continue;
    params.set(key, typeof value === "string" ? value : JSON.stringify(value));
  }
  return withInteractiveSlot(request, () => respondToProspectQuery(params, request.signal));
}
import { readBoundedJson } from "../../../lib/bounded-json";
