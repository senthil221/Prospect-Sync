import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { mergeBulkValues } from "../../../../../lib/bulk-values.ts";
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

  let query = createAdminClient()
    .from("client_blocklist")
    .select("id,kind,value,reason,source,created_at", { count: "exact" })
    .eq("client_id", id)
    .order("created_at", { ascending: false })
    .limit(500);
  if (search) query = query.ilike("value", `%${search}%`);

  const { data, error, count } = await query;
  if (error) return failure(error);
  return Response.json({ entries: data ?? [], total: count ?? 0 });
}

// Accepts one pasted blob and sorts it by shape, so domains and emails can be
// pasted together — which is how they actually arrive from a client.
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();

  const payload = await request.json().catch(() => null) as { text?: unknown; reason?: unknown } | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });
  const text = String(payload.text ?? "");
  if (!text.trim()) return Response.json({ error: "Paste the domains or email addresses to block." }, { status: 400 });

  // Run the same text through both parsers: an entry is an email if it parses as
  // one, otherwise a domain. Normalization matches the import path, so a pasted
  // "https://www.acme.com/careers" blocks acme.com.
  const emails = mergeBulkValues([], text, "email");
  const emailSet = new Set(emails.values.map((value) => value.toLocaleLowerCase()));
  const domainSource = emails.invalid.join("\n");
  const domains = mergeBulkValues([], domainSource, "domain");
  const unrecognised = domains.invalid;

  if (!emails.values.length && !domains.values.length) {
    return Response.json({
      error: "No valid domains or email addresses found in that list.",
      unrecognised: unrecognised.slice(0, 10),
    }, { status: 400 });
  }

  const { data, error } = await createAdminClient().rpc("add_client_blocklist_v1", {
    p_client_id: id,
    p_domains: domains.values,
    p_emails: [...emailSet],
    p_reason: String(payload.reason ?? "").trim().slice(0, 300),
    p_actor: user?.email ?? "",
  });
  if (error) return failure(error);

  return Response.json({
    result: data,
    domains: domains.values.length,
    emails: emailSet.size,
    unrecognised: unrecognised.slice(0, 10),
    unrecognisedCount: unrecognised.length,
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
