import { authorizeApi } from "../../../lib/auth";
import { parseFilters, type ProspectFilter } from "../../../lib/prospect-filters";
import { createAdminClient } from "../../../lib/supabase/admin";
import { parseCompanyScope, type CompanyScope } from "../../../lib/workspace-scopes";

type WorkspaceQuery = {
  search: string;
  filters: ProspectFilter[];
  sort: string;
  direction: string;
  limit: number;
  offset: number;
  clientId: string | null;
  companyScope: CompanyScope | null;
  withTotal: boolean;
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
  const workspace = await supabase.rpc("search_prospect_workspace_v12", {
    p_search: query.search,
    p_filters: query.filters,
    p_sort: query.sort,
    p_direction: query.direction,
    p_limit: query.limit,
    p_offset: query.offset,
    p_client_id: query.clientId,
    p_company_scope: query.companyScope ?? {},
    p_with_total: query.withTotal,
  });
  return { ...workspace, version: "v12" };
}

function workspaceSummary(data: unknown) {
  const summary = Array.isArray(data) ? data[0] : data;
  return summary && typeof summary === "object" ? summary as { result_rows?: unknown; total_count?: unknown; scope_capped?: unknown } : {};
}

// Shared by GET and POST. Same query either way; only the transport differs,
// because a pasted filter list can be far too large for a request line.
async function respondToProspectQuery(params: URLSearchParams) {
  const url = { searchParams: params };
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 300);
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const sort = ["created_at", "name", "company", "title", "last_contacted"].includes(url.searchParams.get("sort") ?? "") ? String(url.searchParams.get("sort")) : "created_at";
  const direction = url.searchParams.get("direction") === "asc" ? "asc" : "desc";
  const clientId = (url.searchParams.get("clientId") ?? "").trim() || null;
  let companyScope: CompanyScope | null;
  try { companyScope = parseCompanyScope(url.searchParams.get("companyScope")); }
  catch { return Response.json({ error: "Invalid company navigation scope." }, { status: 400 }); }
  const includeFields = url.searchParams.get("includeFields") !== "0";
  const withTotal = url.searchParams.get("withTotal") === null ? page === 1 : url.searchParams.get("withTotal") !== "0";
  const limit = 50;
  let filters: ProspectFilter[];
  try { filters = parseFilters(url.searchParams.get("filters")); }
  catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Invalid Boolean filter." }, { status: 400 }); }
  const supabase = createAdminClient();

  const workspaceRequest = runProspectWorkspace(supabase, {
    search,
    filters,
    sort,
    direction,
    limit,
    offset: (page - 1) * limit,
    clientId,
    companyScope,
    withTotal,
  });
  const fieldsRequest = includeFields
    ? supabase.from("prospect_fields").select("field_name").order("field_name").limit(500)
    : Promise.resolve({ data: [] as Array<{ field_name: string }>, error: null });
  const [workspace, fields] = await Promise.all([workspaceRequest, fieldsRequest]);
  if (isMissingFunction(workspace.error)) {
    return Response.json({ error: "Apply the latest database migration to enable the new prospect filters." }, { status: 503 });
  }
  const error = workspace.error ?? fields.error;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const summary = workspaceSummary(workspace.data);
  // Only the completely unscoped People DB count comes from the planner estimate;
  // every scoped read still returns an exact count. Mirrors v12's total branch.
  const totalEstimated = withTotal && !search && filters.length === 0 && !clientId && !companyScope;
  return Response.json({
    prospects: summary.result_rows ?? [],
    total: summary.total_count === null || summary.total_count === undefined ? null : Number(summary.total_count),
    totalEstimated,
    // True when the company scope matched more companies than its own cap, so the
    // people shown are drawn from a truncated set. The UI says so rather than
    // presenting a short list as the whole answer.
    scopeCapped: summary.scope_capped === true,
    page,
    limit,
    fields: (fields.data ?? []).map((item) => item.field_name),
  });
}

export async function DELETE(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as {
    ids?: unknown;
    allMatching?: unknown;
    search?: unknown;
    filters?: unknown;
    excludedIds?: unknown;
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
    const search = String(payload.search ?? "").trim().slice(0, 300);
    let filters: ProspectFilter[];
    try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
    catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Invalid filter." }, { status: 400 }); }
    const excludedIds = Array.isArray(payload.excludedIds) ? [...new Set(payload.excludedIds.map((id) => String(id).trim()).filter(Boolean))].slice(0, 50000) : [];
    const { data, error } = await supabase.rpc("delete_prospects_matching_v1", {
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
  return respondToProspectQuery(new URL(request.url).searchParams);
}

// Same query, carried in the body.
//
// The People filters accept a pasted list up to maxFilterValues (1000), and
// prospectApiPath puts the whole set in the query string. Node answers 431
// Request Header Fields Too Large once the request line passes its 16KB budget,
// before any application code runs -- measured at roughly 450 values. This is
// the same failure Bulk domains hit on the Company DB, and the same remedy.
export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!body || typeof body !== "object") {
    return Response.json({ error: "Invalid prospect query." }, { status: 400 });
  }
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(body)) {
    if (value === null || value === undefined) continue;
    params.set(key, typeof value === "string" ? value : JSON.stringify(value));
  }
  return respondToProspectQuery(params);
}
