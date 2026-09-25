import { normalizeText } from "../../../db/normalize";
import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { data, error } = await createAdminClient().from("client_folders").select("id,name,created_at").order("name");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ folders: data ?? [] });
}
export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { name?: unknown } | null;
  const name = String(payload?.name ?? "").trim().slice(0, 120);
  if (!name) return Response.json({ error: "Folder name is required." }, { status: 400 });
  const normalizedName = normalizeText(name);
  const supabase = createAdminClient();
  const existing = await supabase.from("client_folders").select("id,name,created_at").eq("normalized_name", normalizedName).maybeSingle();
  if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
  if (existing.data) return Response.json({ folder: existing.data });
  const { data, error } = await supabase.from("client_folders")
    .insert({ name, normalized_name: normalizedName }).select("id,name,created_at").single();
  // The pre-read is for the common idempotent case, not concurrency control:
  // two tabs can both see no row and race the unique normalized_name index.
  // The loser resolves the winner instead of turning a harmless duplicate
  // create into a 500.
  if (error?.code === "23505") {
    const winner = await supabase.from("client_folders")
      .select("id,name,created_at").eq("normalized_name", normalizedName).maybeSingle();
    if (winner.error) return Response.json({ error: winner.error.message }, { status: 500 });
    if (winner.data) return Response.json({ folder: winner.data });
    return Response.json({ error: "A folder with that name already exists.", code: "folder_name_conflict" }, { status: 409 });
  }
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ folder: data }, { status: 201 });
}
