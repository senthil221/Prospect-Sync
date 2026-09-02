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

export type FilterLimitKind = "filters" | "values" | "value_length";

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
export function parseFilters(value: string | null): ProspectFilter[] {
  if (!value) return [];
  const parsed = JSON.parse(value) as unknown;
  if (!Array.isArray(parsed)) return [];
  if (parsed.length > maxFilters) {
    throw new FilterLimitError("filters", parsed.length, maxFilters, null,
      `Remove filters until at most ${maxFilters} remain, or save the narrow ones as a view and apply them in two passes.`);
  }
  return parsed.flatMap((item): ProspectFilter[] => {
    if (!item || typeof item !== "object") return [];
    const candidate = item as Record<string, unknown>;
    const field = String(candidate.field ?? "").trim().slice(0, 160);
    const operator = String(candidate.operator ?? "contains");
    // Unknown fields and operators are dropped rather than refused: they carry no
    // rows either way, and the field catalogue check belongs with the versioned
    // AST. The caps below only ever fire on a filter that would have been used.
    if (!field || !allowedOperators.has(operator)) return [];

    // Set-backed: the values live in the database, so none of the size caps
    // below apply - nothing is being carried. Only equality is expressible
    // against a set, matching what the compilers emit.
    const rawSetId = typeof candidate.setId === "string" ? candidate.setId.trim() : "";
    if (rawSetId) {
      if (!uuidPattern.test(rawSetId) || operator !== "equals") return [];
      return [{ field, operator: operator as ProspectFilterOperator, values: [], setId: rawSetId }];
    }

    const rawValues = Array.isArray(candidate.values) ? candidate.values : [candidate.value];
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
