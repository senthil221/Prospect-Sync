// Which fields actually differ, and who you are keeping.
//
// QUALITY-04 and QUALITY-05. The duplicate review showed two cards side by side,
// each listing every populated field it had, and asked "Keep left" or "Keep
// right". Two problems, both of them the same problem: the screen made you do
// the comparison, and then it made you hold the answer in your head.
//
// Twenty identical fields and two different ones render at identical weight, so
// finding the difference is a manual scan of both columns. And "left" is not a
// property of a person - it is a property of where the card happened to land,
// which is decided by the order the API returned. Reordering the response would
// silently invert the meaning of both buttons.

import { parseAllData } from "./dashboard-helpers.ts";
import type { Prospect } from "./types.ts";

export type FieldComparison = {
  field: string;
  left: string;
  right: string;
  /** same: both present and equal. differs: both present, not equal. only-left / only-right: one side is blank. */
  state: "same" | "differs" | "only-left" | "only-right";
};

const namedFields: Array<[string, (prospect: Prospect) => unknown]> = [
  ["Full name", (prospect) => prospect.full_name],
  ["Title", (prospect) => prospect.title],
  ["Company", (prospect) => prospect.company_name],
  ["Work email", (prospect) => prospect.work_email],
  ["Personal email", (prospect) => prospect.personal_email],
  ["LinkedIn", (prospect) => prospect.linkedin_url],
  ["Mobile", (prospect) => prospect.mobile_number],
  ["Seniority", (prospect) => prospect.seniority],
  ["Department", (prospect) => prospect.department],
  ["City", (prospect) => prospect.city],
  ["State", (prospect) => prospect.state],
  ["Country", (prospect) => prospect.country],
];

function fieldMap(prospect: Prospect) {
  const values = new Map<string, string>();
  for (const [field, read] of namedFields) {
    const value = String(read(prospect) ?? "").trim();
    if (value) values.set(field, value);
  }
  for (const [field, value] of Object.entries(parseAllData(prospect.all_data))) {
    const text = String(value ?? "").trim();
    // A named column wins: all_data carries the raw import header alongside it.
    if (text && !values.has(field)) values.set(field, text);
  }
  return values;
}

/** Case- and space-insensitive: "acme corp" and "Acme Corp " are not a conflict. */
const comparable = (value: string) => value.toLowerCase().replace(/\s+/g, " ").trim();

/**
 * Every field either side holds, in a stable order, each labelled with how the
 * two records relate on it. The order is the named fields first (so Full name
 * and Work email stay at the top where they are read) and then whatever the
 * import brought with it.
 */
export function compareProspects(left: Prospect, right: Prospect): FieldComparison[] {
  const leftValues = fieldMap(left);
  const rightValues = fieldMap(right);
  const order = [...namedFields.map(([field]) => field), ...leftValues.keys(), ...rightValues.keys()];
  const seen = new Set<string>();
  const rows: FieldComparison[] = [];
  for (const field of order) {
    if (seen.has(field)) continue;
    seen.add(field);
    const leftValue = leftValues.get(field) ?? "";
    const rightValue = rightValues.get(field) ?? "";
    if (!leftValue && !rightValue) continue;
    const state = leftValue && rightValue
      ? (comparable(leftValue) === comparable(rightValue) ? "same" : "differs")
      : leftValue ? "only-left" : "only-right";
    rows.push({ field, left: leftValue, right: rightValue, state });
  }
  return rows;
}

/** A conflict is a real disagreement; a field only one side holds is not one. */
export function conflictCount(rows: FieldComparison[]) {
  return rows.filter((row) => row.state === "differs").length;
}

export function matchCount(rows: FieldComparison[]) {
  return rows.filter((row) => row.state === "same").length;
}

/**
 * QUALITY-05: what the button keeps, said in terms of the person.
 *
 * "Keep left" is a fact about the layout. This is a fact about the record, so
 * the label stays correct however the two candidates are ordered, and the
 * confirmation can repeat it back without the user re-checking which side they
 * clicked.
 */
export function describeProspect(prospect: Prospect) {
  const name = String(prospect.full_name ?? "").trim();
  const company = String(prospect.company_name ?? "").trim();
  // `||`, not `??`: an absent email is an empty string here, not null.
  const email = String(prospect.work_email || prospect.personal_email || "").trim();
  if (name && company) return `${name} at ${company}`;
  if (name && email) return `${name} (${email})`;
  if (name) return name;
  if (email) return email;
  return "this unnamed record";
}

/**
 * The sentence the confirmation asks. Merging is not reversible from the UI, so
 * it has to name both records and say which one stops existing.
 */
export function describeMerge(keep: Prospect, remove: Prospect) {
  return `${describeProspect(remove)} is merged into ${describeProspect(keep)}. Lists and client links move across; the merged record is removed.`;
}
