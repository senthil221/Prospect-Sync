import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { data, error } = await createAdminClient().from("saved_views").select("*").order("updated_at", { ascending: false });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ views: data ?? [] });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id, name, definition } = await request.json() as { id?: string; name?: string; definition?: unknown };
  const cleanedName = String(name ?? "").trim().slice(0, 80);
  if (!cleanedName || !definition || typeof definition !== "object") return Response.json({ error: "View name and definition are required." }, { status: 400 });
  const view = { id: id || crypto.randomUUID(), name: cleanedName, definition, updated_at: new Date().toISOString() };
  const { data, error } = await createAdminClient().from("saved_views").upsert(view).select("*").single();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ view: data });
}

export async function DELETE(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const id = new URL(request.url).searchParams.get("id");
  if (!id) return Response.json({ error: "View id is required." }, { status: 400 });
  const { error } = await createAdminClient().from("saved_views").delete().eq("id", id);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ deleted: true });
}
