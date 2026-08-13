import { authorizeApi } from "../../../../lib/auth";
import { reindexProspects } from "../../../../lib/reindex";
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
  const clientLists = await supabase.from("lists").select("id").eq("client_id", id);
  const listIds = (clientLists.data ?? []).map((row) => row.id);
  const affected = listIds.length
    ? await supabase.from("list_memberships").select("prospect_id").in("list_id", listIds)
    : { data: [] as Array<{ prospect_id: string }> };
  // Client-side deletes never touch the People/Company databases: only the
  // client, its lists, imports, and membership links are removed.
  const { data, error } = await supabase.rpc("delete_client_with_cleanup", {
    p_client_id: id,
    p_delete_orphans: false,
  });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  await reindexProspects(supabase, (affected.data ?? []).map((row) => row.prospect_id));
  return Response.json({ result: data });
}
