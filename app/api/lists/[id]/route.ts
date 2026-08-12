import { authorizeApi } from "../../../../lib/auth";
import { reindexProspects } from "../../../../lib/reindex";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const payload = await request.json().catch(() => ({})) as { deleteOrphans?: boolean };
  const supabase = createAdminClient();
  const affected = await supabase.from("list_memberships").select("prospect_id").eq("list_id", id);
  const { data, error } = await supabase.rpc("delete_list_with_cleanup", {
    p_list_id: id,
    p_delete_orphans: payload.deleteOrphans === true,
  });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  // Survivors keep their index rows but lost a membership; deleted prospects cascade out.
  await reindexProspects(supabase, (affected.data ?? []).map((row) => row.prospect_id));
  return Response.json({ result: data });
}
