import { normalizeText } from "../../../../db/normalize";
import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  const { id } = await context.params;
  const payload = await request.json().catch(() => null) as { name?: unknown } | null;
  const name = String(payload?.name ?? "").trim().slice(0, 120);
  if (!name) return Response.json({ error: "Folder name is required." }, { status: 400 });

  const { data, error } = await createAdminClient().from("client_folders")
    .update({ name, normalized_name: normalizeText(name), updated_at: new Date().toISOString() })
    .eq("id", id)
    .select("id,name,created_at")
    .single();

  if (error?.code === "23505") {
    return Response.json({ error: "A folder with that name already exists.", code: "folder_name_conflict" }, { status: 409 });
  }
  if (error) {
    return Response.json({ error: error.code === "PGRST116" ? "Folder not found." : error.message },
      { status: error.code === "PGRST116" ? 404 : 500 });
  }
  return Response.json({ folder: data });
}

export async function DELETE(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  const { id } = await context.params;
  // client.folder_id uses ON DELETE SET NULL, so deleting the folder moves all
  // of its active and archived clients to Unfiled without deleting workspaces.
  const { data, error } = await createAdminClient().from("client_folders")
    .delete().eq("id", id).select("id").maybeSingle();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!data) return Response.json({ error: "Folder not found." }, { status: 404 });
  return Response.json({ deleted: true });
}
