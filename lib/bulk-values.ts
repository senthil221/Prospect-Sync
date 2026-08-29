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
