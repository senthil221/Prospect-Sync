import { authorizeApi } from "../../../lib/auth";
import { normalizeText } from "../../../db/normalize";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const [summaries, settings] = await Promise.all([supabase.from("client_summaries").select("*").order("name"), supabase.from("client_settings").select("client_id,cooldown_days")]);
  if (summaries.error) return Response.json({ error: summaries.error.message }, { status: 500 });
  const cooldowns = new Map((settings.data ?? []).map((setting) => [setting.client_id, setting.cooldown_days]));
  return Response.json({ clients: (summaries.data ?? []).map((client) => ({ ...client, cooldown_days: cooldowns.get(client.id) ?? 90 })) });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { name } = await request.json() as { name?: string };
  const cleaned = String(name ?? "").trim();
  if (!cleaned) return Response.json({ error: "Client name is required." }, { status: 400 });
  const supabase = createAdminClient();
  const normalizedName = normalizeText(cleaned);
  const existing = await supabase.from("clients").select("id,name").eq("normalized_name", normalizedName).maybeSingle();
  if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
  if (existing.data) return Response.json({ client: existing.data });
  const client = { id: crypto.randomUUID(), name: cleaned, normalized_name: normalizedName };
  const { error } = await supabase.from("clients").insert(client);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ client: { id: client.id, name: client.name } }, { status: 201 });
}
