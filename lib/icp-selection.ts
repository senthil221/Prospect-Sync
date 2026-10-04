import { withClientCompanyScope } from "./client-workspace-completeness.ts";
import { authorizeFilterSets } from "./filter-sets.ts";
import { filterErrorResponse, parseFilters } from "./prospect-filters.ts";
import { createAdminClient } from "./supabase/admin.ts";
import { parsePeopleScope } from "./workspace-scopes.ts";

// A Company DB selection for an ICP check: the ticked (or pasted and resolved)
// ids, or everything matching the workspace's search and filters. Parsed and
// checked exactly as the Company DB's other bulk actions are
// (app/api/clients/[id]/companies), and resolved once in the database by
// resolve_company_action_selection_v1. Shared by the ICP Validator and ICP
// checks routes.

export type IcpSelectionArgs = {
  p_company_ids: string[] | null; p_search: string; p_filters: unknown; p_people_scope: unknown; p_excluded_ids: string[] | null;
};

const bad = (error: string) => Response.json({ error }, { status: 400 });

export async function readIcpSelection(clientId: string, body: Record<string, unknown>, userId: string, verb: string): Promise<
  { args: IcpSelectionArgs; error?: never } | { args?: never; error: Response }
> {
  const companyIds = Array.isArray(body.companyIds)
    ? [...new Set(body.companyIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const allMatching = body.allMatching === true;
  if (!companyIds.length && !allMatching) return { error: bad(`Select companies to ${verb}.`) };

  let parsedFilters;
  let peopleScope;
  try {
    parsedFilters = withClientCompanyScope(parseFilters(JSON.stringify(body.filters ?? [])), clientId);
    peopleScope = body.peopleScope ? parsePeopleScope(JSON.stringify(body.peopleScope)) : null;
  } catch (error) {
    return { error: filterErrorResponse(error, "Invalid company selection.") };
  }
  const excludedIds = Array.isArray(body.excludedIds)
    ? [...new Set(body.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const widening = allMatching && !companyIds.length;
  if (widening) {
    const setDenial = await authorizeFilterSets(createAdminClient(), parsedFilters, userId, "company", clientId,
      peopleScope ? [{ entityType: "prospect", clientScope: clientId, filters: peopleScope.filters }] : []);
    if (setDenial) return { error: setDenial };
  }
  return {
    args: {
      p_company_ids: companyIds.length ? companyIds : null,
      // Empty unless this is an all-matching request, so an explicit selection
      // can never be widened by a filter left in the payload.
      p_search: widening ? String(body.search ?? "").trim().slice(0, 300) : "",
      p_filters: widening ? parsedFilters : [],
      p_people_scope: widening ? peopleScope : null,
      p_excluded_ids: widening && excludedIds.length ? excludedIds : null,
    },
  };
}
