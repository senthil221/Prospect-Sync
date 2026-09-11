import { authorizeApi } from "../../../../lib/auth";
import { withInteractiveSlot } from "../../../../lib/admission";
import { createAdminClient } from "../../../../lib/supabase/admin";
import { emptyTaxonomy, type TitleTaxonomy } from "../../../../lib/title-taxonomy";

// The values the Job Title & Seniority pickers offer, with counts.
//
// One scan over prospect_index behind GROUPING SETS, about a second on the full
// database, so it is cached rather than fetched per keystroke - the panel asks
// once when it opens. Counts are scoped to the client when the caller is inside
// a client workspace, because a client DB showing master-wide counts would be
// telling the user about people that view cannot reach.
const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const clientId = (new URL(request.url).searchParams.get("clientId") ?? "").trim();

  return withInteractiveSlot(request, async () => {
    const supabase = createAdminClient();
    // The master-wide taxonomy is the same answer for everyone and costs a full
    // scan (2.3s now, past its 30s ceiling at 10M), so it is read from the
    // snapshot. A client-scoped one is not snapshotted - it is per workspace,
    // and narrower, so it still computes.
    const { data, error } = clientId
      ? await supabase.rpc("prospect_title_taxonomy_v1", { p_client_id: clientId })
      : await supabase.rpc("dashboard_snapshot_v1", { p_key: "titleTaxonomy" })
        .then((result) => ({
          ...result,
          data: (result.data as { payload?: unknown } | null)?.payload ?? null,
        }));
    if (error) {
      // Additive: a database one migration behind returns an empty taxonomy, and
      // the panel falls back to its plain value box rather than failing to open.
      if (error.code && missingFunctionCodes.has(error.code)) {
        return Response.json({ taxonomy: emptyTaxonomy, available: false });
      }
      return Response.json({ error: error.message }, { status: 500 });
    }
    const taxonomy = (data ?? emptyTaxonomy) as TitleTaxonomy;
    return Response.json({
      taxonomy: {
        tiers: Array.isArray(taxonomy.tiers) ? taxonomy.tiers : [],
        departments: Array.isArray(taxonomy.departments) ? taxonomy.departments : [],
        undefinedSeniority: Number(taxonomy.undefinedSeniority ?? 0),
        undefinedDepartment: Number(taxonomy.undefinedDepartment ?? 0),
      },
      available: true,
    });
  });
}
