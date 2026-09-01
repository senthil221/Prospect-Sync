import { parseFilters, type ProspectFilter } from "./prospect-filters.ts";

export type CompanyScope = {
  search: string;
  filters: ProspectFilter[];
  limit: number;
};

export type PeopleScope = {
  search: string;
  filters: ProspectFilter[];
  limit: number;
};

export const workspacePivotLimit = 250_000;

// A pivot only means something when the tab you came from was narrowing anything.
// "Every company's people" is just "every person", and the database treats it that
// way -- so carrying an empty scope across only produces a banner claiming a
// restriction that is not being applied.
export function scopeRestricts(scope: { search: string; filters: unknown[] } | null) {
  return Boolean(scope && (scope.search.trim() !== "" || scope.filters.length > 0));
}

function parseScopeLimit(value: unknown) {
  const parsed = Number(value ?? workspacePivotLimit);
  if (!Number.isFinite(parsed)) return workspacePivotLimit;
  return Math.max(1_000, Math.min(workspacePivotLimit, Math.floor(parsed)));
}

export function parseCompanyScope(raw: string | null): CompanyScope | null {
  if (!raw) return null;
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  return {
    search: String(parsed.search ?? "").trim().slice(0, 300),
    filters: parseFilters(JSON.stringify(parsed.filters ?? [])),
    limit: parseScopeLimit(parsed.limit),
  };
}

export function parsePeopleScope(raw: string | null): PeopleScope | null {
  if (!raw) return null;
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  return {
    search: String(parsed.search ?? "").trim().slice(0, 300),
    filters: parseFilters(JSON.stringify(parsed.filters ?? [])),
    limit: parseScopeLimit(parsed.limit),
  };
}
