import { after } from "next/server";
import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { importId, listId } = await request.json() as { importId?: string; listId?: string };
  if (!importId || !listId) return Response.json({ error: "Invalid import." }, { status: 400 });
  const supabase = createAdminClient();
  const current = await supabase.from("imports").select("processed_rows,unique_added,duplicates_linked").eq("id", importId).single();
  if (current.error) return Response.json({ error: current.error.message }, { status: 500 });
  const [importResult, listResult] = await Promise.all([
    supabase.from("imports").update({ status: "completed", completed_at: new Date().toISOString() }).eq("id", importId),
    supabase.from("lists").update({
      uploaded_rows: current.data.processed_rows,
      unique_added: current.data.unique_added,
      duplicates_linked: current.data.duplicates_linked,
    }).eq("id", listId),
  ]);
  const error = importResult.error ?? listResult.error;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  after(async () => {
    try {
      const { error: analyzeError } = await supabase.rpc("analyze_prospect_index");
      if (analyzeError) console.error("Post-import ANALYZE failed", analyzeError);
    } catch (analyzeError) {
      console.error("Post-import ANALYZE failed", analyzeError);
    }
  });
  return Response.json({ summary: current.data });
}
