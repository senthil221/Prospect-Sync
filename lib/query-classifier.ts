import type { ProspectFilter } from "./prospect-filters.ts";

// Decide where a query runs, without asking the database.
//
// Section 6.1: "The classifier never runs EXPLAIN on the request path." Plans
// and cost-to-latency relationships are measured offline and turned into
// deterministic rules here. That is the whole design: an EXPLAIN per request
// would put the cost it is trying to avoid onto the path it is trying to
// protect, and would be one more thing holding a pool connection.
//
// CLASSIFIER_VERSION is part of the cache key, not decoration. A classification
// keyed on filter content alone would survive an index build, an ANALYZE or a
// recalibration - and then route a now-indexed shape to background, or worse, a
// now-unindexed shape to interactive. Bump it whenever the matrix or the
// calibration below changes.
export const CLASSIFIER_VERSION = 1;

export type QueryRoute = "interactive" | "interactive_capped" | "background";

export type Classification = {
  route: QueryRoute;
  reason: string;
  classifierVersion: number;
  // The filter that decided it, when one did. Lets the UI say which control to
  // change rather than "this query is too complex".
  field?: string;
};

// Which (field, substring) pairs an index can serve, from the actual catalogue
// on prospect_index rather than from intent. Every entry here was verified
// against pg_indexes; the eight added in 20260902000080 carry their measured
// before/after in that migration.
//
// A trigram index cannot serve a pattern with no full trigram in it, which is
// why shortSubstringLength exists below rather than this being the whole story.
const trigramServedFields = new Set([
  "__name", "__first_name", "__last_name", "__company", "__company_domain",
  "__title", "__work_email", "__personal_email", "__linkedin",
  "__city", "__state", "__country", "__person_location",
  "__company_country", "__seniority", "__department", "__tags",
]);

// Fields whose substring form has no index and is not expected to get one,
// because the values are broad enough that a sequential scan with early stop is
// the correct plan. Measured in 20260902000080: company_state 22% of rows, esp
// 32%. Section 6.1 rule 4 - these stay interactive, capped.
const broadUnindexedFields = new Set([
  "__company_state", "__company_city", "__esp", "__email_provider_type",
  "__title_seniority", "__esp_type", "__company_location", "__keywords",
  "__lists", "__clients",
]);

// pg_trgm extracts no full trigram from a one or two character pattern, so the
// index degrades to a full scan through the index plus a recheck of every row.
// Measured on production: full_name ILIKE '%vp%' went from a ~530 ms parallel
// sequential scan to a 1,107 ms bitmap scan with 674,652 rows removed by
// recheck. Still bounded, so it stays interactive - but it is not indexed work
// and must not be counted as such.
const shortSubstringLength = 3;

// Section 6.1 rule 2. Above this many substring terms the generated predicate
// stops being something the planner can narrow with, which 20260902000030
// measured directly.
const maxInteractiveSubstringTerms = 100;

// Custom fields read all_data as jsonb with no index. One is affordable; a
// filter set full of them is not.
const maxInteractiveCustomFields = 2;

const substringOperators = new Set(["contains", "not_contains"]);
const negativeOperators = new Set(["not_contains", "not_equals", "empty"]);

function isCustomField(field: string) {
  return field.startsWith("custom:");
}

// An equality is index-served whenever the column has any index at all -
// trigram indexes answer equality too, and the array fields have GIN. A
// set-backed equality is a primary-key probe per row (20260902000110).
function equalityIsCheap(filter: ProspectFilter) {
  if (filter.setId) return true;
  return trigramServedFields.has(filter.field)
    || filter.field === "__lists" || filter.field === "__clients"
    || filter.field === "__keywords" || filter.field === "__employee_count"
    || filter.field.startsWith("__title_");
}

function substringTermCount(filter: ProspectFilter) {
  return substringOperators.has(filter.operator) ? filter.values.length : 0;
}

// Classify one request. Pure: same AST in, same answer out, so it can be cached
// under (content hash, classifier version) exactly as section 6.1 describes.
export function classifyQuery(filters: ProspectFilter[], search = ""): Classification {
  const version = CLASSIFIER_VERSION;
  const answer = (route: QueryRoute, reason: string, field?: string): Classification =>
    ({ route, reason, classifierVersion: version, field });

  // Rule 2, first because it is the one that actually breaks things: a pasted
  // column of substring terms.
  const heaviest = filters
    .map((filter) => ({ filter, terms: substringTermCount(filter) }))
    .sort((a, b) => b.terms - a.terms)[0];
  if (heaviest && heaviest.terms > maxInteractiveSubstringTerms) {
    return answer("background",
      `${heaviest.terms.toLocaleString("en-IN")} substring terms is past the ${maxInteractiveSubstringTerms} that can be narrowed interactively.`,
      heaviest.filter.field);
  }

  // Rule 1, for the shape with no index and no early stop to rely on.
  const customFields = filters.filter((filter) => isCustomField(filter.field));
  if (customFields.length > maxInteractiveCustomFields) {
    return answer("background",
      `${customFields.length} custom-field filters each read the raw JSON of every row.`,
      customFields[0].field);
  }

  // Rule 3. A filter set that only excludes has nothing to narrow with, so it
  // reads everything to prove a negative. A positive alongside it changes that,
  // which is why this asks about the set rather than about one filter.
  const usable = filters.filter((filter) => filter.operator !== "not_empty");
  if (usable.length > 0 && usable.every((filter) => negativeOperators.has(filter.operator))) {
    return answer("background",
      "Every filter here excludes rather than selects, so there is nothing to narrow with first.",
      usable[0].field);
  }

  // Rule 5. Boolean is an inline tsvector match: not index-served, but bounded
  // and early-stopping, so it stays interactive unless something else in the
  // set is already expensive. 20260831230000 measured why no vector index is
  // built for it.
  const hasBoolean = filters.some((filter) => filter.operator === "boolean");

  // Anything that will be a sequential scan, counted rather than judged one at
  // a time - the cost is the scan, and several of them share it.
  const scanning = filters.filter((filter) => {
    if (!substringOperators.has(filter.operator)) return false;
    if (isCustomField(filter.field)) return true;
    if (broadUnindexedFields.has(filter.field)) return true;
    if (!trigramServedFields.has(filter.field)) return true;
    // Indexed, but too short for a trigram to be extracted from.
    return filter.values.some((value) => value.length < shortSubstringLength);
  });

  if (hasBoolean && scanning.length > 0) {
    return answer("background",
      "A Boolean expression combined with a filter that cannot use an index reads the whole table more than once.",
      scanning[0].field);
  }
  if (hasBoolean) {
    return answer("interactive_capped",
      "Boolean search scans and stops early; the count is capped rather than exact.");
  }

  if (scanning.length > 0) {
    const short = scanning.find((filter) => filter.values.some((value) => value.length < shortSubstringLength));
    if (short) {
      return answer("interactive_capped",
        "A one or two character search cannot use the text index, so this scans; the count is capped.",
        short.field);
    }
    return answer("interactive_capped",
      "This filter has no index to narrow with, so it scans and stops early; the count is capped.",
      scanning[0].field);
  }

  // Everything left is either index-served or free.
  const uncheapEquality = filters.find((filter) => filter.operator === "equals" && !equalityIsCheap(filter));
  if (uncheapEquality) {
    return answer("interactive_capped",
      "This filter matches exactly but has no index, so the count is capped.",
      uncheapEquality.field);
  }

  if (!filters.length && !search.trim()) {
    return answer("interactive", "No filters: the listing reads the index directly.");
  }
  return answer("interactive", "Every filter here is served by an index.");
}

// The cache key section 6.1 asks for: content identity plus the classifier
// version, so a classification does not outlive the calibration that produced
// it.
export function classificationCacheKey(contentHash: string) {
  return `${contentHash}:c${CLASSIFIER_VERSION}`;
}
