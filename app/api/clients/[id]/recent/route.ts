import { authorizeApi } from "../../../../../lib/auth.ts";
import { databaseErrorResponse, isStatementTimeout, statementTimeoutResponse } from "../../../../../lib/api-errors.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

const pageSize = 50;

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  const { id: clientId } = await context.params;
  if (!clientId) return Response.json({ error: "No client." }, { status: 400 });

  const url = new URL(request.url);
  const rawPage = Number(url.searchParams.get("page") ?? 1);
  const page = Number.isSafeInteger(rawPage) ? Math.max(1, Math.min(rawPage, 100_000)) : 1;
  const batchId = (url.searchParams.get("batchId") ?? "").trim();
  const supabase = createAdminClient();
  if (batchId) {
    if (!/^[0-9a-f-]{36}$/i.test(batchId)) return Response.json({ error: "Invalid batch." }, { status: 400 });
    const { data, error } = await supabase.rpc("client_addition_batch_records_v1", {
      p_client_id: clientId, p_batch_id: batchId, p_limit: pageSize, p_offset: (page - 1) * pageSize,
    }).abortSignal(request.signal ?? AbortSignal.timeout(30_000));
    if (error) return error.code === "P0002"
      ? Response.json({ error: "Batch not found." }, { status: 404 })
      : databaseErrorResponse("The batch records", error);
    const summary = Array.isArray(data) ? data[0] : data;
    return Response.json({ records: summary?.result_rows ?? [], total: Number(summary?.total_count ?? 0), page, pageSize });
  }
  const rawEntity = url.searchParams.get("entity") ?? "";
  const entity = rawEntity === "people" || rawEntity === "companies" ? rawEntity : "";
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 200);
  const windowKey = url.searchParams.get("window") ?? "30d";
  const windows: Record<string, number | null> = { "24h": 24, "7d": 168, "30d": 720, all: null };
  if (!(windowKey in windows)) return Response.json({ error: "Unknown time window." }, { status: 400 });

  const { data, error } = await supabase.rpc("client_recent_batches_v1", {
    p_client_id: clientId,
    p_search: search,
    p_entity: entity,
    p_hours: windows[windowKey],
    p_limit: pageSize,
    p_offset: (page - 1) * pageSize,
  }).abortSignal(request.signal ?? AbortSignal.timeout(30_000));

  if (error) {
    if (missingFunctionCodes.has(error.code ?? "")) {
      return Response.json({ error: "Apply the latest database migration to enable recent batches." }, { status: 503 });
    }
    if (isStatementTimeout(error)) {
      return statementTimeoutResponse("This recent-batch search", "Use a more specific record or source search.");
    }
    return databaseErrorResponse("The recently added listing", error);
  }

  const summary = Array.isArray(data) ? data[0] : data;
  return Response.json({
    batches: summary?.result_rows ?? [],
    total: Number(summary?.total_count ?? 0),
    entity,
    window: windowKey,
    page,
    pageSize,
  });
}
