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

function scopeObject(raw: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(raw);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('A pivot scope must be an object.');
  const scope = parsed as Record<string, unknown>;
  if (scope.search !== undefined && (typeof scope.search !== 'string' || scope.search.trim().length > 300)) {
    throw new Error('Pivot search must be text of at most 300 characters.');
  }
  return scope;
}

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

export function parseCompanyScope(raw: string | null, options: { compileBoolean?: boolean } = {}): CompanyScope | null {
  if (!raw) return null;
  const parsed = scopeObject(raw);
  return {
    search: String(parsed.search ?? "").trim().slice(0, 300),
    filters: parseFilters(JSON.stringify(parsed.filters ?? []), options),
    limit: parseScopeLimit(parsed.limit),
  };
}

export function parsePeopleScope(raw: string | null, options: { compileBoolean?: boolean } = {}): PeopleScope | null {
  if (!raw) return null;
  const parsed = scopeObject(raw);
  return {
    search: String(parsed.search ?? "").trim().slice(0, 300),
    filters: parseFilters(JSON.stringify(parsed.filters ?? []), options),
    limit: parseScopeLimit(parsed.limit),
  };
}
