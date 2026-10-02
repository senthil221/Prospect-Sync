import { authorizeApi } from "../../../../lib/auth";
import { deleteAndReindex, queuedNotice } from "../../../../lib/delete-cleanup.ts";
import { createAdminClient } from "../../../../lib/supabase/admin";
import { observed } from "../../../../lib/observability.ts";

async function handleGET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  const [summary, setting, folder] = await Promise.all([
    supabase.rpc("client_summaries_v1", { p_client_id: id }),
    supabase.from("client_settings").select("cooldown_days,seg_emails").eq("client_id", id).maybeSingle(),
    supabase.from("clients").select("folder_id").eq("id", id).maybeSingle(),
  ]);
  const error = summary.error ?? setting.error ?? folder.error;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const client = ((summary.data ?? []) as Array<{ id: string; folder_id: string | null }>)[0];
  if (!client) return Response.json({ error: "Client not found." }, { status: 404 });
  const folderId = folder.data?.folder_id ?? client.folder_id ?? null;
  const folderName = folderId
    ? await supabase.from("client_folders").select("name").eq("id", folderId).maybeSingle()
    : null;
  if (folderName?.error) return Response.json({ error: folderName.error.message }, { status: 500 });
  return Response.json({
    client: {
      ...client,
      folder_id: folderId,
      folder_name: folderName?.data?.name ?? null,
      cooldown_days: setting.data?.cooldown_days ?? 90,
      seg_emails: setting.data?.seg_emails ?? "keep",
    },
  }, { headers: { "Cache-Control": "no-store" } });
}

async function handlePATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const payload = await request.json().catch(() => null) as { cooldownDays?: unknown; segEmails?: unknown; folderId?: unknown; archived?: unknown } | null;
  if (!payload) return Response.json({ error: "Invalid client update." }, { status: 400 });
  const supabase = createAdminClient();
  if (payload.archived !== undefined) {
    if (typeof payload.archived !== "boolean") return Response.json({ error: "Archived must be true or false." }, { status: 400 });
    const { data, error } = await supabase.from("clients")
      .update({ archived_at: payload.archived ? new Date().toISOString() : null })
      .eq("id", id).select("id,archived_at").single();
    if (error) return Response.json({ error: error.message }, { status: error.code === "PGRST116" ? 404 : 500 });
    return Response.json({ client: data });
  }
  if (payload.folderId !== undefined) {
    const folderId = payload.folderId === null ? null : String(payload.folderId ?? "").trim();
    if (folderId) {
      const folder = await supabase.from("client_folders").select("id").eq("id", folderId).maybeSingle();
      if (folder.error) return Response.json({ error: folder.error.message }, { status: 500 });
      if (!folder.data) return Response.json({ error: "Folder not found." }, { status: 404 });
    }
    const { data, error } = await supabase.from("clients").update({ folder_id: folderId }).eq("id", id).select("id,folder_id").single();
    if (error) return Response.json({ error: error.message }, { status: error.code === "PGRST116" ? 404 : 500 });
    return Response.json({ client: data });
  }
  // Keep or discard people behind a secure email gateway. The database applies
  // it to every view of this client from the next query (20261003100000).
  if (payload.segEmails !== undefined) {
    if (payload.segEmails !== "keep" && payload.segEmails !== "discard") return Response.json({ error: "SEG emails must be keep or discard." }, { status: 400 });
    const { data, error } = await supabase.from("client_settings")
      .upsert({ client_id: id, seg_emails: payload.segEmails, updated_at: new Date().toISOString() })
      .select("seg_emails").single();
    if (error) return Response.json({ error: error.message }, { status: error.code === "23503" ? 404 : 500 });
    return Response.json({ segEmails: data.seg_emails });
  }
  const days = payload?.cooldownDays;
  if (typeof days !== "number" || !Number.isInteger(days) || days < 0 || days > 730) {
    return Response.json({ error: "Contact cooldown must be a whole number between 0 and 730 days." }, { status: 400 });
  }
  const { data, error } = await supabase.from("client_settings").upsert({ client_id: id, cooldown_days: days, updated_at: new Date().toISOString() }).select("cooldown_days").single();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ cooldownDays: data.cooldown_days });
}

async function handleDELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  // Delete and re-index in one server-side call: a large client owns far too
  // many prospects to ship their ids over HTTP just to hand straight back.
  // Client-side deletes never touch the People/Company databases - only the
  // client, its lists, imports, and membership links are removed.
  const { data, error } = await deleteAndReindex(supabase, "delete_client_and_reindex_v1", "delete_client_with_cleanup", { p_client_id: id });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  return Response.json({ result: data, notice: queuedNotice(data) });
}

export const GET = observed("/api/clients/[id]", handleGET);
export const PATCH = observed("/api/clients/[id]", handlePATCH);
export const DELETE = observed("/api/clients/[id]", handleDELETE);
