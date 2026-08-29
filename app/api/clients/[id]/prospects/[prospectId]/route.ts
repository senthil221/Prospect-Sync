import { authorizeApi, getAuthorizedUser } from "../../../../../../lib/auth.ts";
import { createAdminClient } from "../../../../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

// Removing one prospect is the same operation as removing a filtered segment,
// so it goes through the same function - one code path, one set of semantics:
// the client link goes, the master People DB record never does.
export async function DELETE(_request: Request, context: { params: Promise<{ id: string; prospectId: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id, prospectId } = await context.params;
  const user = await getAuthorizedUser();
  const supabase = createAdminClient();

  const { data, error } = await supabase.rpc("remove_prospects_from_client_v2", {
    p_client_id: id,
    p_search: "",
    p_filters: [],
    p_prospect_ids: [prospectId],
    p_excluded_ids: null,
    p_actor: user?.email ?? "",
  });
  if (error) {
    const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
    return Response.json(
      { error: missing ? "Apply the latest database migration to enable client-only prospect removal." : error.message },
      { status: missing ? 503 : error.code === "P0002" ? 404 : 500 },
    );
  }

  return Response.json({
    removedMemberships: Number((data as { removed?: number } | null)?.removed ?? 0),
    masterProspectPreserved: true,
  });
}
