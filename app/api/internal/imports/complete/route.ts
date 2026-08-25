import { after } from "next/server";
import { completeProspectImport } from "../../../../../lib/import-complete.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin.ts";
import { authorizeImportWorker } from "../../../../../lib/worker-auth.ts";

export async function POST(request: Request) {
  const unauthorized = authorizeImportWorker(request);
  if (unauthorized) return unauthorized;
  const { importId, listId } = await request.json() as { importId?: string; listId?: string };
  if (!importId || !listId) return Response.json({ error: "Invalid import." }, { status: 400 });
  const result = await completeProspectImport(importId, listId);
  if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
  if (result.conflict) return Response.json({ error: result.conflict }, { status: 409 });
  after(async () => {
    const { error } = await createAdminClient().rpc("analyze_prospect_index");
    if (error) console.error("Post-import ANALYZE failed", error);
  });
  return Response.json({ summary: result.summary });
}
