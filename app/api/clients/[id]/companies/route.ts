import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { authorizeFilterSets } from "../../../../../lib/filter-sets.ts";
import { MAX_BULK_COMPANY_MATCHES, parseCompanyBulkSelection } from "../../../../../lib/company-bulk-selection.ts";
import { filterErrorResponse, parseFilters } from "../../../../../lib/prospect-filters.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";
import { parsePeopleScope } from "../../../../../lib/workspace-scopes.ts";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  const { id: clientId } = await context.params;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const payload = decoded.value as Record<string, unknown> | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });

  const action = String(payload.action ?? "");
  if (action === "resolve_selection") {
    const rawValues = typeof payload.values === "string" ? payload.values : "";
    if (rawValues.length > 2_000_000) {
      return Response.json({ error: "Bulk company selection is limited to 2 MB of pasted text." }, { status: 413 });
    }
    const parsed = parseCompanyBulkSelection(rawValues);
    if (!parsed.submitted) {
      return Response.json({ error: "Paste at least one company website or name." }, { status: 400 });
    }

    const supabase = createAdminClient();
    const { data, error } = await supabase.rpc("resolve_client_company_selection_v1", {
      p_client_id: clientId,
      p_domains: parsed.domains.length ? parsed.domains : null,
      p_names: parsed.names.length ? parsed.names : null,
      p_limit: MAX_BULK_COMPANY_MATCHES,
    });
    if (error) {
      const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
      return Response.json(
        { error: missing ? "Apply the latest database migration to enable bulk company selection." : error.message },
        { status: missing ? 503 : error.code === "P0002" ? 404 : 500 },
      );
    }

    const companyIds = Array.isArray(data)
      ? data.map((row) => String((row as { company_id?: unknown }).company_id ?? "")).filter(Boolean)
      : [];
    return Response.json({ companyIds, matched: companyIds.length, submitted: parsed.submitted, truncated: parsed.truncated });
  }
  // Applying a client ICP tag to companies, to an explicit selection or to
  // everything matching the current search.
  //
  // It used to be explicit ids only, on the grounds that resolving an
  // all-matching company scope is the expensive half of this product. That is
  // true, and it is also exactly what push and ICP verification below already
  // do on every all-matching request, through the same
  // resolve_company_action_selection_v1 under the same 120s ceiling and 250,000
  // cap. Tagging was the only company action that had not been given the
  // arguments to do it - see 20260916170000. Once the ids are resolved it is
  // strictly the cheapest of the three: one insert or one delete.
  //
  // No re-index: prospect_index carries no company tags, so nothing it holds
  // changes. The tag's ownership is checked against the client inside the RPC,
  // before anything is resolved, so a workspace cannot reach another client's
  // tag by sending its id.
  if (action === "add_tag" || action === "remove_tag") {
    const tagId = String(payload.tagId ?? "").trim();
    const companyIds = Array.isArray(payload.companyIds)
      ? [...new Set(payload.companyIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
      : [];
    const tagAllMatching = payload.allMatching === true;
    if (!tagId) return Response.json({ error: "Choose an ICP tag." }, { status: 400 });
    // Without ids and without "all matching", this would tag the whole client.
    if (!companyIds.length && !tagAllMatching) {
      return Response.json({ error: "Select companies to tag." }, { status: 400 });
    }

    let tagFilters;
    let tagPeopleScope;
    try {
      tagFilters = parseFilters(JSON.stringify(payload.filters ?? []));
      tagPeopleScope = payload.peopleScope ? parsePeopleScope(JSON.stringify(payload.peopleScope)) : null;
    } catch (error) {
      return filterErrorResponse(error, "Invalid company selection.");
    }
    const tagExcluded = Array.isArray(payload.excludedIds)
      ? [...new Set(payload.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
      : [];

    const tagUser = await getAuthorizedUser();
    const tagSupabase = createAdminClient();
    // A saved filter set can only be spent by the person who owns it, and only
    // in the scope it was built for - the same check push and ICP verification
    // make. A tag applied through someone else's set would read another
    // client's segment through this client's workspace.
    if (tagAllMatching && !companyIds.length) {
      const setDenial = await authorizeFilterSets(tagSupabase, tagFilters, tagUser?.id ?? '', 'company', clientId,
        tagPeopleScope ? [{ entityType: 'prospect', clientScope: clientId, filters: tagPeopleScope.filters }] : []);
      if (setDenial) return setDenial;
    }

    const tagged = await tagSupabase.rpc("set_client_company_tag_v2", {
      p_client_id: clientId,
      p_tag_id: tagId,
      p_apply: action === "add_tag",
      p_company_ids: companyIds.length ? companyIds : null,
      // Empty unless this is an all-matching request, so an explicit selection
      // can never be widened by a filter left in the payload.
      p_search: tagAllMatching && !companyIds.length ? String(payload.search ?? "").trim().slice(0, 300) : "",
      p_filters: tagAllMatching && !companyIds.length ? tagFilters : [],
      p_people_scope: tagAllMatching && !companyIds.length ? tagPeopleScope : null,
      p_excluded_ids: tagAllMatching && !companyIds.length && tagExcluded.length ? tagExcluded : null,
      p_actor: tagUser?.email ?? "",
    });
    if (tagged.error) {
      const missing = Boolean(tagged.error.code && missingFunctionCodes.has(tagged.error.code));
      return Response.json(
        { error: missing ? "Apply the latest database migration to enable company ICP tags." : tagged.error.message },
        { status: missing ? 503 : tagged.error.code === "P0002" ? 404 : 500 },
      );
    }
    return Response.json({ result: tagged.data });
  }

  // Taking companies out of this client, and their people with them.
  //
  // NOT A DELETE, and the vocabulary is kept separate from one on purpose:
  // nothing in public.companies or public.prospects is touched and no other
  // client's links are affected. The master Company DB's Delete is the
  // destructive one and stays where it is.
  //
  // Two actions rather than one with a flag. "remove_preview" runs a STABLE
  // function that cannot write, so the confirmation can say "3 companies and
  // 416 people" before anything happens - and a company routinely carries
  // hundreds of people, which is the whole reason the preview exists.
  if (action === "remove" || action === "remove_preview") {
    const removeIds = Array.isArray(payload.companyIds)
      ? [...new Set(payload.companyIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
      : [];
    const removeAllMatching = payload.allMatching === true;
    if (!removeIds.length && !removeAllMatching) {
      return Response.json({ error: "Select companies to remove from this client." }, { status: 400 });
    }

    let removeFilters;
    let removePeopleScope;
    try {
      removeFilters = parseFilters(JSON.stringify(payload.filters ?? []));
      removePeopleScope = payload.peopleScope ? parsePeopleScope(JSON.stringify(payload.peopleScope)) : null;
    } catch (error) {
      return filterErrorResponse(error, "Invalid company selection.");
    }
    const removeExcluded = Array.isArray(payload.excludedIds)
      ? [...new Set(payload.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
      : [];

    const removeUser = await getAuthorizedUser();
    const removeSupabase = createAdminClient();
    if (removeAllMatching && !removeIds.length) {
      const setDenial = await authorizeFilterSets(removeSupabase, removeFilters, removeUser?.id ?? '', 'company', clientId,
        removePeopleScope ? [{ entityType: 'prospect', clientScope: clientId, filters: removePeopleScope.filters }] : []);
      if (setDenial) return setDenial;
    }

    // Identical selection arguments for both, so the preview cannot describe a
    // different set from the one the removal acts on.
    const selectionArgs = {
      p_client_id: clientId,
      p_company_ids: removeIds.length ? removeIds : null,
      p_search: removeAllMatching && !removeIds.length ? String(payload.search ?? "").trim().slice(0, 300) : "",
      p_filters: removeAllMatching && !removeIds.length ? removeFilters : [],
      p_people_scope: removeAllMatching && !removeIds.length ? removePeopleScope : null,
      p_excluded_ids: removeAllMatching && !removeIds.length && removeExcluded.length ? removeExcluded : null,
    };

    const removal = action === "remove_preview"
      ? await removeSupabase.rpc("client_company_removal_preview_v1", selectionArgs)
      : await removeSupabase.rpc("remove_companies_from_client_v1", { ...selectionArgs, p_actor: removeUser?.email ?? "" });

    if (removal.error) {
      const missing = Boolean(removal.error.code && missingFunctionCodes.has(removal.error.code));
      // 54000 is the people ceiling refusing rather than truncating. It is the
      // user's problem to narrow, not a server fault, so it must not read as one.
      if (removal.error.code === "54000") {
        return Response.json({ error: removal.error.message, code: "too_many_people" }, { status: 413 });
      }
      return Response.json(
        { error: missing ? "Apply the latest database migration to enable removing companies from a client." : removal.error.message },
        { status: missing ? 503 : removal.error.code === "P0002" ? 404 : 500 },
      );
    }
    return Response.json({ result: removal.data });
  }

  if (action !== "push" && action !== "set_icp_verified" && action !== "clear_icp_verified") {
    return Response.json({ error: "Unsupported client company action." }, { status: 400 });
  }

  const explicitIds = Array.isArray(payload.companyIds)
    ? [...new Set(payload.companyIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const allMatching = payload.allMatching === true;
  if (!explicitIds.length && !allMatching) {
    return Response.json({ error: `Select companies before ${action === "push" ? "pushing them" : "updating ICP verification"}.` }, { status: 400 });
  }

  let filters;
  let peopleScope;
  try {
    filters = parseFilters(JSON.stringify(payload.filters ?? []));
    peopleScope = payload.peopleScope ? parsePeopleScope(JSON.stringify(payload.peopleScope)) : null;
  } catch (error) {
    return filterErrorResponse(error, "Invalid company selection.");
  }

  const excludedIds = Array.isArray(payload.excludedIds)
    ? [...new Set(payload.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const user = await getAuthorizedUser();
  const supabase = createAdminClient();
  if (allMatching && !explicitIds.length) {
    const sourceScope = action === 'push' ? '' : clientId;
    const setDenial = await authorizeFilterSets(supabase, filters, user?.id ?? '', 'company', sourceScope,
      peopleScope ? [{ entityType: 'prospect', clientScope: sourceScope, filters: peopleScope.filters }] : []);
    if (setDenial) return setDenial;
  }
  const rpcName = action === "push" ? "push_companies_to_client_v1" : "set_company_icp_verified_v2";
  const rpcArgs = {
    p_client_id: clientId,
    p_company_ids: explicitIds.length ? explicitIds : null,
    p_search: allMatching ? String(payload.search ?? "").trim().slice(0, 300) : "",
    p_filters: allMatching ? filters : [],
    p_people_scope: allMatching ? peopleScope : null,
    p_excluded_ids: allMatching && excludedIds.length ? excludedIds : null,
    p_actor: user?.email ?? "",
  };
  const { data, error } = action === "push"
    ? await supabase.rpc(rpcName, rpcArgs)
    : await supabase.rpc(rpcName, { ...rpcArgs, p_verified: action === "set_icp_verified" });

  if (error) {
    const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
    return Response.json(
      { error: missing ? `Apply the latest database migration to enable company ${action === "push" ? "push" : "ICP verification"}.` : error.message },
      { status: missing ? 503 : error.code === "P0002" ? 404 : 500 },
    );
  }

  return Response.json({ result: data });
}
import { readBoundedJson } from "../../../../../lib/bounded-json";
