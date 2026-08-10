import { authorizeApi } from "../../../lib/auth";
import { csvDocument } from "../../../lib/csv";
import { createAdminClient } from "../../../lib/supabase/admin";

type ProspectFilter = { field: string; operator: "contains" | "equals" | "not_contains" | "not_equals" | "empty" | "not_empty"; values: string[] };
type ProspectRow = Record<string, unknown>;
type WorkspaceQuery = {
  search: string;
  filters: ProspectFilter[];
  sort: string;
  direction: string;
  limit: number;
  offset: number;
  clientId: string | null;
};

const allowedOperators = new Set(["contains", "equals", "not_contains", "not_equals", "empty", "not_empty"]);
const missingFunctionCodes = new Set(["PGRST202", "42883"]);
const exportPageSize = 100;
const exportConcurrency = 5;

function parseFilters(value: string | null): ProspectFilter[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.slice(0, 8).flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const candidate = item as Record<string, unknown>;
      const field = String(candidate.field ?? "").trim().slice(0, 160);
      const operator = String(candidate.operator ?? "contains");
      const rawValues = Array.isArray(candidate.values) ? candidate.values : [candidate.value];
      const values = rawValues.map((value) => String(value ?? "").trim().slice(0, 160)).filter(Boolean).slice(0, 30);
      if (!field || !allowedOperators.has(operator)) return [];
      if (!["empty", "not_empty"].includes(operator) && !values.length) return [];
      return [{ field, operator: operator as ProspectFilter["operator"], values }];
    });
  } catch {
    return [];
  }
}

function isMissingFunction(error: { code?: string } | null | undefined) {
  return Boolean(error?.code && missingFunctionCodes.has(error.code));
}

async function runProspectWorkspace(supabase: ReturnType<typeof createAdminClient>, query: WorkspaceQuery) {
  const legacyFilters = query.filters.filter((filter) => !["__esp", "__email_provider_type"].includes(filter.field));
  let workspace = await supabase.rpc("search_prospect_workspace_v5", {
    p_search: query.search,
    p_filters: query.filters,
    p_sort: query.sort,
    p_direction: query.direction,
    p_limit: query.limit,
    p_offset: query.offset,
    p_client_id: query.clientId,
  });
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

function arrayText(value: unknown) {
  return Array.isArray(value) ? value.map((item) => String(item ?? "").trim()).filter(Boolean).join(" | ") : "";
}

function tagsText(value: unknown) {
  if (!Array.isArray(value)) return "";
  return value.map((tag) => tag && typeof tag === "object" ? String((tag as ProspectRow).name ?? "") : String(tag ?? "")).filter(Boolean).join(" | ");
}

function allData(value: unknown): ProspectRow {
  if (value && typeof value === "object" && !Array.isArray(value)) return value as ProspectRow;
  if (typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as ProspectRow : {};
  } catch {
    return {};
  }
}

function exportValue(value: unknown) {
  if (value == null) return "";
  if (Array.isArray(value)) return value.map((item) => typeof item === "object" ? JSON.stringify(item) : String(item)).join(" | ");
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function websiteUrl(value: unknown) {
  const domain = String(value ?? "").trim();
  if (!domain) return "";
  return /^https?:\/\//i.test(domain) ? domain : `https://${domain}`;
}

const standardExportColumns: Array<{ id: string; header: string; value: (row: ProspectRow) => unknown }> = [
  { id: "__name", header: "Full Name", value: (row) => row.full_name },
  { id: "__first_name", header: "First Name", value: (row) => row.first_name },
  { id: "__last_name", header: "Last Name", value: (row) => row.last_name },
  { id: "__work_email", header: "Work Email", value: (row) => row.work_email },
  { id: "__personal_email", header: "Personal Email", value: (row) => row.personal_email },
  { id: "__mobile_number", header: "Mobile Number", value: (row) => row.mobile_number },
  { id: "__linkedin", header: "LinkedIn", value: (row) => row.linkedin_url },
  { id: "__title", header: "Title", value: (row) => row.title },
  { id: "__seniority", header: "Seniority", value: (row) => row.seniority },
  { id: "__department", header: "Department", value: (row) => row.department },
  { id: "__city", header: "City", value: (row) => row.city },
  { id: "__state", header: "State", value: (row) => row.state },
  { id: "__country", header: "Country", value: (row) => row.country },
  { id: "__company", header: "Company", value: (row) => row.company_name },
  { id: "__website", header: "Website", value: (row) => websiteUrl(row.company_domain) },
  { id: "__esp", header: "ESP", value: (row) => row.esp },
  { id: "__email_provider_type", header: "Email Provider Type", value: (row) => row.email_provider_type },
  { id: "__mx_records", header: "MX Records", value: (row) => arrayText(row.mx_records) },
  { id: "__mx_status", header: "MX Status", value: (row) => row.mx_status },
  { id: "__mx_checked_at", header: "MX Checked At", value: (row) => row.mx_checked_at },
  { id: "__lists", header: "List Names", value: (row) => arrayText(row.list_names) },
  { id: "__clients", header: "Client Names", value: (row) => arrayText(row.client_names) },
  { id: "__tags", header: "Tags", value: (row) => tagsText(row.tags) },
  { id: "__last_contacted", header: "Last Contacted", value: (row) => row.last_contacted_at },
  { id: "__created_at", header: "Created At", value: (row) => row.created_at },
  { id: "__updated_at", header: "Updated At", value: (row) => row.updated_at },
];

function normalizedHeader(value: string) {
  return value.trim().toLocaleLowerCase().replace(/[^a-z0-9]+/g, "");
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

function prospectsCsv(rows: ProspectRow[], fields: string[], requestedFields?: string[]) {
  const selected = requestedFields ? new Set(requestedFields) : null;
  const standardColumns = standardExportColumns.filter((column) => !selected || selected.has(column.id));
  const standardHeaders = new Set(standardExportColumns.map((column) => normalizedHeader(column.header)));
  const customColumns = fields.filter((field) => !selected || selected.has(`custom:${field}`)).map((field) => ({
    field,
    header: standardHeaders.has(normalizedHeader(field)) ? `${field} (Imported)` : field,
  }));
  return csvDocument(
    [...standardColumns.map((column) => column.header), ...customColumns.map((column) => column.header)],
    rows.map((row) => {
      const preserved = allData(row.all_data);
      return [
        ...standardColumns.map((column) => exportValue(column.value(row))),
        ...customColumns.map((column) => exportValue(preserved[column.field])),
      ];
    }),
  );
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
  const includeFields = url.searchParams.get("includeFields") !== "0";
  const exportCsv = url.searchParams.get("export") === "csv";
  const limit = 50;
  const filters = parseFilters(url.searchParams.get("filters"));
  const supabase = createAdminClient();

  if (exportCsv) {
    const result = await exportProspects(supabase, { search, filters, sort, direction, clientId });
    if (clientId && isMissingFunction(result.error)) {
      return Response.json({ error: "Apply the latest database migration to enable client workspaces." }, { status: 503 });
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
  });
  const fieldsRequest = includeFields
    ? supabase.from("prospect_fields").select("field_name").order("field_name").limit(500)
    : Promise.resolve({ data: [] as Array<{ field_name: string }>, error: null });
  const [workspace, fields] = await Promise.all([workspaceRequest, fieldsRequest]);
  if (clientId && isMissingFunction(workspace.error)) {
    return Response.json({ error: "Apply the latest database migration to enable client workspaces." }, { status: 503 });
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
    selection?: { mode?: unknown; ids?: unknown; excludedIds?: unknown };
  } | null;
  if (!payload) return Response.json({ error: "Invalid export request." }, { status: 400 });
  const search = String(payload.search ?? "").trim().slice(0, 300);
  const filters = parseFilters(JSON.stringify(payload.filters ?? []));
  const sortValue = String(payload.sort ?? "created_at");
  const sort = ["created_at", "name", "company", "title", "last_contacted"].includes(sortValue) ? sortValue : "created_at";
  const direction = payload.direction === "asc" ? "asc" : "desc";
  const clientId = String(payload.clientId ?? "").trim() || null;
  const requestedFields = Array.isArray(payload.fields) ? [...new Set(payload.fields.map((field) => String(field).trim()).filter(Boolean))].slice(0, 600) : [];
  if (!requestedFields.length) return Response.json({ error: "Choose at least one field to export." }, { status: 400 });

  const supabase = createAdminClient();
  const result = await exportProspects(supabase, { search, filters, sort, direction, clientId });
  if (clientId && isMissingFunction(result.error)) {
    return Response.json({ error: "Apply the latest database migration to enable client workspaces." }, { status: 503 });
  }
  if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
  const availableFields = new Set([...standardExportColumns.map((column) => column.id), ...result.fields.map((field) => `custom:${field}`)]);
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
