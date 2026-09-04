import { normalizeDomain, normalizeLinkedin } from "../db/normalize.ts";

// Shared parsing for every place the user pastes a list of values: filter value
// pickers, the Company DB bulk domain box, and the per-client blocklist. One
// implementation means a pasted URL matches a stored domain the same way
// everywhere, instead of each surface inventing its own trimming.

export type BulkFieldKind = "domain" | "email" | "linkedin" | "text";

// Fields whose stored form differs from what people paste. A domain column holds
// "acme.com" but a spreadsheet holds "https://www.acme.com/careers"; normalizing
// on the way in is the difference between 800 matches and none.
const fieldKinds: Record<string, BulkFieldKind> = {
  __website: "domain",
  __company_domain: "domain",
  __email: "email",
  __work_email: "email",
  __personal_email: "email",
  __linkedin: "linkedin",
};

export function bulkFieldKind(field?: string): BulkFieldKind {
  return (field && fieldKinds[field]) || "text";
}

// Split on the separators a pasted list realistically uses. Tabs and newlines
// cover a spreadsheet column; commas, semicolons and pipes cover a flat list.
// Quotes and stray bullets are stripped so a copied CSV cell still lands clean.
export function splitPastedValues(raw: string) {
  return raw
    .split(/[\r\n\t,;|]+/)
    .map((value) => value.trim().replace(/^["'`•\-\s]+|["'`\s]+$/g, ""))
    .filter(Boolean);
}

export function normalizeBulkValue(value: string, kind: BulkFieldKind) {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (kind === "domain") return normalizeDomain(trimmed);
  if (kind === "email") return trimmed.toLowerCase();
  if (kind === "linkedin") return normalizeLinkedin(trimmed);
  return trimmed;
}

// A pasted email must look like one, and a pasted domain must have a dot -
// otherwise a stray header row ("Website") silently becomes a filter value that
// matches nothing and quietly shrinks the result set.
export function isValidBulkValue(value: string, kind: BulkFieldKind) {
  if (!value) return false;
  if (kind === "email") return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  if (kind === "domain") return /^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(value);
  if (kind === "linkedin") return value.includes("linkedin.com/");
  return true;
}

export type BulkMergeResult = {
  values: string[];
  added: number;
  duplicates: number;
  invalid: string[];
};

export const MAX_BLOCKLIST_PASTE_VALUES = 5_000;
export const BLOCKLIST_REQUEST_VALUES = 200;

export type BlocklistPartition = {
  domains: string[];
  emails: string[];
  duplicates: number;
  invalid: string[];
  invalidCount: number;
  submitted: number;
};

// Keep processing data separate from the short diagnostic sample shown to the
// user. The old route reused mergeBulkValues().invalid as the domain payload;
// because that sample intentionally stops at ten, a paste of 1,875 domains sent
// only ten to Postgres.
export function partitionBlocklistValues(raw: string): BlocklistPartition {
  const candidates = splitPastedValues(raw);
  const domains: string[] = [];
  const emails: string[] = [];
  const invalid: string[] = [];
  const seen = new Set<string>();
  let duplicates = 0;
  let invalidCount = 0;

  for (const candidate of candidates) {
    const email = normalizeBulkValue(candidate, "email");
    const domain = normalizeBulkValue(candidate, "domain");
    const kind = isValidBulkValue(email, "email") ? "email" : isValidBulkValue(domain, "domain") ? "domain" : null;
    const value = kind === "email" ? email : domain;
    if (!kind) {
      invalidCount += 1;
      if (invalid.length < 10) invalid.push(candidate);
      continue;
    }
    const key = `${kind}:${value.toLocaleLowerCase()}`;
    if (seen.has(key)) { duplicates += 1; continue; }
    seen.add(key);
    if (kind === "email") emails.push(value); else domains.push(value);
  }

  return { domains, emails, duplicates, invalid, invalidCount, submitted: candidates.length };
}

// Merge pasted text into an existing value list, reporting what happened so the
// UI can say "412 added · 38 duplicates · 6 unrecognised" instead of silently
// dropping rows.
export function mergeBulkValues(existing: string[], raw: string, kind: BulkFieldKind): BulkMergeResult {
  const seen = new Set(existing.map((value) => value.toLocaleLowerCase()));
  const values = [...existing];
  const invalid: string[] = [];
  let added = 0;
  let duplicates = 0;

  for (const candidate of splitPastedValues(raw)) {
    const normalized = normalizeBulkValue(candidate, kind);
    if (!isValidBulkValue(normalized, kind)) {
      if (invalid.length < 10) invalid.push(candidate);
      continue;
    }
    const key = normalized.toLocaleLowerCase();
    if (seen.has(key)) { duplicates += 1; continue; }
    seen.add(key);
    values.push(normalized);
    added += 1;
  }

  return { values, added, duplicates, invalid };
}

// One summary line for a merge, phrased so the counts that matter come first.
export function describeBulkMerge(result: BulkMergeResult, noun = "value") {
  if (!result.added && !result.duplicates && !result.invalid.length) return "Nothing to add.";
  const parts = [`${result.added.toLocaleString("en-IN")} ${noun}${result.added === 1 ? "" : "s"} added`];
  if (result.duplicates) parts.push(`${result.duplicates.toLocaleString("en-IN")} already listed`);
  if (result.invalid.length) parts.push(`${result.invalid.length} skipped (${result.invalid.slice(0, 3).join(", ")}${result.invalid.length > 3 ? "…" : ""})`);
  return `${parts.join(" · ")}.`;
}

// Pasting hundreds of domains means "these exact companies", not "any company
// whose domain contains this string" - and an equality test is indexable where a
// chain of ILIKE '%…%' is not. Above this size the picker switches operators.
export const exactMatchThreshold = 25;

export function matchesExactly(valueCount: number) {
  return valueCount > exactMatchThreshold;
}

// Fields where a longer list never means "these exact strings", so the threshold
// above does not apply.
//
// The switch exists for pasted IDENTIFIERS - domains, emails, exact company
// names - where substring matching invents matches (acme.com inside
// notacme.com.au) and equality is the indexable test. Company keywords is not
// that: it is a keyword search, and "IT services" is a phrase to look for
// INSIDE a name or a description, never a whole value to equal.
//
// Applying it there silently broke the description scope. A description is a
// paragraph, so `short_description = 'IT services'` is true for 13 companies out
// of 419,214 - the checkbox became a no-op above 25 keywords. Reported as "only
// 3 prospects got added"; measured on a real 51-keyword IT-services list, exact
// mode found 27,480 companies / 54,423 prospects where contains finds 38,448 /
// 73,094. A third of the answer, silently missing.
//
// Precision is not lost by exempting it: the keywords scope matches tags with
// `c.keywords && ARRAY[...]`, which is already true exact matching, and it is
// the scope where exactness is meaningful.
const keywordSearchFields = new Set(["__company_keywords"]);

export function switchesToExactMatch(field: string, valueCount: number) {
  return !keywordSearchFields.has(field) && matchesExactly(valueCount);
}

// The operator switch changes which rows come back, so the count on screen moves
// when a list crosses the threshold. Say which mode is in force instead of
// letting that look like a bug. Field-aware, so it cannot announce a switch that
// does not happen.
export function describeMatchMode(valueCount: number, noun = "value", field = "") {
  if (!valueCount) return "";
  return switchesToExactMatch(field, valueCount)
    ? `Matching these ${valueCount.toLocaleString("en-IN")} ${noun}s exactly.`
    : `Matching any ${noun} that contains what you entered.`;
}
