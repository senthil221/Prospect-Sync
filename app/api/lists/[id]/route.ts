import { authorizeApi } from "../../../../lib/auth";
import { deleteAndReindex, queuedNotice } from "../../../../lib/delete-cleanup.ts";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const clientId = new URL(request.url).searchParams.get("clientId")?.trim();
  if (!clientId) return Response.json({ error: "Client id is required." }, { status: 400 });
  const { data, error } = await createAdminClient().from("list_summaries")
    .select("*").eq("id", id).eq("client_id", clientId).maybeSingle();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!data) return Response.json({ error: "List not found for this client." }, { status: 404 });
  return Response.json({ list: data }, { headers: { "Cache-Control": "no-store" } });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  // Client-side deletes never touch the People/Company databases: only the
  // list, its imports, and its membership links are removed. Survivors keep
  // their index rows but lost a membership, so they are re-indexed inside the
  // same call rather than by shipping every id back over HTTP.
  const { data, error } = await deleteAndReindex(supabase, "delete_list_and_reindex_v1", "delete_list_with_cleanup", { p_list_id: id });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  return Response.json({ result: data, notice: queuedNotice(data) });
}
