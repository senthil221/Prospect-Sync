import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Release 2, item 5: section 6.4's "migrate ... bulk resolvers" half. The
// listings moved to the complete compiler in 20260902000000/20260902000020; the
// bulk resolvers, which read the whole match set rather than a page of it, did
// not.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000150_bulk_resolvers_use_the_compiler.sql");

test("each resolver reaches the compiler but keeps its fallback", async () => {
  const sql = await migration();

  // coalesce(<compiler>, <row function>) - the shape the listings already use.
  // When the compiler can express the filters they are used; when it cannot it
  // returns null and the row function still answers, so a coverage gap costs
  // speed and never rows.
  assert.match(sql, /coalesce\(%s\(p_search, coalesce\(p_filters, \\'\[\]\\'::jsonb\)\), format\(%L,/);
  assert.match(sql, /still never reaches the compiler/);
  assert.match(sql, /lost its row-function fallback/);

  // Both entities.
  assert.match(sql, /public\.prospect_filter_sql_v1/);
  assert.match(sql, /public\.company_filter_sql_v2/);
});

test("a splice that cannot find its anchor fails the migration", async () => {
  const sql = await migration();

  // The lesson of 20260826050000 and of the guard 20260902000110 nearly shipped
  // past: a silent skip is how a predicate quietly stops being applied.
  assert.match(sql, /Could not find a known call site in/);
  assert.match(sql, /The deployed body changed shape/);
  // Both halves of a wrap, or neither: an opening without its closing paren
  // would not compile.
  assert.match(sql, /expected exactly one closing fragment for its opening/);
  // And a stale target list must not pass silently either.
  assert.match(sql, /the target list is stale/);
});

test("the resolver that is not migrated says why", async () => {
  const sql = await migration();

  // resolve_company_action_selection_v1 calls the row function from static SQL,
  // and the compiler returns SQL text, so it needs a rewrite rather than a
  // substitution. Recorded so the remaining caller is a decision.
  assert.match(sql, /resolve_company_action_selection_v1, is deliberately left alone/);
  assert.match(sql, /STATIC SQL/);
  assert.doesNotMatch(sql, /'resolve_company_action_selection_v1'\s*\n\s*\]/);
});

test("the prefilters and row functions are explicitly not retired", async () => {
  const sql = await migration();

  // Section 6.4 gates retirement on a caller inventory proving no active
  // dependency. After this migration there are still live callers, so they stay.
  assert.match(sql, /THE PREFILTERS AND ROW FUNCTIONS ARE NOT RETIRED/);
  assert.match(sql, /company_scope_ids_v2, client_company_workspace_v2, people_scope_company_ids_v1/);
  assert.doesNotMatch(sql, /drop function[^;]*prospect_index_matches_v1/i);
  assert.doesNotMatch(sql, /drop function[^;]*company_matches_filters_v1/i);
  assert.doesNotMatch(sql, /drop function[^;]*prefilter_sql/i);
});

test("the measured win is recorded, including where it is small", async () => {
  const sql = await migration();

  // The gain depends entirely on how many candidates survive the pre-filter, so
  // quoting only the large number would misrepresent it.
  assert.match(sql, /66,346 ms/);
  assert.match(sql, /411 ms/);
  assert.match(sql, /784 ms/);
  assert.match(sql, /574 ms/);
  assert.match(sql, /depends on how many rows survive/i);
});
