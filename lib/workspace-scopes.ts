import { parseFilters, type ProspectFilter } from "./prospect-filters.ts";
import { clientCompanyScopeField, clientSegPolicyField, validateClientCompanyScopeFilters, withClientCompanyScope } from "./client-workspace-completeness.ts";

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

// Server-injected origin/SEG predicates never count as the user's request to
// create a pivot. An explicit incomplete-profile predicate does: it is how the
// Incomplete Info workspace deliberately asks for its partition.
export function companyScopeHasIntent(scope: CompanyScope | null) {
  return Boolean(scope && (scope.search.trim() !== "" || scope.filters.some((filter) =>
    filter.field !== clientCompanyScopeField && filter.field !== clientSegPolicyField)));
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

// Bind a Company -> People pivot to the client workspace that created it.
// Server-owned predicates do not make an otherwise empty pivot meaningful: an
// unfiltered Client Company DB already leads to the same client's People DB.
export function normalizeCompanyScope(
  scope: CompanyScope | null,
  clientId: string | null | undefined,
): CompanyScope | null {
  if (!scope) return null;
  validateClientCompanyScopeFilters(scope.filters);
  const hasServerScope = scope.filters.some((filter) => filter.field === clientCompanyScopeField);
  if (!clientId && hasServerScope) {
    throw new Error("Client company scope is server-managed.");
  }
  if (!companyScopeHasIntent(scope)) return null;
  const filters = withClientCompanyScope(scope.filters, clientId);
  return filters === scope.filters ? scope : { ...scope, filters };
}

export function hasUnsupportedPeoplePivot(payload: Record<string, unknown>, options: { compileBoolean?: boolean } = {}) {
  if (!Object.prototype.hasOwnProperty.call(payload, "peopleScope") || payload.peopleScope === null || payload.peopleScope === undefined) {
    return false;
  }
  // JSON.stringify preserves false/0/empty-string, so malformed present values
  // fail instead of being silently treated as absent by a truthiness check.
  const encoded = JSON.stringify(payload.peopleScope);
  if (encoded === undefined) throw new Error("A people pivot scope must be JSON serializable.");
  return scopeRestricts(parsePeopleScope(encoded, options));
}
