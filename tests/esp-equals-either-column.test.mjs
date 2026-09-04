import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// 20260902000280: __esp_type and __title_seniority compare a concatenation of
// two columns. That is right for a substring test and nonsense for an equality
// test, so equality now looks at the columns themselves.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000280_esp_equals_matches_either_column.sql");
const executable = (sql) => sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");

test("equality looks at the columns, substring keeps the concatenation", async () => {
  const sql = executable(await migration());

  // The two virtual fields, and only those two, get per-column matching.
  assert.match(sql, /when '__esp_type' then array\['pi\.esp', 'pi\.email_provider_type'\]/);
  assert.match(sql, /when '__title_seniority' then array\['pi\.title', 'pi\.seniority'\]/);
  assert.match(sql, /elsif match_exprs is not null then/);

  // not_equals is built from the same list, so it stays the exact complement of
  // equals rather than a lookalike written separately. It keeps coalesce, since
  // not(NULL = any(...)) would drop a row whose column is null.
  assert.match(sql, /lower\(coalesce\(%s, %L\)\) = any \(%L::text\[\]\)/);

  // contains / not_contains / empty / not_empty are untouched: narrowing a
  // substring test to per-column would lose matches that span the join.
  assert.match(sql, /format\('btrim\(%s\) = %L', candidate_expr, ''\)/);
});

test("the row matcher moves identically, because bulk actions use it", async () => {
  const sql = executable(await migration());

  // Same two fields, same decision, in prospect_index_matches_v1.
  assert.match(sql, /when '__esp_type' then array\[coalesce\(\(p_row\)\.esp, ''\), coalesce\(\(p_row\)\.email_provider_type, ''\)\]/);
  assert.match(sql, /when '__title_seniority' then array\[coalesce\(\(p_row\)\.title, ''\), coalesce\(\(p_row\)\.seniority, ''\)\]/);
  assert.match(sql, /end as candidate_parts/);

  // Both equality branches consult the parts when there are parts to consult.
  assert.equal(sql.match(/case when candidate\.candidate_parts is null/g)?.length, 2);
});

test("the migration proves the change before it commits", async () => {
  const sql = await migration();

  // Fifteen shapes, both implementations, on an ordered sample - unordered
  // LIMIT hands the two sides different rows, which is how the previous
  // migration's assertion reported fourteen phantom mismatches.
  assert.match(sql, /public\.prospect_index_matches_v1\(pi, %L, %L::jsonb\)/);
  assert.match(sql, /order by id limit 20000/);
  assert.doesNotMatch(sql, /from public\.prospect_index limit/);

  // equals + not_equals must partition the sample exactly.
  assert.match(sql, /expected 20000/);

  // And the shape is pinned, so nobody can put the concatenation back on the
  // equality path or take it off the substring path.
  assert.match(sql, /esp_type equals still compares against the concatenation/);
  assert.match(sql, /esp_type contains lost the concatenation it needs for spanning matches/);
  assert.match(sql, /array_append\(v_problems/);
  assert.doesNotMatch(sql, /v_problems := v_problems \|\| '/);
});

test("the migration records what changed and why nobody was relying on it", async () => {
  const sql = await migration();

  // The evidence that this is a fix and not a preference: the joined value was
  // undiscoverable, and equality against it returned nothing.
  assert.match(sql, /649,288 of 681,085/);
  assert.match(sql, /prospect_filter_values_v3 returns/);
  assert.match(sql, /12,815/);
  assert.match(sql, /40,000 - 12,815 = 27,185/);

  // concat_ws is STABLE, so the old predicate could never have been indexed -
  // which is why this is a performance fix as well as a correctness one.
  assert.match(sql, /concat_ws is STABLE/);
  for (const index of [
    "idx_prospect_index_esp_lower\n  on public.prospect_index (lower(esp))",
    "idx_prospect_index_email_provider_type_lower\n  on public.prospect_index (lower(email_provider_type))",
    "idx_prospect_index_seniority_lower\n  on public.prospect_index (lower(seniority))",
  ]) {
    assert.ok(sql.includes(index), `missing index: ${index.split("\n")[0]}`);
  }
});
