import { authorizeApi } from "../../../../lib/auth";
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
  const payload = await request.json().catch(() => ({})) as { deleteOrphans?: boolean };
  const { data, error } = await createAdminClient().rpc("delete_client_with_cleanup", {
    p_client_id: id,
    p_delete_orphans: payload.deleteOrphans !== false,
  });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  return Response.json({ result: data });
}
