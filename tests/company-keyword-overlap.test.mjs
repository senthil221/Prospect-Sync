import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const sqlOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");
const migration = () => read("../supabase/migrations/20260917040000_company_keyword_search_matches_tags_by_overlap.sql");

// Company keyword search matches the tag array by overlap instead of building a
// string per company and matching a substring in it.
//
// Measured on an idle production database, company side:
//   name + short_description ilike (trigram)      746 ms
//   array_to_string(keywords) ilike (no index)  2,983 ms
//   keywords && keyword_tag_variants_v1            33 ms
//
// End to end through search_prospect_workspace_v12:
//   all three scopes   8,371 ms -> 2,487 ms
//   keywords only      4,368 ms ->   321 ms, and exact rather than capped
test("the keywords scope is an overlap test, and the text half keeps name and description", async () => {
  const sql = sqlOnly(await migration());

  // The text expression must not concatenate the tag array - that is the cost
  // being removed, and putting it back would undo the whole migration.
  assert.match(sql, /create or replace function public\.company_keyword_text_expr_sql_v1/);
  // Bounded by the function's own dollar-quote terminator, not by a comment:
  // sqlOnly has already stripped the comments, so a comment marker would not be
  // found and the slice would run on into the compiler splice below.
  const helperStart = sql.indexOf("create or replace function public.company_keyword_text_expr_sql_v1");
  const helper = sql.slice(helperStart, sql.indexOf("$FN$;", helperStart));
  assert.match(helper, /v_scopes \? 'name'/);
  assert.match(helper, /v_scopes \? 'description'/);
  // It may join its own SQL fragments with array_to_string; what it must never
  // do is concatenate the KEYWORDS COLUMN into the text, which is the 2,983 ms
  // this migration removes.
  assert.doesNotMatch(helper, /array_to_string\(%I\.keywords/,
    "the text half must not join the keyword column; overlap covers keywords");
  assert.doesNotMatch(helper, /\? 'keywords'/,
    "the text half must not have a keywords scope branch at all");

  // The overlap is appended to the text match, not substituted for it, so a
  // company is still found by name or description as well as by tag.
  assert.match(sql, /or co\.keywords && %L::text\[\]/);
  assert.match(sql, /public\.keyword_tag_variants_v1\(raw_values\)/);

  // Only the substring path changes. Boolean search and empty/not-empty still
  // read the full concatenation, because a Boolean query is a text query and
  // "has no keywords" has to be able to see the keywords.
  assert.match(sql, /company_contains_expr/);
  assert.ok(sql.includes("company_expr text;\n  company_contains_expr text;"),
    "the new local must be declared in the same rewrite that uses it");
});

// The pair has to move together or the grid contradicts its own bulk actions.
test("the compiler and the row matcher are changed together and proved equal", async () => {
  const sql = sqlOnly(await migration());

  // The matcher's candidate drops the tag text, exactly as the compiler's does.
  assert.match(sql, /prospect_index_matches_v1 no longer contains the company keyword candidate/);
  // And gains an arm that puts the overlap back for contains/not_contains.
  assert.match(sql, /prospect_index_matches_v1 no longer contains the tag-array arm this migration extends/);
  assert.match(sql, /in \(''contains'', ''not_contains''\)/);

  // That arm must use the scalar candidate, not candidate_parts: for this field
  // candidate_parts is null, so a parts-based test silently matches nothing.
  // Caught by the battery at 86 vs 68 before it was fixed.
  assert.match(sql, /candidate\.candidate_value ilike ''%'' \|\| selected\.value \|\| ''%''/);
  assert.doesNotMatch(sql, /candidate\.candidate_parts is not null/);

  // Proved rather than asserted, across every scope combination and including
  // not_contains, which is the arm most easily got backwards.
  assert.match(sql, /compiler matched %, row matcher matched %/);
  assert.match(sql, /not_contains: compiler matched %/);
  assert.match(sql, /limit 3000/);

  // And a tag that appears in neither the name nor the description must still
  // be found - otherwise the overlap arm could be dead and the battery would
  // happily agree that both halves return nothing.
  assert.match(sql, /but the overlap arm did not match it/);
});
