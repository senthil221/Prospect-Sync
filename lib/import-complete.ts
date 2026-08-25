import { createAdminClient } from "./supabase/admin.ts";

export async function completeProspectImport(importId: string, listId: string) {
  const supabase = createAdminClient();
  const current = await supabase.from("imports")
    .select("processed_rows,unique_added,duplicates_linked,total_rows,status")
    .eq("id", importId).eq("list_id", listId).single();
  if (current.error) return { error: current.error };
  if (current.data.status !== "processing") return { conflict: "Import is not processing." };
  if (current.data.total_rows !== null && Number(current.data.processed_rows) !== Number(current.data.total_rows)) {
    return { conflict: `Import has committed ${current.data.processed_rows} of ${current.data.total_rows} rows.` };
  }
  const [importResult, listResult] = await Promise.all([
    supabase.from("imports").update({ status: "completed", completed_at: new Date().toISOString(), worker_id: null, lease_expires_at: null, last_error: null }).eq("id", importId).eq("status", "processing"),
    supabase.from("lists").update({
      uploaded_rows: current.data.processed_rows,
      unique_added: current.data.unique_added,
      duplicates_linked: current.data.duplicates_linked,
    }).eq("id", listId),
  ]);
  const error = importResult.error ?? listResult.error;
  if (error) return { error };
  return { summary: current.data };
}
