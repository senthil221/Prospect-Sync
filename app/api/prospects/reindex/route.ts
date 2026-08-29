import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

export const runtime = "nodejs";
export const maxDuration = 60;

// Manual full rebuild of the flat prospect_index - a safety net. Normal operation
// keeps the index fresh incrementally through reindex hooks on every write path.
export async function POST() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("reindex_all");
  if (error) {
    const migrationMissing = error.code === "PGRST202" || error.code === "42883" || error.code === "42P01";
    return Response.json(
      { error: migrationMissing ? "Apply the search-index migration before rebuilding the index." : error.message },
      { status: migrationMissing ? 503 : 500 },
    );
  }
  return Response.json({ indexed: Number(data ?? 0) });
}
