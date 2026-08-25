import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const clientId = new URL(request.url).searchParams.get("clientId");
  if (!clientId) return Response.json({ lists: [] });
  const { data, error } = await createAdminClient().from("list_summaries").select("*").eq("client_id", clientId).order("created_at", { ascending: false });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ lists: data ?? [] });
}

// Create an empty list for a client. Until now a list could only come into
// existence as a side effect of a CSV import, which left no way to push people from
// the People database into a brand-new list.
export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { clientId?: unknown; name?: unknown } | null;
  const clientId = String(payload?.clientId ?? "").trim();
  const name = String(payload?.name ?? "").trim().slice(0, 240);
  if (!clientId) return Response.json({ error: "Choose a client for the list." }, { status: 400 });
  if (!name) return Response.json({ error: "List name is required." }, { status: 400 });

  const supabase = createAdminClient();
  const client = await supabase.from("clients").select("id").eq("id", clientId).maybeSingle();
  if (client.error) return Response.json({ error: client.error.message }, { status: 500 });
  if (!client.data) return Response.json({ error: "Client not found." }, { status: 404 });

  // Reuse a same-named list rather than creating a confusing duplicate.
  const existing = await supabase.from("lists").select("id,name").eq("client_id", clientId).ilike("name", name).maybeSingle();
  if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
  if (existing.data) return Response.json({ list: existing.data });

  const list = { id: crypto.randomUUID(), client_id: clientId, name };
  const { error } = await supabase.from("lists").insert(list);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ list: { id: list.id, name: list.name } }, { status: 201 });
}
