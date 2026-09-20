import { authorizeApi } from "../../../../../lib/auth.ts";
import { databaseErrorResponse, isStatementTimeout, statementTimeoutResponse } from "../../../../../lib/api-errors.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

// The windows the tab offers, and the only ones it will answer. A free-form
// hours value would let a hand-built URL ask for the whole table through a
// listing that has no cap of its own; the function bounds it too, but the set
// of real answers is this short.
const windows: Record<string, number> = { "24h": 24, "7d": 24 * 7, "30d": 24 * 30 };

const pageSize = 50;

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  const { id: clientId } = await context.params;
  if (!clientId) return Response.json({ error: "No client." }, { status: 400 });

  const url = new URL(request.url);
  const entity = url.searchParams.get("entity") === "companies" ? "companies" : "people";
  const windowKey = url.searchParams.get("window") ?? "24h";
  const hours = windows[windowKey];
  if (!hours) return Response.json({ error: "Unknown window." }, { status: 400 });
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("client_recently_added_v1", {
    p_client_id: clientId,
    p_entity: entity,
    p_hours: hours,
    p_limit: pageSize,
    p_offset: (page - 1) * pageSize,
  }).abortSignal(request.signal ?? AbortSignal.timeout(30_000));

  if (error) {
    if (missingFunctionCodes.has(error.code ?? "")) {
      return Response.json({ error: "Apply the latest database migration to enable the Recently Added tab." }, { status: 503 });
    }
    if (isStatementTimeout(error)) {
      return statementTimeoutResponse("This window", "Choose a shorter window.");
    }
    return databaseErrorResponse("The recently added listing", error);
  }

  const summary = Array.isArray(data) ? data[0] : data;
  return Response.json({
    records: summary?.result_rows ?? [],
    total: Number(summary?.total_count ?? 0),
    entity,
    window: windowKey,
    page,
    pageSize,
  });
}
