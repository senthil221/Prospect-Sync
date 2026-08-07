import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const payload = await request.json().catch(() => ({})) as { deleteOrphans?: boolean };
  const { data, error } = await createAdminClient().rpc("delete_import_with_cleanup", {
    p_import_id: id,
    p_delete_orphans: payload.deleteOrphans !== false,
  });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  return Response.json({ result: data });
}
