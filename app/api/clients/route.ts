import { authorizeApi } from "../../../lib/auth";
import { boundedDatabaseFailure } from "../../../lib/api-errors.ts";
import { clientSummarySignals, observeClientSummaryQuery } from "../../../lib/client-summary-query.ts";
import { normalizeText } from "../../../db/normalize";
import { createAdminClient } from "../../../lib/supabase/admin";
import { observed } from "../../../lib/observability";

type ClientDirectoryDependencies = {
  authorize: typeof authorizeApi;
  admin: typeof createAdminClient;
  signals: typeof clientSummarySignals;
};

const clientDirectoryDependencies: ClientDirectoryDependencies = {
  authorize: authorizeApi,
  admin: createAdminClient,
  signals: clientSummarySignals,
};

async function getClientDirectory(
  request: Request,
  dependencies: ClientDirectoryDependencies = clientDirectoryDependencies,
) {
  const unauthorized = await dependencies.authorize();
  if (unauthorized) return unauthorized;
  const supabase = dependencies.admin();
  const { callerSignal, deadlineSignal, signal } = dependencies.signals(request.signal);
  let summaries;
  let settings;
  let folders;
  try {
    [summaries, settings, folders] = await Promise.all([
      // Cached until memberships or company text change (20260930250000).
      observeClientSummaryQuery("directory", "counts",
        supabase.rpc("client_summaries_v1", { p_client_id: null }).abortSignal(signal),
        callerSignal, deadlineSignal),
      observeClientSummaryQuery("directory", "metadata",
        supabase.from("client_settings").select("client_id,cooldown_days,seg_emails").abortSignal(signal),
        callerSignal, deadlineSignal),
      observeClientSummaryQuery("directory", "metadata",
        supabase.from("client_folders").select("id,name,created_at").order("name").abortSignal(signal),
        callerSignal, deadlineSignal),
    ]);
  } catch (error) {
    return boundedDatabaseFailure({ callerSignal, deadlineSignal }, error, "The client directory", "Open a specific client instead.");
  }
  const error = summaries.error ?? settings.error ?? folders.error;
  if (error) return boundedDatabaseFailure({ callerSignal, deadlineSignal }, error, "The client directory", "Open a specific client instead.");
  const settingsByClient = new Map((settings.data ?? []).map((setting) => [setting.client_id, setting]));
  const folderNames = new Map((folders.data ?? []).map((folder) => [folder.id, folder.name]));
  return Response.json({
    clients: ((summaries.data ?? []) as Array<{ id: string; folder_id: string | null }>).map((client) => ({ ...client, folder_name: client.folder_id ? folderNames.get(client.folder_id) ?? null : null, cooldown_days: settingsByClient.get(client.id)?.cooldown_days ?? 90, seg_emails: settingsByClient.get(client.id)?.seg_emails ?? "keep" })),
    folders: folders.data ?? [],
  });
}

async function handleGET(request: Request) {
  return getClientDirectory(request);
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
