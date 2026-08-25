import { parseFilters, type ProspectFilter } from "./prospect-filters.ts";

// Bulk client operations take a filter payload, not a list of ids: "select all
// 40,000 matching, then push" has to be one request, not 40,000 ids over the
// wire. This is the shared shape for push, ICP verification, and removal.
export type BulkSelection = {
  search: string;
  filters: ProspectFilter[];
  prospectIds: string[] | null;
  excludedIds: string[] | null;
  sourceClientId: string | null;
};

const maxExplicitIds = 50000;

function idList(value: unknown, limit = maxExplicitIds) {
  if (!Array.isArray(value)) return null;
  const ids = [...new Set(value.map((id) => String(id ?? "").trim()).filter(Boolean))].slice(0, limit);
  return ids.length ? ids : null;
}

// Throws on a malformed Boolean expression, matching the workspace endpoints.
export function parseBulkSelection(payload: Record<string, unknown> | null): BulkSelection {
  return {
    search: String(payload?.search ?? "").trim().slice(0, 300),
    filters: parseFilters(JSON.stringify(payload?.filters ?? [])),
    prospectIds: idList(payload?.prospectIds ?? payload?.ids),
    excludedIds: idList(payload?.excludedIds),
    sourceClientId: String(payload?.sourceClientId ?? "").trim() || null,
  };
}

// An explicit id list and a filter payload are mutually exclusive downstream:
// the SQL prefers ids when present. Guard against a request that carries
// neither, which would otherwise mean "every prospect in the database".
export function isEmptySelection(selection: BulkSelection) {
  return !selection.prospectIds && !selection.search && selection.filters.length === 0;
}

export function selectionArgs(selection: BulkSelection) {
  return {
    p_search: selection.search,
    p_filters: selection.filters,
    p_prospect_ids: selection.prospectIds,
    p_excluded_ids: selection.excludedIds,
  };
}
