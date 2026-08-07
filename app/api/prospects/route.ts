import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

type ProspectFilter = { field: string; operator: "contains" | "equals" | "empty" | "not_empty"; values: string[] };

const allowedOperators = new Set(["contains", "equals", "empty", "not_empty"]);

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
      if ((operator === "contains" || operator === "equals") && !values.length) return [];
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
  const limit = 50;
  const filters = parseFilters(url.searchParams.get("filters"));
  const supabase = createAdminClient();
  const [workspace, fields] = await Promise.all([
    supabase.rpc("search_prospect_workspace", {
      p_search: search,
      p_filters: filters,
      p_limit: limit,
      p_offset: (page - 1) * limit,
    }),
    supabase.from("prospect_fields").select("field_name").order("field_name").limit(500),
  ]);
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
