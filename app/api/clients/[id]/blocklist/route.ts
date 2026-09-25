import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { BLOCKLIST_REQUEST_VALUES, partitionBlocklistValues } from "../../../../../lib/bulk-values.ts";
import { csvCell } from "../../../../../lib/csv.ts";
import { readBoundedJson } from "../../../../../lib/bounded-json.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);
const reasons = new Set(["Client Provided", "ICP Invalid", "Campaign Reply"]);
const datePattern = /^\d{4}-\d{2}-\d{2}$/;

function failure(error: { code?: string; message: string }) {
  const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
  return Response.json(
    { error: missing ? "Apply the latest database migration to enable client blocklist bulk actions." : error.message },
    { status: missing ? 503 : error.code === "P0002" ? 404 : error.code === "54000" ? 413 : error.code === "22023" ? 400 : 500 },
  );
}

function validDate(value: string) {
  if (!datePattern.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(value);
}

function readFilters(url: URL) {
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 200);
  const rawKind = url.searchParams.get("kind") ?? "";
  const kind = rawKind === "domain" || rawKind === "email" ? rawKind : "";
  const rawFrom = url.searchParams.get("dateFrom") ?? "";
  const rawTo = url.searchParams.get("dateTo") ?? "";
  return { search, kind, dateFrom: validDate(rawFrom) ? rawFrom : "", dateTo: validDate(rawTo) ? rawTo : "" };
}

type SelectionPayload = { ids?: unknown; allMatching?: unknown; search?: unknown; kind?: unknown; dateFrom?: unknown; dateTo?: unknown; excludedIds?: unknown; selectedBefore?: unknown; reason?: unknown };

function selectionArgs(payload: SelectionPayload) {
  const ids = Array.isArray(payload.ids) ? [...new Set(payload.ids.map((value) => String(value ?? "").trim()).filter(Boolean))] : [];
  const excluded = Array.isArray(payload.excludedIds) ? [...new Set(payload.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))] : [];
  const kind = payload.kind === "domain" || payload.kind === "email" ? payload.kind : "";
  const selectedBeforeText = String(payload.selectedBefore ?? "").trim();
  const selectedBeforeDate = new Date(selectedBeforeText);
  const selectedBefore = selectedBeforeText && !Number.isNaN(selectedBeforeDate.getTime()) && selectedBeforeDate.getTime() <= Date.now() + 60_000
    ? selectedBeforeDate.toISOString() : null;
  return { p_ids: ids, p_all_matching: payload.allMatching === true, p_search: String(payload.search ?? "").trim().slice(0, 200), p_kind: kind, p_date_from: validDate(String(payload.dateFrom ?? "")) ? String(payload.dateFrom) : null, p_date_to: validDate(String(payload.dateTo ?? "")) ? String(payload.dateTo) : null, p_excluded_ids: excluded, p_selected_before: selectedBefore };
}

function invalidSelectionSize(payload: SelectionPayload) {
  if (Array.isArray(payload.ids) && payload.ids.length > 50_000) return "At most 50,000 explicit entries can be changed at once.";
  if (Array.isArray(payload.excludedIds) && payload.excludedIds.length > 10_000) return "At most 10,000 entries can be excluded. Narrow the filters instead.";
  return "";
}

async function exportSelection(request: Request, clientId: string, payload: SelectionPayload) {
  const sizeError = invalidSelectionSize(payload);
  if (sizeError) return Response.json({ error: sizeError }, { status: 413 });
  const args = selectionArgs(payload);
  if (args.p_all_matching && !args.p_selected_before) return Response.json({ error: "The export snapshot expired. Start the export again." }, { status: 400 });
  if (!args.p_all_matching && !args.p_ids.length) return Response.json({ error: "Choose entries to export, or export all matching entries." }, { status: 400 });

  const admin = createAdminClient();
  const { data: matched, error: countError } = await admin.rpc("client_blocklist_selection_count_v1", { p_client_id: clientId, ...args });
  if (countError) return failure(countError);
  const count = Number(matched ?? 0);
  if (count > 250_000) return Response.json({ error: "More than 250,000 entries match. Narrow the filters before exporting." }, { status: 413 });

  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        controller.enqueue(encoder.encode(`\uFEFF${["Value", "Type", "Reason", "Date Added"].map(csvCell).join(",")}\r\n`));
        let afterCreatedAt: string | null = null;
        let afterId: string | null = null;
        let exported = 0;
        while (exported < count && !request.signal.aborted) {
          const { data, error } = await admin.rpc("client_blocklist_export_page_v1", {
            p_client_id: clientId, ...args, p_after_created_at: afterCreatedAt, p_after_id: afterId, p_limit: 1000,
          });
          if (error) throw error;
          const rows = (data ?? []) as Array<{ id: string; value: string; kind: string; reason: string | null; created_at: string }>;
          if (!rows.length) break;
          controller.enqueue(encoder.encode(rows.map((row) => [row.value, row.kind, row.reason, row.created_at].map(csvCell).join(",")).join("\r\n") + "\r\n"));
          exported += rows.length;
          const last = rows.at(-1)!;
          afterCreatedAt = last.created_at;
          afterId = last.id;
          if (rows.length < 1000) break;
        }
        controller.close();
      } catch (caught) { controller.error(caught); }
    },
  });
  return new Response(stream, { headers: {
    "Content-Type": "text/csv; charset=utf-8",
    "Content-Disposition": `attachment; filename="${clientId}-blocklist-${new Date().toISOString().slice(0, 10)}.csv"`,
    "Cache-Control": "no-store",
  } });
}

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const url = new URL(request.url);
  const filters = readFilters(url);

  const rawPage = Number(url.searchParams.get("page") ?? 1);
  const page = Number.isSafeInteger(rawPage) ? Math.max(1, Math.min(rawPage, 100_000)) : 1;
  const pageSize = 100;
  const offset = (page - 1) * pageSize;
  let query = createAdminClient().from("client_blocklist")
    .select("id,kind,value,reason,source,created_at", { count: "exact" })
    .eq("client_id", id).order("created_at", { ascending: false }).order("id", { ascending: true });
  if (filters.search) query = query.ilike("value", `%${filters.search}%`);
  if (filters.kind) query = query.eq("kind", filters.kind);
  if (filters.dateFrom) query = query.gte("created_at", `${filters.dateFrom}T00:00:00.000Z`);
  if (filters.dateTo) { const exclusive = new Date(`${filters.dateTo}T00:00:00.000Z`); exclusive.setUTCDate(exclusive.getUTCDate() + 1); query = query.lt("created_at", exclusive.toISOString()); }
  const { data, error, count } = await query.range(offset, offset + pageSize - 1);
  if (error) return failure(error);
  return Response.json({ entries: data ?? [], total: count ?? 0, page, pageSize });
}

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();
  const decoded = await readBoundedJson(request, { bytes: 300_000, depth: 8, timeoutMs: 5_000 });
  if (decoded.response) return decoded.response;
  const payload = decoded.value as (SelectionPayload & { action?: unknown; text?: unknown; requestId?: unknown }) | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });
  if (payload.action === "export") return exportSelection(request, id, payload);
  const text = String(payload.text ?? "");
  const reason = String(payload.reason ?? "").trim();
  const requestId = String(payload.requestId ?? "").trim();
  if (!reasons.has(reason)) return Response.json({ error: "Choose a blocklist reason." }, { status: 400 });
  if (!text.trim()) return Response.json({ error: "Paste the domains or email addresses to block." }, { status: 400 });
  if (!/^[a-zA-Z0-9-]{8,100}$/.test(requestId)) return Response.json({ error: "A valid blocklist request id is required." }, { status: 400 });
  if (text.length > 250_000) return Response.json({ error: "This blocklist batch is too large. Please use the in-app batch processor." }, { status: 413 });
  const parsed = partitionBlocklistValues(text);
  if (parsed.submitted > BLOCKLIST_REQUEST_VALUES) return Response.json({ error: `For reliability, each request can process ${BLOCKLIST_REQUEST_VALUES.toLocaleString("en-IN")} entries. The app submits larger pastes automatically in batches.` }, { status: 413 });
  if (!parsed.emails.length && !parsed.domains.length) return Response.json({ error: "No valid domains or email addresses found in that list.", unrecognised: parsed.invalid }, { status: 400 });
  const { data, error } = await createAdminClient().rpc("add_client_blocklist_batch_v2", {
    p_client_id: id, p_domains: parsed.domains, p_emails: parsed.emails, p_reason: reason,
    p_actor: user?.email ?? "", p_request_id: requestId, p_match_limit: 5_000,
  });
  if (error) return failure(error);
  return Response.json({ result: data, domains: parsed.domains.length, emails: parsed.emails.length, duplicates: parsed.duplicates, unrecognised: parsed.invalid, unrecognisedCount: parsed.invalidCount });
}

export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const payload = decoded.value as SelectionPayload | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });
  const sizeError = invalidSelectionSize(payload);
  if (sizeError) return Response.json({ error: sizeError }, { status: 413 });
  const reason = String(payload.reason ?? "").trim();
  if (!reasons.has(reason)) return Response.json({ error: "Choose an allowed blocklist reason." }, { status: 400 });
  const args = selectionArgs(payload);
  if (args.p_all_matching && !args.p_selected_before) return Response.json({ error: "The select-all snapshot expired. Select all matching entries again." }, { status: 400 });
  if (!args.p_all_matching && !args.p_ids.length) return Response.json({ error: "Choose at least one entry." }, { status: 400 });
  const { data, error } = await createAdminClient().rpc("update_client_blocklist_reason_v1", { p_client_id: id, p_reason: reason, ...args, p_actor: user?.email ?? "" });
  if (error) return failure(error);
  return Response.json({ result: data });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const payload = decoded.value as SelectionPayload | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });
  const sizeError = invalidSelectionSize(payload);
  if (sizeError) return Response.json({ error: sizeError }, { status: 413 });
  const args = selectionArgs(payload);
  if (args.p_all_matching && !args.p_selected_before) return Response.json({ error: "The select-all snapshot expired. Select all matching entries again." }, { status: 400 });
  if (!args.p_all_matching && !args.p_ids.length) return Response.json({ error: "Choose at least one entry to remove." }, { status: 400 });
  const { data, error } = await createAdminClient().rpc("remove_client_blocklist_selection_v1", { p_client_id: id, ...args, p_actor: user?.email ?? "" });
  if (error) return failure(error);
  return Response.json({ result: data });
}
