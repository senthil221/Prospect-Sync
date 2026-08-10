import { compileBooleanSearch } from "./boolean-search";

export type ProspectFilterOperator =
  | "contains" | "equals" | "not_contains" | "not_equals"
  | "empty" | "not_empty" | "boolean" | "number_ranges";

export type ProspectFilter = { field: string; operator: ProspectFilterOperator; values: string[] };

const allowedOperators = new Set<string>([
  "contains", "equals", "not_contains", "not_equals", "empty", "not_empty", "boolean", "number_ranges",
]);

// Sanitize an untrusted filters JSON string into a bounded, well-formed filter list.
// Throws only when a Boolean expression fails to compile.
export function parseFilters(value: string | null): ProspectFilter[] {
  if (!value) return [];
  const parsed = JSON.parse(value) as unknown;
  if (!Array.isArray(parsed)) return [];
  return parsed.slice(0, 20).flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const candidate = item as Record<string, unknown>;
    const field = String(candidate.field ?? "").trim().slice(0, 160);
    const operator = String(candidate.operator ?? "contains");
    const rawValues = Array.isArray(candidate.values) ? candidate.values : [candidate.value];
    let values = rawValues.map((entry) => String(entry ?? "").trim().slice(0, operator === "boolean" ? 1000 : 160)).filter(Boolean).slice(0, 50);
    if (!field || !allowedOperators.has(operator)) return [];
    if (!["empty", "not_empty"].includes(operator) && !values.length) return [];
    if (operator === "boolean") values = [compileBooleanSearch(values[0])];
    if (operator === "number_ranges") values = values.filter((range) => range === "unknown" || /^[0-9]+:[0-9]*$/.test(range));
    if (operator === "number_ranges" && !values.length) return [];
    return [{ field, operator: operator as ProspectFilterOperator, values }];
  });
}
