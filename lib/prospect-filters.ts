import { compileBooleanSearch } from "./boolean-search.ts";

export type ProspectFilterOperator =
  | "contains" | "equals" | "not_contains" | "not_equals"
  | "empty" | "not_empty" | "boolean" | "number_ranges";

export type ProspectFilter = { field: string; operator: ProspectFilterOperator; values: string[]; scopes?: string[] };

const allowedOperators = new Set<string>([
  "contains", "equals", "not_contains", "not_equals", "empty", "not_empty", "boolean", "number_ranges",
]);

// A pasted spreadsheet column is routinely hundreds of domains long. The old cap
// of 50 silently discarded everything past the fiftieth value, so a 500-domain
// filter quietly returned the wrong answer. Values past this cap are still
// dropped silently, so the number has to be comfortably above real list sizes.
//
// Raised from 1,000 once pasted lists became an indexed equality test rather than
// a chain of ILIKE (20260901000000) and the company scope stopped calling the
// per-row predicate (20260901000080). Measured end to end on 674,804 prospects
// and 418,151 companies:
//
//   domains   Companies tab    See People    export
//     1,000        545 ms         ~1.2 s      ~2.1 s
//     2,000           -            1.9 s         -
//     5,000        950 ms          3.1 s       4.3 s
//    10,000        860 ms         10.0 s         -
//
// The Companies tab is flat because it is index lookups; the pivot is what grows,
// because it carries the whole value list into the scope. 5,000 keeps every
// surface under about 4.5s with room as the database grows toward 2M, where
// 10,000 sits at ten seconds today and would only get worse.
const maxFilterValues = 5000;
const maxFilters = 40;
const companyKeywordScopes = new Set(["name", "keywords", "description"]);
const defaultCompanyKeywordScopes = ["name", "keywords"];

// Sanitize an untrusted filters JSON string into a bounded, well-formed filter list.
// Throws only when a Boolean expression fails to compile.
export function parseFilters(value: string | null): ProspectFilter[] {
  if (!value) return [];
  const parsed = JSON.parse(value) as unknown;
  if (!Array.isArray(parsed)) return [];
  return parsed.slice(0, maxFilters).flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const candidate = item as Record<string, unknown>;
    const field = String(candidate.field ?? "").trim().slice(0, 160);
    const operator = String(candidate.operator ?? "contains");
    const rawValues = Array.isArray(candidate.values) ? candidate.values : [candidate.value];
    let values = rawValues.map((entry) => String(entry ?? "").trim().slice(0, operator === "boolean" ? 1000 : 160)).filter(Boolean).slice(0, maxFilterValues);
    if (!field || !allowedOperators.has(operator)) return [];
    if (!["empty", "not_empty"].includes(operator) && !values.length) return [];
    if (operator === "boolean") values = [compileBooleanSearch(values[0])];
    if (operator === "number_ranges") values = values.filter((range) => range === "unknown" || /^[0-9]+:[0-9]*$/.test(range));
    if (operator === "number_ranges" && !values.length) return [];
    const requestedScopes = Array.isArray(candidate.scopes) ? candidate.scopes : [];
    const scopes = field === "__company_keywords"
      ? [...new Set(requestedScopes.map((scope) => String(scope)).filter((scope) => companyKeywordScopes.has(scope)))].slice(0, 3)
      : [];
    return [{ field, operator: operator as ProspectFilterOperator, values,
      ...(field === "__company_keywords" ? { scopes: scopes.length ? scopes : defaultCompanyKeywordScopes } : {}) }];
  });
}
