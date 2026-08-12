import { authorizeApi } from "../../../lib/auth";
import { parseFilters, type ProspectFilter } from "../../../lib/prospect-filters";
import { availableExportFieldIds, prospectsCsv, type ProspectRow } from "../../../lib/prospect-export";
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
};

const missingFunctionCodes = new Set(["PGRST202", "42883"]);
const exportPageSize = 100;
const exportConcurrency = 5;

function isMissingFunction(error: { code?: string } | null | undefined) {
  return Boolean(error?.code && missingFunctionCodes.has(error.code));
}

async function runProspectWorkspace(supabase: ReturnType<typeof createAdminClient>, query: WorkspaceQuery) {
  const legacyFilters = query.filters.filter((filter) => !["__esp", "__email_provider_type"].includes(filter.field));
  const v6OnlyFields = new Set(["__first_name", "__last_name", "__keywords", "__person_location", "__company_location", "__company_city", "__company_state", "__company_country", "__employee_count"]);
  const requiresV6 = query.filters.some((filter) => v6OnlyFields.has(filter.field) || filter.field.startsWith("custom:") || ["boolean", "number_ranges"].includes(filter.operator));
  // v7 reads the flat prospect_index (fast at any size); v6 is the identical-semantics fallback
  // used automatically until the search-index migration is applied.
  let workspace = query.companyScope ? await supabase.rpc("search_prospect_workspace_v8", {
    p_search: query.search,
    p_filters: query.filters,
    p_sort: query.sort,
    p_direction: query.direction,
    p_limit: query.limit,
    p_offset: query.offset,
    p_client_id: query.clientId,
    p_company_scope: query.companyScope,
  }) : await supabase.rpc("search_prospect_workspace_v7", {
    p_search: query.search,
    p_filters: query.filters,
    p_sort: query.sort,
    p_direction: query.direction,
    p_limit: query.limit,
    p_offset: query.offset,
    p_client_id: query.clientId,
  });
  if (query.companyScope) return workspace;
  if (isMissingFunction(workspace.error)) {
    workspace = await supabase.rpc("search_prospect_workspace_v6", {
      p_search: query.search,
      p_filters: query.filters,
      p_sort: query.sort,
      p_direction: query.direction,
      p_limit: query.limit,
      p_offset: query.offset,
      p_client_id: query.clientId,
    });
  }
  if (isMissingFunction(workspace.error)) {
    if (requiresV6) return workspace;
    workspace = await supabase.rpc("search_prospect_workspace_v5", {
      p_search: query.search,
      p_filters: legacyFilters.filter((filter) => !["boolean", "number_ranges"].includes(filter.operator)),
      p_sort: query.sort,
      p_direction: query.direction,
      p_limit: query.limit,
      p_offset: query.offset,
      p_client_id: query.clientId,
    });
  }
  if (isMissingFunction(workspace.error)) {
    workspace = await supabase.rpc("search_prospect_workspace_v4", {
      p_search: query.search,
      p_filters: legacyFilters,
      p_sort: query.sort,
      p_direction: query.direction,
      p_limit: query.limit,
      p_offset: query.offset,
      p_client_id: query.clientId,
    });
  }
  if (isMissingFunction(workspace.error)) {
    if (query.clientId) return workspace;
    workspace = await supabase.rpc("search_prospect_workspace_v3", {
      p_search: query.search,
      p_filters: legacyFilters,
      p_sort: query.sort,
      p_direction: query.direction,
      p_limit: query.limit,
      p_offset: query.offset,
    });
  }
  if (isMissingFunction(workspace.error)) {
    workspace = await supabase.rpc("search_prospect_workspace", {
      p_search: query.search,
      p_filters: legacyFilters.filter((filter) => !["not_contains", "not_equals"].includes(filter.operator)),
      p_limit: query.limit,
      p_offset: query.offset,
    });
  }
  return workspace;
}

function workspaceSummary(data: unknown) {
  const summary = Array.isArray(data) ? data[0] : data;
  return summary && typeof summary === "object" ? summary as { result_rows?: unknown; total_count?: unknown } : {};
}

function workspaceRows(data: unknown): ProspectRow[] {
  const rows = workspaceSummary(data).result_rows;
  return Array.isArray(rows) ? rows.filter((row): row is ProspectRow => Boolean(row) && typeof row === "object") : [];
}

async function exportProspects(supabase: ReturnType<typeof createAdminClient>, query: Omit<WorkspaceQuery, "limit" | "offset">) {
  const firstPageRequest = runProspectWorkspace(supabase, { ...query, limit: exportPageSize, offset: 0 });
  const fieldsRequest = supabase.from("prospect_fields").select("field_name").order("field_name").limit(500);
  const [firstPage, fields] = await Promise.all([firstPageRequest, fieldsRequest]);
  const firstError = firstPage.error ?? fields.error;
  if (firstError) return { error: firstError, rows: [] as ProspectRow[], fields: [] as string[] };

  const total = Number(workspaceSummary(firstPage.data).total_count ?? 0);
  const rows = workspaceRows(firstPage.data);
  const offsets = Array.from({ length: Math.max(0, Math.ceil(total / exportPageSize) - 1) }, (_, index) => (index + 1) * exportPageSize);
  for (let index = 0; index < offsets.length; index += exportConcurrency) {
    const pages = await Promise.all(offsets.slice(index, index + exportConcurrency).map((offset) =>
      runProspectWorkspace(supabase, { ...query, limit: exportPageSize, offset }),
    ));
    const failure = pages.find((page) => page.error)?.error;
    if (failure) return { error: failure, rows: [] as ProspectRow[], fields: [] as string[] };
    pages.forEach((page) => rows.push(...workspaceRows(page.data)));
  }
  return { error: null, rows, fields: (fields.data ?? []).map((field) => String(field.field_name ?? "")).filter(Boolean) };
}

function exportResponse(rows: ProspectRow[], fields: string[], requestedFields: string[] | undefined, clientId: string | null) {
  return new Response(prospectsCsv(rows, fields, requestedFields), {
    headers: {
      "Cache-Control": "no-store",
      "Content-Disposition": `attachment; filename="prospect-sync-prospects-${clientId ? "client-" : "all-"}${new Date().toISOString().slice(0, 10)}.csv"`,
      "Content-Type": "text/csv; charset=utf-8",
      "X-Exported-Rows": String(rows.length),
    },
  });
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 300);
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const sort = ["created_at", "name", "company", "title", "last_contacted"].includes(url.searchParams.get("sort") ?? "") ? String(url.searchParams.get("sort")) : "created_at";
  const direction = url.searchParams.get("direction") === "asc" ? "asc" : "desc";
  const clientId = (url.searchParams.get("clientId") ?? "").trim() || null;
  let companyScope: CompanyScope | null;
  try { companyScope = parseCompanyScope(url.searchParams.get("companyScope")); }
  catch { return Response.json({ error: "Invalid company navigation scope." }, { status: 400 }); }
  const includeFields = url.searchParams.get("includeFields") !== "0";
  const exportCsv = url.searchParams.get("export") === "csv";
  const limit = 50;
  let filters: ProspectFilter[];
  try { filters = parseFilters(url.searchParams.get("filters")); }
  catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Invalid Boolean filter." }, { status: 400 }); }
  const supabase = createAdminClient();

  if (exportCsv) {
    const result = await exportProspects(supabase, { search, filters, sort, direction, clientId, companyScope });
    if (isMissingFunction(result.error)) {
      return Response.json({ error: "Apply the latest database migration to enable the new prospect filters." }, { status: 503 });
    }
    if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
    return exportResponse(result.rows, result.fields, undefined, clientId);
  }

  const workspaceRequest = runProspectWorkspace(supabase, {
    search,
    filters,
    sort,
    direction,
    limit,
    offset: (page - 1) * limit,
    clientId,
    companyScope,
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
  return Response.json({
    prospects: summary.result_rows ?? [],
    total: Number(summary.total_count ?? 0),
    page,
    limit,
    fields: (fields.data ?? []).map((item) => item.field_name),
  });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as {
    search?: unknown;
    filters?: unknown;
    sort?: unknown;
    direction?: unknown;
    clientId?: unknown;
    fields?: unknown;
    companyScope?: unknown;
    selection?: { mode?: unknown; ids?: unknown; excludedIds?: unknown };
  } | null;
  if (!payload) return Response.json({ error: "Invalid export request." }, { status: 400 });
  const search = String(payload.search ?? "").trim().slice(0, 300);
  let filters: ProspectFilter[];
  try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
  catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Invalid Boolean filter." }, { status: 400 }); }
  const sortValue = String(payload.sort ?? "created_at");
  const sort = ["created_at", "name", "company", "title", "last_contacted"].includes(sortValue) ? sortValue : "created_at";
  const direction = payload.direction === "asc" ? "asc" : "desc";
  const clientId = String(payload.clientId ?? "").trim() || null;
  let companyScope: CompanyScope | null;
  try { companyScope = parseCompanyScope(payload.companyScope ? JSON.stringify(payload.companyScope) : null); }
  catch { return Response.json({ error: "Invalid company navigation scope." }, { status: 400 }); }
  const requestedFields = Array.isArray(payload.fields) ? [...new Set(payload.fields.map((field) => String(field).trim()).filter(Boolean))].slice(0, 600) : [];
  if (!requestedFields.length) return Response.json({ error: "Choose at least one field to export." }, { status: 400 });

  const supabase = createAdminClient();
  const result = await exportProspects(supabase, { search, filters, sort, direction, clientId, companyScope });
  if (isMissingFunction(result.error)) {
    return Response.json({ error: "Apply the latest database migration to enable the new prospect filters." }, { status: 503 });
  }
  if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
  const availableFields = availableExportFieldIds(result.fields);
  const validatedFields = requestedFields.filter((field) => availableFields.has(field));
  if (!validatedFields.length) return Response.json({ error: "None of the selected fields are available." }, { status: 400 });

  const selectionMode = payload.selection?.mode === "ids" ? "ids" : "all_matching";
  const selectionValues = selectionMode === "ids" ? payload.selection?.ids : payload.selection?.excludedIds;
  const selectionIds = new Set(Array.isArray(selectionValues) ? selectionValues.map((id) => String(id).trim()).filter(Boolean).slice(0, 10000) : []);
  const rows = selectionMode === "ids"
    ? result.rows.filter((row) => selectionIds.has(String(row.id ?? "")))
    : result.rows.filter((row) => !selectionIds.has(String(row.id ?? "")));
  return exportResponse(rows, result.fields, validatedFields, clientId);
}
