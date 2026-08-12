import { authorizeApi } from "../../../../lib/auth";
import { reindexProspects } from "../../../../lib/reindex";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const payload = await request.json().catch(() => ({})) as { deleteOrphans?: boolean };
  const supabase = createAdminClient();
  const affected = await supabase.from("list_rows").select("prospect_id").eq("import_id", id);
  const { data, error } = await supabase.rpc("delete_import_with_cleanup", {
    p_import_id: id,
    p_delete_orphans: payload.deleteOrphans === true,
  });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  await reindexProspects(supabase, (affected.data ?? []).map((row) => row.prospect_id));
  return Response.json({ result: data });
}
