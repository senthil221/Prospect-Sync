import { authorizeApi } from "../../../../lib/auth";
import { deleteAndReindex, queuedNotice } from "../../../../lib/delete-cleanup.ts";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const { cooldownDays } = await request.json() as { cooldownDays?: number };
  const days = Math.max(0, Math.min(730, Math.round(Number(cooldownDays ?? 90))));
  const { data, error } = await createAdminClient().from("client_settings").upsert({ client_id: id, cooldown_days: days, updated_at: new Date().toISOString() }).select("cooldown_days").single();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ cooldownDays: data.cooldown_days });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
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
