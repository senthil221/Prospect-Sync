import { after } from "next/server";
import { authorizeApi } from "../../../../lib/auth";
import { completeProspectImport } from "../../../../lib/import-complete.ts";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { importId, listId } = await request.json() as { importId?: string; listId?: string };
  if (!importId || !listId) return Response.json({ error: "Invalid import." }, { status: 400 });
  const completed = await completeProspectImport(importId, listId);
  if (completed.error) return Response.json({ error: completed.error.message }, { status: 500 });
  if (completed.conflict) return Response.json({ error: completed.conflict }, { status: 409 });
  after(async () => {
    try {
      const supabase = createAdminClient();
      const { error: analyzeError } = await supabase.rpc("analyze_prospect_index");
      if (analyzeError) console.error("Post-import ANALYZE failed", analyzeError);
    } catch (analyzeError) {
      console.error("Post-import ANALYZE failed", analyzeError);
    }
  });
  return Response.json({ summary: completed.summary });
}
