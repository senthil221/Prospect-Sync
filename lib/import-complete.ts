import { createAdminClient } from "./supabase/admin.ts";

export async function completeProspectImport(importId: string, listId: string) {
  const supabase = createAdminClient();
  const result = await supabase.rpc("complete_prospect_import_v2", { p_import_id: importId, p_list_id: listId });
  if (result.error) {
    if (["40001", "P0002"].includes(result.error.code ?? "")) return { conflict: result.error.message };
    return { error: result.error };
  }
  const payload = result.data && typeof result.data === "object" && !Array.isArray(result.data)
    ? result.data as { summary?: unknown; verificationRunId?: string | null }
    : {};
  return { summary: payload.summary, verificationRunId: payload.verificationRunId ?? null };
}
