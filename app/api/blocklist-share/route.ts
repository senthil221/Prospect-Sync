import { createHash } from "node:crypto";
import { readBoundedJson } from "../../../lib/bounded-json.ts";
import { BLOCKLIST_REQUEST_VALUES, partitionBlocklistValues } from "../../../lib/bulk-values.ts";
import { createAdminClient } from "../../../lib/supabase/admin";

const allowedReasons = ["Client Provided", "ICP Invalid", "Campaign Reply"] as const;
function hash(value: string) { return createHash("sha256").update(value).digest("hex"); }
const headers = { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex, nofollow, noarchive" };
function json(body: unknown, status = 200) { return Response.json(body, { status, headers }); }

async function activeShare(token: string) {
  if (!/^[A-Za-z0-9_-]{40,80}$/.test(token)) return { data: null, error: null };
  return createAdminClient().from("client_blocklist_shares")
    .select("id,client_id,label,expires_at,client:clients(name)").eq("token_hash", hash(token))
    .is("revoked_at", null).or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`).maybeSingle();
}

export async function POST(request: Request) {
  const decoded = await readBoundedJson(request, { bytes: 64 * 1024, depth: 8, timeoutMs: 10_000 });
  if (decoded.response) return decoded.response;
  const payload = decoded.value as { token?: unknown; action?: unknown; text?: unknown; reason?: unknown; requestId?: unknown } | null;
  const token = String(payload?.token ?? "");
  const action = String(payload?.action ?? "info");
  const { data: share, error: shareError } = await activeShare(token);
  if (shareError) return json({ error: "Unable to use this submission link." }, 500);
  if (!share) return json({ error: "This submission link is invalid, expired, or revoked." }, 404);
  if (action === "info") {
    const client = Array.isArray(share.client) ? share.client[0] : share.client;
    return json({ clientName: client?.name ?? "Client", label: share.label, reasons: allowedReasons });
  }
  if (action !== "submit") return json({ error: "Invalid request." }, 400);
  const text = String(payload?.text ?? "");
  const reason = String(payload?.reason ?? "").trim();
  const requestId = String(payload?.requestId ?? "").trim();
  if (!allowedReasons.includes(reason as (typeof allowedReasons)[number])) return json({ error: "Choose a blocklist reason." }, 400);
  if (!/^[0-9a-f-]{36}$/i.test(requestId)) return json({ error: "Refresh this form and try again." }, 400);
  if (!text.trim() || text.length > 50_000) return json({ error: "Add a reasonable-sized list of domains or emails." }, 400);
  const parsed = partitionBlocklistValues(text);
  if (!parsed.domains.length && !parsed.emails.length) return json({ error: "No valid domains or emails were found." }, 400);
  if (parsed.submitted > BLOCKLIST_REQUEST_VALUES) return json({ error: `Submit at most ${BLOCKLIST_REQUEST_VALUES.toLocaleString("en-IN")} entries at a time.` }, 413);
  // The host proxy, not a browser-supplied field, sets these headers. The DB
  // also applies a share-wide bound, so spoofing one address cannot bypass it.
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || request.headers.get("x-real-ip") || "unknown";
  const { error } = await createAdminClient().rpc("enqueue_blocklist_share_submission_v1", {
    p_token_hash: hash(token), p_requester_hash: hash(forwarded), p_request_key: requestId,
    p_domains: parsed.domains, p_emails: parsed.emails, p_reason: reason,
  });
  if (error?.code === "P0003") return json({ error: "Too many submissions. Please try again later." }, 429);
  if (error?.code === "P0002") return json({ error: "This submission link is invalid, expired, or revoked." }, 404);
  if (error) return json({ error: "The submission could not be accepted. Please try again." }, 500);
  return json({ accepted: true }, 202);
}
