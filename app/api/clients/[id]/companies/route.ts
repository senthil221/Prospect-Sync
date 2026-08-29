import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { MAX_BULK_COMPANY_MATCHES, parseCompanyBulkSelection } from "../../../../../lib/company-bulk-selection.ts";
import { parseFilters } from "../../../../../lib/prospect-filters.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";
import { parsePeopleScope } from "../../../../../lib/workspace-scopes.ts";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  const { id: clientId } = await context.params;
  const payload = await request.json().catch(() => null) as Record<string, unknown> | null;
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
  if (action !== "set_icp_validated" && action !== "clear_icp_validated") {
    return Response.json({ error: "Unsupported client company action." }, { status: 400 });
  }

  const explicitIds = Array.isArray(payload.companyIds)
    ? [...new Set(payload.companyIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const allMatching = payload.allMatching === true;
  if (!explicitIds.length && !allMatching) {
    return Response.json({ error: "Select companies before updating ICP validation." }, { status: 400 });
  }

  let filters;
  let peopleScope;
  try {
    filters = parseFilters(JSON.stringify(payload.filters ?? []));
    peopleScope = payload.peopleScope ? parsePeopleScope(JSON.stringify(payload.peopleScope)) : null;
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Invalid company selection." }, { status: 400 });
  }

  const excludedIds = Array.isArray(payload.excludedIds)
    ? [...new Set(payload.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const user = await getAuthorizedUser();
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("set_company_icp_validated_v1", {
    p_client_id: clientId,
    p_validated: action === "set_icp_validated",
    p_company_ids: explicitIds.length ? explicitIds : null,
    p_search: allMatching ? String(payload.search ?? "").trim().slice(0, 300) : "",
    p_filters: allMatching ? filters : [],
    p_people_scope: allMatching ? peopleScope : null,
    p_excluded_ids: allMatching && excludedIds.length ? excludedIds : null,
    p_actor: user?.email ?? "",
  });

  if (error) {
    const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
    return Response.json(
      { error: missing ? "Apply the latest database migration to enable company ICP validation." : error.message },
      { status: missing ? 503 : error.code === "P0002" ? 404 : 500 },
    );
  }

  return Response.json({ result: data });
}
