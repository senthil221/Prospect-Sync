import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");
const migration = () => read("../supabase/migrations/20260902000210_match_keyword_tags_regardless_of_case.sql");

// Reported as "is keywords case sensitive?" It was, in one scope out of three.
// Typing "Cloud Computing" instead of "cloud computing" returned 1,951 companies
// where the lowercase spelling returned 19,325 -- the keywords scope is an exact
// array overlap and tags are stored lowercase, so the capitalised form matched
// nothing at all while name and description carried on matching via ILIKE.
test("a tag match is built from both spellings", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.keyword_tag_variants_v1/i);
  // Both forms, de-duplicated, so one GIN scan still serves it.
  assert.match(statements, /select unnest\(p_values\) as value\s*\n\s*union\s*\n\s*select lower\(unnest\(p_values\)\)/);
  // Immutable, or it cannot be folded into a generated predicate.
  assert.match(statements, /language sql\s*\n\s*immutable\s*\n\s*strict/);
});

// Lowercasing the search values alone would have fixed keywords and broken
// technologies: 9,877 of 10,017 distinct technology values carry uppercase
// ("WordPress", "Google Analytics"), where 2,356,733 of 2,357,195 keyword tags
// are lowercase. Searching both forms is the only direction that cannot lose.
test("the fix widens and never narrows", async () => {
  const statements = statementsOnly(await migration());

  // Every array-overlap test goes through the helper.
  const overlaps = statements.match(/&& %L::text\[\]', public\.keyword_tag_variants_v1\(raw_values\)\)/g) ?? [];
  assert.ok(overlaps.length >= 4, `every tag overlap must use the helper, found ${overlaps.length}`);
  // And none is left comparing the raw list directly.
  assert.doesNotMatch(statements, /c\.keywords && %L::text\[\]', raw_values\)/,
    "a raw-values overlap is the case-sensitive comparison this migration removes");
  assert.doesNotMatch(statements, /c\.technologies && %L::text\[\]', raw_values\)/);
});

// The prefilter is ANDed onto the predicate. If the predicate starts matching
// more rows and the prefilter does not, those rows are dropped again.
test("the prefilter widens in step with the predicate", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.company_prefilter_sql/i);
  const prefilter = statements.slice(statements.indexOf("create or replace function public.company_prefilter_sql"));
  assert.match(prefilter, /c\.keywords && %L::text\[\]',\s*\n?\s*public\.keyword_tag_variants_v1\(raw_values\)\)/);
});

// The probe shape carries its own copy of the keyword branch.
test("the index probe matches tags case-insensitively too", async () => {
  const statements = statementsOnly(await migration());

  const probe = statements.slice(statements.indexOf("create or replace function public.company_substring_probe_sql_v1"));
  assert.match(probe, /public\.keyword_tag_variants_v1\(p_keyword_values\)/);
});

test("the helper is locked to service_role like its callers", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /revoke execute on function public\.keyword_tag_variants_v1\(text\[\]\) from public, anon, authenticated;/);
  assert.match(statements, /grant execute on function public\.keyword_tag_variants_v1\(text\[\]\) to service_role;/);
});
