import { after } from "next/server";
import { authorizeApi } from "../../../../lib/auth";
import { databaseErrorResponse } from "../../../../lib/api-errors";
import { logServerEvent } from "../../../../lib/server-log";
import { reindexCompanyImport } from "../../../../lib/reindex";
import { createAdminClient } from "../../../../lib/supabase/admin";

// Completing a company import is now two separable things, and the separation
// is the whole fix.
//
// It used to be one RPC that flipped the status AND rebuilt prospect_index in
// the same transaction. For a 12,498-company import that is 131,769 index rows
// rewritten inside a 120s ceiling, and when it blew the ceiling the 57014 took
// the status flip down with it - so the import stayed 'processing' and the
// retry started the same 131,769 rows again. It could never finish.
//
// Now the RPC decides the import and queues the index work, which is fast and
// returns here. Draining that queue is the slow half, so it happens after the
// response, and durably: the rows are in reindex_backlog whether or not this
// process survives the next minute, and the operations worker drains them
// either way. Nothing below this line is load-bearing for correctness.
export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { importId?: unknown } | null;
  const importId = String(payload?.importId ?? "").trim();
  if (!importId) return Response.json({ error: "Invalid company import." }, { status: 400 });
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("complete_company_import_v1", { p_import_id: importId });
  if (error) {
    // P0002 is now reserved for an id that genuinely does not exist; completing
    // an already-completed import is deliberately not an error.
    if (error.code === "P0002") return Response.json({ error: "That company import no longer exists." }, { status: 404 });
    return databaseErrorResponse("Completing the company import", error);
  }
  after(async () => {
    try {
      const outcome = await reindexCompanyImport(supabase, importId);
      // A stale index should be visible in the Logs tab rather than inferred
      // from search results being wrong.
      logServerEvent({
        level: outcome.degraded || outcome.remaining ? "warn" : "info",
        source: "company-imports",
        message: outcome.degraded
          ? "Company import re-index degraded"
          : `Company import re-index queued ${outcome.queued}, indexed ${outcome.reindexed}`,
        detail: { importId, ...outcome },
      });
    } catch (reindexError) {
      console.error("Post-import re-index failed", reindexError);
      logServerEvent({ level: "error", source: "company-imports", message: "Post-import re-index failed", detail: reindexError });
    }
    try {
      const { error: analyzeError } = await supabase.rpc("analyze_prospect_index");
      if (analyzeError) {
        console.error("Post-import ANALYZE failed", analyzeError);
        logServerEvent({ level: "error", source: "company-imports", message: "Post-import ANALYZE failed", detail: analyzeError });
      }
    } catch (analyzeError) {
      console.error("Post-import ANALYZE failed", analyzeError);
      logServerEvent({ level: "error", source: "company-imports", message: "Post-import ANALYZE failed", detail: analyzeError });
    }
  });
  return Response.json({ summary: data?.[0] ?? null });
}
