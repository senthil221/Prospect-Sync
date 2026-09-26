import { createHash, randomBytes } from "node:crypto";
import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";
import { blocklistShareOrigin } from "./public-origin";

function tokenHash(token: string) {
  return createHash("sha256").update(token).digest("hex");
}

export async function GET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const admin = createAdminClient();
  const [shares, failed, pending] = await Promise.all([
    admin.from("client_blocklist_shares").select("id,label,created_at,expires_at,revoked_at,last_submitted_at").eq("client_id", id).is("revoked_at", null).order("created_at", { ascending: false }),
    admin.from("client_blocklist_share_submissions").select("id", { count: "exact", head: true }).eq("client_id", id).eq("status", "failed"),
    admin.from("client_blocklist_share_submissions").select("id", { count: "exact", head: true }).eq("client_id", id).in("status", ["queued", "running"]),
  ]);
  const error = shares.error ?? failed.error ?? pending.error;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ shares: shares.data ?? [], queue: { failed: failed.count ?? 0, pending: pending.count ?? 0 } });
}

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();
  const payload = await request.json().catch(() => null) as { label?: unknown; expiresAt?: unknown } | null;
  const label = String(payload?.label ?? "Client blocklist form").trim().slice(0, 120) || "Client blocklist form";
  const expiresAt = payload?.expiresAt && !Number.isNaN(Date.parse(String(payload.expiresAt))) ? new Date(String(payload.expiresAt)).toISOString() : null;
  let origin: string;
  try { origin = blocklistShareOrigin(process.env.APP_PUBLIC_URL, request.url, process.env.NODE_ENV === "production"); }
  catch (caught) { return Response.json({ error: caught instanceof Error ? caught.message : "Unable to create a public link." }, { status: 500 }); }
  const token = randomBytes(32).toString("base64url");
  const { data, error } = await createAdminClient().from("client_blocklist_shares").insert({
    client_id: id, token_hash: tokenHash(token), label, expires_at: expiresAt, created_by: user?.email ?? "",
  }).select("id,label,created_at,expires_at,revoked_at,last_submitted_at").single();
  if (error) return Response.json({ error: error.message }, { status: error.code === "23503" ? 404 : 500 });
  return Response.json({ share: data, url: `${origin}/blocklist#token=${token}` }, { status: 201 });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const payload = await request.json().catch(() => null) as { shareId?: unknown } | null;
  const shareId = String(payload?.shareId ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(shareId)) return Response.json({ error: "Invalid share link." }, { status: 400 });
  const { data, error } = await createAdminClient().from("client_blocklist_shares")
    .update({ revoked_at: new Date().toISOString() }).eq("id", shareId).eq("client_id", id).is("revoked_at", null).select("id").maybeSingle();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!data) return Response.json({ error: "Active share link not found." }, { status: 404 });
  return Response.json({ revoked: true });
}

export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const payload = await request.json().catch(() => null) as { retryFailed?: unknown } | null;
  if (payload?.retryFailed !== true) return Response.json({ error: "Invalid retry request." }, { status: 400 });
  const { data, error } = await createAdminClient().from("client_blocklist_share_submissions")
    .update({ status: "queued", attempts: 0, last_error: null, worker_id: null, lease_expires_at: null })
    .eq("client_id", id).eq("status", "failed").select("id");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ retried: data?.length ?? 0 });
}
