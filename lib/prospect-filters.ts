import { compileBooleanSearch } from "./boolean-search.ts";

export type ProspectFilterOperator =
  | "contains" | "equals" | "not_contains" | "not_equals"
  | "empty" | "not_empty" | "boolean" | "number_ranges";

export type ProspectFilter = { field: string; operator: ProspectFilterOperator; values: string[]; scopes?: string[]; setId?: string };

// A durable filter set is addressed by id; its values are rows in the database
// (migration 20260902000100). The id is checked for shape here and for ownership
// before the query runs - a set id is not authorization on its own.
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function filterSetIds(filters: ProspectFilter[]) {
  return [...new Set(filters.map((filter) => filter.setId).filter((id): id is string => Boolean(id)))];
}

const allowedOperators = new Set<string>([
  "contains", "equals", "not_contains", "not_equals", "empty", "not_empty", "boolean", "number_ranges",
]);

const companyKeywordScopes = new Set(["name", "keywords", "description"]);
const defaultCompanyKeywordScopes = ["name", "keywords"];

// A pasted spreadsheet column is routinely hundreds of domains long. The old cap
// of 50 silently discarded everything past the fiftieth value, so a 500-domain
// filter quietly returned the wrong answer. Values past this cap are no longer
// dropped -- the request is refused with a FilterLimitError (413) before it
// reaches the database -- so the number still has to sit comfortably above real
// list sizes.
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
export const maxFilterValues = 5000;

// 50 simultaneously active filters is the stated target workload, so the refusal
// threshold sits above it rather than on it. Past 60 the generated SQL grows
// faster than the answer improves -- see 20260902000030 on values x filters.
export const maxFilters = 60;

// Per-value length. A Boolean value is one compiled tsquery expression, so it
// gets a larger budget than a pasted cell. Trimming either one silently changes
// which rows match, so both are refusals rather than clamps.
export const maxValueLength = 160;
export const maxBooleanValueLength = 1000;
// Per-filter ceilings do not bound a whole query: 60 × 5,000 is 300,000
// predicates. These budgets cover the complete inline query, including pivots.
export const maxQueryInlineValues = 20_000;
export const maxQueryFilterBytes = 1_048_576;

export type FilterLimitKind = "filters" | "values" | "value_length" | "total_values" | "request_bytes";

// Thrown instead of trimming. Carries everything an API route needs to answer
// 413 with actionable numbers: what arrived, what is allowed, which filter, and
// what to do instead.
export class FilterLimitError extends Error {
  readonly kind: FilterLimitKind;
  readonly received: number;
  readonly allowed: number;
  readonly field: string | null;
  readonly alternative: string;

  constructor(kind: FilterLimitKind, received: number, allowed: number, field: string | null, alternative: string) {
    const subject = kind === "filters" ? "filters"
      : kind === "values" ? "filter values"
      : kind === "total_values" ? "inline values across the query"
      : kind === "request_bytes" ? "bytes of filter data"
      : "characters in a filter value";
    super(`This request carries ${received} ${subject}; at most ${allowed} are allowed.`);
    this.name = "FilterLimitError";
    this.kind = kind;
    this.received = received;
    this.allowed = allowed;
    this.field = field;
    this.alternative = alternative;
  }
}

// One rejection shape for every filter entry point. A limit breach is a 413
// carrying the numbers needed to fix the request; anything else parseFilters
// throws (a Boolean expression that will not compile) stays a 400.
//
// The remedy is folded into `error` as well as returned as a field, because every
// current UI surface shows that one string (lib/dashboard-api.ts). A caller that
// wants to build its own message reads the structured fields instead.
export function filterErrorResponse(error: unknown, fallback: string): Response {
  if (error instanceof FilterLimitError) {
    return Response.json({
      error: `${error.message} ${error.alternative}`,
      limit: error.kind,
      received: error.received,
      allowed: error.allowed,
      field: error.field,
      alternative: error.alternative,
    }, { status: 413 });
  }
  return Response.json({ error: error instanceof Error ? error.message : fallback }, { status: 400 });
}

// Sanitize an untrusted filters JSON string into a bounded, well-formed filter list.
// Throws FilterLimitError when the request exceeds a cap, or a compile error when a
// Boolean expression is malformed. Nothing is silently trimmed: a filter this
// function cannot honour exactly is refused, never narrowed.
export function parseFilters(value: string | null, options: { compileBoolean?: boolean } = {}): ProspectFilter[] {
  if (!value) return [];
  const inputBytes = new TextEncoder().encode(value).byteLength;
  if (inputBytes > maxQueryFilterBytes) throw new FilterLimitError('request_bytes', inputBytes, maxQueryFilterBytes, null,
    'Reduce the inline filter data, or use saved value lists for exact matching. No values were dropped.');
  const parsed = JSON.parse(value) as unknown;
  if (!Array.isArray(parsed)) throw new Error('Filters must be an array. No filters were applied.');
  if (parsed.length > maxFilters) {
    throw new FilterLimitError("filters", parsed.length, maxFilters, null,
      `Remove filters until at most ${maxFilters} remain, or save the narrow ones as a view and apply them in two passes.`);
  }
  const filters = parsed.flatMap((item): ProspectFilter[] => {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error('Each filter must be an object.');
    const candidate = item as Record<string, unknown>;
    const field = typeof candidate.field === 'string' ? candidate.field.trim() : '';
    const operator = candidate.operator ?? 'contains';
    // Dropping a malformed predicate can broaden a read or filtered mutation.
    // Field-catalogue validation remains the compiler's responsibility.
    if (!field || field.length > 160) throw new Error('A filter field must contain 1–160 characters.');
    if (typeof operator !== 'string' || !allowedOperators.has(operator)) throw new Error('Unsupported filter operator.');

    // Set-backed: the values live in the database, so none of the size caps
    // below apply - nothing is being carried. Only equality is expressible
    // against a set, matching what the compilers emit.
    const rawSetId = typeof candidate.setId === "string" ? candidate.setId.trim() : "";
    if (candidate.setId !== undefined) {
      if (!uuidPattern.test(rawSetId) || operator !== "equals") throw new Error('Stored filter references require a valid ID and equality matching.');
      if (candidate.value !== undefined || (candidate.values !== undefined && (!Array.isArray(candidate.values) || candidate.values.length > 0))) {
        throw new Error('Use either inline filter values or a stored filter reference, not both.');
      }
      return [{ field, operator: operator as ProspectFilterOperator, values: [], setId: rawSetId }];
    }

    if (candidate.values !== undefined && !Array.isArray(candidate.values)) throw new Error('Filter values must be an array.');
    const rawValues = Array.isArray(candidate.values) ? candidate.values : [candidate.value];
    if (rawValues.some(entry => entry != null && typeof entry !== 'string' && typeof entry !== 'number' && typeof entry !== 'boolean')) {
      throw new Error('Filter values must be text, numbers or booleans.');
    }
    if (rawValues.length > maxFilterValues) {
      throw new FilterLimitError("values", rawValues.length, maxFilterValues, field,
        `Split this list into batches of ${maxFilterValues} values or fewer and run them one at a time.`);
    }
    const allowedLength = operator === "boolean" ? maxBooleanValueLength : maxValueLength;
    const trimmed = rawValues.map((entry) => String(entry ?? "").trim());
    const overlong = trimmed.find((entry) => entry.length > allowedLength);
    if (overlong !== undefined) {
      throw new FilterLimitError("value_length", overlong.length, allowedLength, field,
        operator === "boolean"
          ? "Shorten the Boolean expression."
          : "Check for a pasted cell that ran together with the next one; each value must be a single entry.");
    }
    let values = trimmed.filter(Boolean);
    if (!["empty", "not_empty"].includes(operator) && !values.length) return [];
    if (operator === "boolean") {
      if (values.length !== 1) throw new Error('A Boolean filter must contain exactly one expression.');
      const compiled = compileBooleanSearch(values[0]);
      // URL/UI restoration validates the expression but must retain its source.
      // Compiling it there would cause the API to compile PostgreSQL syntax twice.
      if (options.compileBoolean !== false) values = [compiled];
    }
    if (operator === "number_ranges" && values.some(range => {
      if (range === 'unknown') return false;
      if (!/^[0-9]+:[0-9]*$/.test(range)) return true;
      const [lower, upper] = range.split(':');
      return !Number.isSafeInteger(Number(lower)) || (upper !== '' && (!Number.isSafeInteger(Number(upper)) || Number(upper) < Number(lower)));
    })) throw new Error('Each numeric range must have valid bounds, with the upper bound at least the lower bound.');
    const requestedScopes = Array.isArray(candidate.scopes) ? candidate.scopes : [];
    if (field === '__company_keywords' && candidate.scopes !== undefined &&
      (!Array.isArray(candidate.scopes) || requestedScopes.some(scope => typeof scope !== 'string' || !companyKeywordScopes.has(scope)))) {
      throw new Error('Unsupported company keyword search scope.');
    }
    const scopes = field === "__company_keywords"
      ? [...new Set(requestedScopes.map((scope) => String(scope)).filter((scope) => companyKeywordScopes.has(scope)))].slice(0, 3)
      : [];
    return [{ field, operator: operator as ProspectFilterOperator, values,
      ...(field === "__company_keywords" ? { scopes: scopes.length ? scopes : defaultCompanyKeywordScopes } : {}) }];
  });
  assertQueryFilterBudget([filters]);
  return filters;
}

export function assertQueryFilterBudget(groups: ProspectFilter[][]) {
  let values = 0;
  let bytes = 0;
  const encoder = new TextEncoder();
  for (const filters of groups) {
    values += filters.reduce((sum, filter) => sum + filter.values.length, 0);
    bytes += encoder.encode(JSON.stringify(filters)).byteLength;
  }
  if (values > maxQueryInlineValues) throw new FilterLimitError('total_values', values, maxQueryInlineValues, null,
    'Reduce inline values across the main filters and pivots, or use saved value lists for exact matching. No values were dropped.');
  if (bytes > maxQueryFilterBytes) throw new FilterLimitError('request_bytes', bytes, maxQueryFilterBytes, null,
    'Reduce the combined filter data across the main query and pivots. No values were dropped.');
}
