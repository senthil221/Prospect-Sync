import { authorizeApi } from "../../../lib/auth";
import { normalizeText } from "../../../db/normalize";
import { createAdminClient } from "../../../lib/supabase/admin";
import { observed } from "../../../lib/observability";

async function handleGET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const [summaries, settings, folders] = await Promise.all([
    // Cached until memberships or company text change (20260930250000).
    supabase.rpc("client_summaries_v1", { p_client_id: null }),
    supabase.from("client_settings").select("client_id,cooldown_days"),
    supabase.from("client_folders").select("id,name,created_at").order("name"),
  ]);
  const error = summaries.error ?? settings.error ?? folders.error;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const cooldowns = new Map((settings.data ?? []).map((setting) => [setting.client_id, setting.cooldown_days]));
  const folderNames = new Map((folders.data ?? []).map((folder) => [folder.id, folder.name]));
  return Response.json({
    clients: ((summaries.data ?? []) as Array<{ id: string; folder_id: string | null }>).map((client) => ({ ...client, folder_name: client.folder_id ? folderNames.get(client.folder_id) ?? null : null, cooldown_days: cooldowns.get(client.id) ?? 90 })),
    folders: folders.data ?? [],
  });
}

async function handlePOST(request: Request) {
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

export const GET = observed("/api/clients", handleGET);
export const POST = observed("/api/clients", handlePOST);
