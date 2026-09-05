import { acquireSlot } from "../../../../lib/admission";
import { authorizeFilterSets } from "../../../../lib/filter-sets";
import { isStatementTimeout, statementTimeoutResponse } from "../../../../lib/api-errors";
import { authorizeApi, getAuthorizedUser } from "../../../../lib/auth";
import { filterErrorResponse, parseFilters, type ProspectFilter } from "../../../../lib/prospect-filters";
import { availableExportFieldIds, buildExportColumns, csvHeaderLine, csvRowsBody, exportRowKeys, type ProspectRow } from "../../../../lib/prospect-export";
import { createAdminClient } from "../../../../lib/supabase/admin";
import { recordRequest, routeOf } from "../../../../lib/observability";
import { parseCompanyScope, type CompanyScope } from "../../../../lib/workspace-scopes";

export const runtime = "nodejs";
// A direct export is several bounded queries with bytes going to the client in
// between, not one long query. lib/export-plan.ts is what keeps it short:
// anything past 50,000 rows or 25 MB is a background job instead.
export const maxDuration = 300;

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);
// One database page. Larger pages mean fewer round trips and a bigger jsonb
// array held in the server for the moment it is rendered; 25,000 projected rows
// is a few MB and is what search_prospect_export_v5 will return at most anyway.
const pageSize = 25_000;
const BOM = "﻿";
const CRLF = "\r\n";

// A page may be refused by the admission guard, and a refusal in the middle of
// a download cannot become a 503 - the status line is long gone. So a page
// waits and asks again before the stream gives up, which turns a burst of
// concurrent listings into a slower export rather than a broken file.
const slotRetries = 8;
const slotRetryMs = 2500;

function summary(data: unknown) {
  const row = Array.isArray(data) ? data[0] : data;
  return row && typeof row === "object" ? row as { result_rows?: unknown } : {};
}

function rowsOf(data: unknown): ProspectRow[] {
  const rows = summary(data).result_rows;
  return Array.isArray(rows) ? rows.filter((row): row is ProspectRow => Boolean(row) && typeof row === "object") : [];
}

type Cursor = { createdAt: string; id: string } | null;

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  return runExport(request);
}

async function runExport(request: Request) {
  const route = routeOf(request.url);
  const startedAt = Date.now();
  const answer = (response: Response) => {
    recordRequest(route, response.status, Date.now() - startedAt);
    return response;
  };

  const payload = await request.json().catch(() => null) as {
    search?: unknown;
    filters?: unknown;
    clientId?: unknown;
    fields?: unknown;
    excludedIds?: unknown;
    companyScope?: unknown;
    fileBaseName?: unknown;
  } | null;
  if (!payload) return answer(Response.json({ error: "Invalid export request." }, { status: 400 }));

  const search = String(payload.search ?? "").trim().slice(0, 300);
  let filters: ProspectFilter[];
  try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
  catch (error) { return answer(filterErrorResponse(error, "Invalid Boolean filter.")); }
  const clientId = String(payload.clientId ?? "").trim() || null;
  let companyScope: CompanyScope | null;
  try { companyScope = parseCompanyScope(payload.companyScope ? JSON.stringify(payload.companyScope) : null); }
  catch (error) { return answer(filterErrorResponse(error, "Invalid company navigation scope.")); }
  const requestedFields = Array.isArray(payload.fields)
    ? [...new Set(payload.fields.map((field) => String(field).trim()).filter(Boolean))].slice(0, 600)
    : [];
  if (!requestedFields.length) return answer(Response.json({ error: "Choose at least one field to export." }, { status: 400 }));
  const excludedIds = new Set(Array.isArray(payload.excludedIds)
    ? payload.excludedIds.map((id) => String(id).trim()).filter(Boolean).slice(0, 50000)
    : []);
  const fileBaseName = String(payload.fileBaseName ?? "prospect-sync-export").replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 80) || "export";

  const supabase = createAdminClient();

  // An export reads the same sets the grid did, and re-checks them the same way.
  const setDenial = await authorizeFilterSets(supabase, filters, (await getAuthorizedUser())?.id ?? "", "prospect", clientId ?? "",
    companyScope ? [{ entityType: 'company', clientScope: clientId ?? '', filters: companyScope.filters }] : []);
  if (setDenial) return answer(setDenial);

  const fieldRows = await supabase.from("prospect_fields").select("field_name").order("field_name").limit(500);
  if (fieldRows.error) return answer(Response.json({ error: fieldRows.error.message }, { status: 500 }));
  const customFieldNames = (fieldRows.data ?? []).map((field) => String(field.field_name ?? "")).filter(Boolean);
  const available = availableExportFieldIds(customFieldNames);
  const validatedFields = requestedFields.filter((field) => available.has(field));
  if (!validatedFields.length) return answer(Response.json({ error: "None of the selected fields are available." }, { status: 400 }));

  const columns = buildExportColumns(customFieldNames, validatedFields);
  // Only the columns this file actually reads leave the database. The key list
  // is derived from these same columns by running them, so it cannot name a
  // field the renderer does not use or miss one it does.
  const keys = exportRowKeys(customFieldNames, validatedFields);

  async function readPage(cursor: Cursor, signal: AbortSignal | undefined) {
    let release: (() => void) | null = null;
    for (let attempt = 0; attempt <= slotRetries && !release; attempt += 1) {
      release = await acquireSlot(signal);
      if (!release && attempt < slotRetries) await new Promise((resolve) => setTimeout(resolve, slotRetryMs));
    }
    if (!release) throw new Error("The database stayed busy for too long, so this export stopped rather than queueing behind it.");
    try {
      return await supabase.rpc("search_prospect_export_v5", {
        p_search: search,
        p_filters: filters,
        p_client_id: clientId,
        p_company_scope: companyScope ?? {},
        p_after_created_at: cursor?.createdAt ?? null,
        p_after_id: cursor?.id ?? null,
        p_limit: pageSize,
        p_with_total: false,
        p_keys: keys,
      }).abortSignal(signal ?? AbortSignal.timeout(120_000));
    } finally {
      release();
    }
  }

  // The first page runs before a byte is sent, because once the response has a
  // status line an error can only be a truncated file. Everything that can be
  // told to the caller properly - a missing migration, a timeout, a bad filter -
  // is found here.
  let first;
  try { first = await readPage(null, request.signal); }
  catch (error) { return answer(Response.json({ error: error instanceof Error ? error.message : "Export failed." }, { status: 503 })); }

  if (first.error && missingFunctionCodes.has(first.error.code ?? "")) {
    return answer(Response.json({ error: "Apply the latest database migration to enable large exports." }, { status: 503 }));
  }
  if (isStatementTimeout(first.error)) {
    return answer(statementTimeoutResponse("This export", "Narrow the filters, or export fewer columns."));
  }
  if (first.error) return answer(Response.json({ error: first.error.message }, { status: 500 }));

  const keep = (rows: ProspectRow[]) => excludedIds.size ? rows.filter((row) => !excludedIds.has(String(row.id ?? ""))) : rows;
  const cursorAfter = (rows: ProspectRow[], previous: Cursor): Cursor => {
    const last = rows.at(-1);
    return last ? { createdAt: String(last.created_at ?? ""), id: String(last.id ?? "") } : previous;
  };

  const firstRaw = rowsOf(first.data);
  let cursor: Cursor = cursorAfter(firstRaw, null);
  let exhausted = firstRaw.length < pageSize;
  let pending: ProspectRow[] | null = keep(firstRaw);
  let written = 0;

  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (pending === null) {
        if (exhausted) { controller.close(); return; }
        const page = await readPage(cursor, request.signal);
        if (page.error) throw new Error(page.error.message);
        const raw = rowsOf(page.data);
        cursor = cursorAfter(raw, cursor);
        exhausted = raw.length < pageSize;
        pending = keep(raw);
      }
      const rows = pending;
      pending = null;
      // Nothing accumulates: each page is rendered, enqueued and dropped. The
      // header goes with the first chunk so the file is valid even if the
      // caller stops reading after one page.
      const head = written === 0 ? BOM + csvHeaderLine(columns) + CRLF : "";
      const body = rows.length ? (written === 0 ? "" : CRLF) + csvRowsBody(rows, columns) : "";
      written += rows.length;
      if (head || body) controller.enqueue(encoder.encode(head + body));
      if (exhausted) controller.close();
    },
  });

  // Recorded at the first byte rather than at the last: the rest of the time is
  // the client reading, and counting that as query time would make every export
  // look like the slowest request on the box.
  recordRequest(route, 200, Date.now() - startedAt);
  return new Response(stream, {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${fileBaseName}.csv"`,
      "Cache-Control": "no-store",
      // Nothing between here and the browser may buffer this to measure it.
      "X-Accel-Buffering": "no",
    },
  });
}
