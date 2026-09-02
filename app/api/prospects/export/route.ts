import { withInteractiveSlot } from "../../../../lib/admission";
import { isStatementTimeout, statementTimeoutResponse } from "../../../../lib/api-errors";
import { authorizeApi } from "../../../../lib/auth";
import { filterErrorResponse, parseFilters } from "../../../../lib/prospect-filters";
import { availableExportFieldIds, buildExportColumns, csvHeaderLine, csvRowsBody, type ProspectRow } from "../../../../lib/prospect-export";
import { createAdminClient } from "../../../../lib/supabase/admin";
import { parseCompanyScope } from "../../../../lib/workspace-scopes";

export const runtime = "nodejs";
export const maxDuration = 60;

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);
// Server-side clamp: keeps each request comfortably inside the 60s function budget.
const maxPageSize = 25000;

type Cursor = { createdAt: string; id: string } | null;

function summary(data: unknown) {
  const row = Array.isArray(data) ? data[0] : data;
  return row && typeof row === "object" ? row as { result_rows?: unknown; total_count?: unknown } : {};
}

function rowsOf(data: unknown): ProspectRow[] {
  const rows = summary(data).result_rows;
  return Array.isArray(rows) ? rows.filter((row): row is ProspectRow => Boolean(row) && typeof row === "object") : [];
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  return withInteractiveSlot(request, () => runExport(request));
}

async function runExport(request: Request) {

  const payload = await request.json().catch(() => null) as {
    search?: unknown;
    filters?: unknown;
    clientId?: unknown;
    fields?: unknown;
    excludedIds?: unknown;
    cursor?: { createdAt?: unknown; id?: unknown } | null;
    limit?: unknown;
    withTotal?: unknown;
    companyScope?: unknown;
  } | null;
  if (!payload) return Response.json({ error: "Invalid export request." }, { status: 400 });

  const search = String(payload.search ?? "").trim().slice(0, 300);
  let filters;
  try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
  catch (error) { return filterErrorResponse(error, "Invalid Boolean filter."); }
  const clientId = String(payload.clientId ?? "").trim() || null;
  let companyScope;
  try { companyScope = parseCompanyScope(payload.companyScope ? JSON.stringify(payload.companyScope) : null); }
  catch (error) { return filterErrorResponse(error, "Invalid company navigation scope."); }
  const requestedFields = Array.isArray(payload.fields)
    ? [...new Set(payload.fields.map((field) => String(field).trim()).filter(Boolean))].slice(0, 600)
    : [];
  if (!requestedFields.length) return Response.json({ error: "Choose at least one field to export." }, { status: 400 });
  const excludedIds = new Set(Array.isArray(payload.excludedIds)
    ? payload.excludedIds.map((id) => String(id).trim()).filter(Boolean).slice(0, 50000)
    : []);
  const cursor: Cursor = payload.cursor && payload.cursor.createdAt
    ? { createdAt: String(payload.cursor.createdAt), id: String(payload.cursor.id ?? "") }
    : null;
  const limit = Math.max(1000, Math.min(maxPageSize, Number(payload.limit ?? maxPageSize) || maxPageSize));
  const withTotal = payload.withTotal === true;

  const supabase = createAdminClient();
  // One export function, scoped or not. v1 carried its own inlined copy of the
  // filter CASE, and the copies had drifted: v1 never learned __company_domain,
  // which the compiler and the row predicate both have, so a domain filter
  // exported as though it had not been set. v4 compiles the same predicate the
  // workspace listing does (prospect_filter_sql_v1), so the rows in the file and
  // the count above the grid answer the same question. An empty scope costs
  // nothing - v_has_scope is false, so no scope CTE is emitted.
  const [page, fieldRows] = await Promise.all([
    supabase.rpc("search_prospect_export_v4", {
      p_search: search,
      p_filters: filters,
      p_client_id: clientId,
      p_company_scope: companyScope ?? {},
      p_after_created_at: cursor?.createdAt ?? null,
      p_after_id: cursor?.id ?? null,
      p_limit: limit,
      p_with_total: withTotal,
    }).abortSignal(request.signal ?? AbortSignal.timeout(60_000)),
    supabase.from("prospect_fields").select("field_name").order("field_name").limit(500),
  ]);

  if (page.error && missingFunctionCodes.has(page.error.code ?? "")) {
    return Response.json({ error: "Apply the search-index migration to enable large exports." }, { status: 503 });
  }
  const failure = page.error ?? fieldRows.error;
  if (isStatementTimeout(failure)) {
    return statementTimeoutResponse("This export page", "Narrow the filters, or export in smaller pages.");
  }
  if (failure) return Response.json({ error: failure.message }, { status: 500 });

  const customFieldNames = (fieldRows.data ?? []).map((field) => String(field.field_name ?? "")).filter(Boolean);
  const available = availableExportFieldIds(customFieldNames);
  const validatedFields = requestedFields.filter((field) => available.has(field));
  if (!validatedFields.length) return Response.json({ error: "None of the selected fields are available." }, { status: 400 });

  const rawRows = rowsOf(page.data);
  const last = rawRows.at(-1);
  const nextCursor: Cursor = last ? { createdAt: String(last.created_at ?? ""), id: String(last.id ?? "") } : cursor;
  const done = rawRows.length < limit;

  const rows = excludedIds.size ? rawRows.filter((row) => !excludedIds.has(String(row.id ?? ""))) : rawRows;
  const columns = buildExportColumns(customFieldNames, validatedFields);

  return Response.json({
    header: csvHeaderLine(columns),
    rows: csvRowsBody(rows, columns),
    count: rows.length,
    nextCursor,
    done,
    total: withTotal ? Number(summary(page.data).total_count ?? 0) : undefined,
  });
}
