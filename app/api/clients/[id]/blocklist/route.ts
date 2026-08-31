import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { BLOCKLIST_REQUEST_VALUES, partitionBlocklistValues } from "../../../../../lib/bulk-values.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

function failure(error: { code?: string; message: string }) {
  const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
  return Response.json(
    { error: missing ? "Apply the latest database migration to enable client blocklists." : error.message },
    { status: missing ? 503 : error.code === "P0002" ? 404 : 500 },
  );
}

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 200);
  const page = Math.max(1, Math.min(Number(url.searchParams.get("page") ?? 1) || 1, 100_000));
  const pageSize = 100;
  const offset = (page - 1) * pageSize;

  let query = createAdminClient()
    .from("client_blocklist")
    .select("id,kind,value,reason,source,created_at", { count: "exact" })
    .eq("client_id", id)
    .order("created_at", { ascending: false })
    .order("id", { ascending: true })
    .range(offset, offset + pageSize - 1);
  if (search) query = query.ilike("value", `%${search}%`);

  const { data, error, count } = await query;
  if (error) return failure(error);
  return Response.json({ entries: data ?? [], total: count ?? 0 });
}

// Accepts one pasted blob and sorts it by shape, so domains and emails can be
// pasted together - which is how they actually arrive from a client.
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();

  const payload = await request.json().catch(() => null) as { text?: unknown; reason?: unknown; requestId?: unknown } | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });
  const text = String(payload.text ?? "");
  const requestId = String(payload.requestId ?? "").trim();
  if (!text.trim()) return Response.json({ error: "Paste the domains or email addresses to block." }, { status: 400 });
  if (!/^[a-zA-Z0-9-]{8,100}$/.test(requestId)) return Response.json({ error: "A valid blocklist request id is required." }, { status: 400 });
  if (text.length > 250_000) return Response.json({ error: "This blocklist batch is too large. Please use the in-app batch processor." }, { status: 413 });

  const parsed = partitionBlocklistValues(text);
  if (parsed.submitted > BLOCKLIST_REQUEST_VALUES) {
    return Response.json({
      error: `For reliability, each request can process ${BLOCKLIST_REQUEST_VALUES.toLocaleString("en-IN")} entries. The app submits larger pastes automatically in batches.`,
    }, { status: 413 });
  }

  if (!parsed.emails.length && !parsed.domains.length) {
    return Response.json({
      error: "No valid domains or email addresses found in that list.",
      unrecognised: parsed.invalid,
    }, { status: 400 });
  }

  const { data, error } = await createAdminClient().rpc("add_client_blocklist_batch_v2", {
    p_client_id: id,
    p_domains: parsed.domains,
    p_emails: parsed.emails,
    p_reason: String(payload.reason ?? "").trim().slice(0, 300),
    p_actor: user?.email ?? "",
    p_request_id: requestId,
    p_match_limit: 5_000,
  });
  if (error) return failure(error);

  return Response.json({
    result: data,
    domains: parsed.domains.length,
    emails: parsed.emails.length,
    duplicates: parsed.duplicates,
    unrecognised: parsed.invalid,
    unrecognisedCount: parsed.invalidCount,
  });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();

  const payload = await request.json().catch(() => null) as { ids?: unknown } | null;
  const ids = Array.isArray(payload?.ids)
    ? [...new Set(payload.ids.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 5000)
    : [];
  if (!ids.length) return Response.json({ error: "Choose at least one entry to remove." }, { status: 400 });

  const { data, error } = await createAdminClient().rpc("remove_client_blocklist_v1", {
    p_client_id: id,
    p_ids: ids,
    p_actor: user?.email ?? "",
  });
  if (error) return failure(error);
  return Response.json({ result: data });
}
