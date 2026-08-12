import { authorizeApi } from "../../../../../../lib/auth";
import { reindexProspects } from "../../../../../../lib/reindex";
import { createAdminClient } from "../../../../../../lib/supabase/admin";

export async function DELETE(_request: Request, context: { params: Promise<{ id: string; prospectId: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id, prospectId } = await context.params;
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("remove_prospect_from_client_v1", {
    p_client_id: id,
    p_prospect_id: prospectId,
  });
  if (error) {
    const missing = error.code === "PGRST202" || error.code === "42883";
    return Response.json({ error: missing ? "Apply the latest database migration to enable client-only prospect removal." : error.message }, { status: missing ? 503 : 500 });
  }
  await reindexProspects(supabase, [prospectId]);
  return Response.json({ removedMemberships: Number(data ?? 0), masterProspectPreserved: true });
}
