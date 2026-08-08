import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

type ProspectFilter = { field: string; operator: "contains" | "equals" | "not_contains" | "not_equals" | "empty" | "not_empty"; values: string[] };

const allowedOperators = new Set(["contains", "equals", "not_contains", "not_equals", "empty", "not_empty"]);

function parseFilters(value: string | null): ProspectFilter[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.slice(0, 8).flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const candidate = item as Record<string, unknown>;
      const field = String(candidate.field ?? "").trim().slice(0, 160);
      const operator = String(candidate.operator ?? "contains");
      const rawValues = Array.isArray(candidate.values) ? candidate.values : [candidate.value];
      const values = rawValues.map((value) => String(value ?? "").trim().slice(0, 160)).filter(Boolean).slice(0, 30);
      if (!field || !allowedOperators.has(operator)) return [];
      if (!["empty", "not_empty"].includes(operator) && !values.length) return [];
      return [{ field, operator: operator as ProspectFilter["operator"], values }];
    });
  } catch {
    return [];
  }
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim().slice(0, 300);
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const sort = ["created_at", "name", "company", "title", "last_contacted"].includes(url.searchParams.get("sort") ?? "") ? String(url.searchParams.get("sort")) : "created_at";
  const direction = url.searchParams.get("direction") === "asc" ? "asc" : "desc";
  const clientId = (url.searchParams.get("clientId") ?? "").trim() || null;
  const includeFields = url.searchParams.get("includeFields") !== "0";
  const limit = 50;
  const filters = parseFilters(url.searchParams.get("filters"));
  const supabase = createAdminClient();
  const workspaceRequest = (async () => {
    let workspace = await supabase.rpc("search_prospect_workspace_v4", {
      p_search: search,
      p_filters: filters,
      p_sort: sort,
      p_direction: direction,
      p_limit: limit,
      p_offset: (page - 1) * limit,
      p_client_id: clientId,
    });
    if (workspace.error?.code === "PGRST202" || workspace.error?.code === "42883") {
      if (clientId) return workspace;
      workspace = await supabase.rpc("search_prospect_workspace_v3", { p_search: search, p_filters: filters, p_sort: sort, p_direction: direction, p_limit: limit, p_offset: (page - 1) * limit });
    }
    if (workspace.error?.code === "PGRST202" || workspace.error?.code === "42883") {
      workspace = await supabase.rpc("search_prospect_workspace", { p_search: search, p_filters: filters.filter((filter) => !["not_contains", "not_equals"].includes(filter.operator)), p_limit: limit, p_offset: (page - 1) * limit });
    }
    return workspace;
  })();
  const fieldsRequest = includeFields
    ? supabase.from("prospect_fields").select("field_name").order("field_name").limit(500)
    : Promise.resolve({ data: [] as Array<{ field_name: string }>, error: null });
  const [workspace, fields] = await Promise.all([workspaceRequest, fieldsRequest]);
  if (clientId && (workspace.error?.code === "PGRST202" || workspace.error?.code === "42883")) {
    return Response.json({ error: "Apply the latest database migration to enable client workspaces." }, { status: 503 });
  }
  const error = workspace.error ?? fields.error;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const summary = Array.isArray(workspace.data) ? workspace.data[0] : workspace.data;
  return Response.json({
    prospects: summary?.result_rows ?? [],
    total: Number(summary?.total_count ?? 0),
    page,
    limit,
    fields: (fields.data ?? []).map((item) => item.field_name),
  });
}
