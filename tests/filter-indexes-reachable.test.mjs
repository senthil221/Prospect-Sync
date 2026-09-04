import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// 20260902000270: coalesce(col, '') was disqualifying every expression and
// trigram index on both filter tables. The wrapper comes off the positive
// operators, stays on the negative ones, and five columns that had no index at
// all get one.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000270_stop_hiding_the_indexes_behind_coalesce.sql");
const executable = (sql) => sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");

test("positive operators compare the raw column, negative ones keep the wrapper", async () => {
  const sql = executable(await migration());

  // Both compilers keep an un-wrapped copy alongside the coalesced one.
  assert.match(sql, /raw_cols := match_cols;/);
  assert.match(sql, /raw_expr := candidate_expr;/);

  // equals and contains use it, which is what lets an index match.
  assert.match(sql, /format\('lower\(%s\) = any \(%L::text\[\]\)', col, lowered\) from unnest\(raw_cols\) col/);
  assert.match(sql, /format\('%s ilike %L', col, '%' \|\| value_text \|\| '%'\) from unnest\(raw_cols\) col/);
  assert.match(sql, /format\('lower\(%s\) = any \(%L::text\[\]\)', raw_expr, lowered\)/);

  // The negative operators branch on the operator rather than taking raw_expr
  // unconditionally: not(NULL) excludes a null row where not('' = ...) includes
  // it, and the row functions give the second answer.
  assert.match(sql, /case when operator_key = 'not_contains' then candidate_expr else raw_expr end/);
  assert.match(sql, /format\('not \(lower\(%s\) = any \(%L::text\[\]\)\)', candidate_expr, lowered\)/);

  // empty / not_empty are untouched - they are the whole reason the wrapper
  // exists, and they compare against '' on purpose.
  assert.match(sql, /format\('btrim\(%s\) = %L', candidate_expr, ''\)/);
  assert.match(sql, /format\('btrim\(%s\) <> %L', candidate_expr, ''\)/);
});

test("the five columns with no index at all get one", async () => {
  const sql = executable(await migration());
  for (const index of [
    "idx_prospect_index_department_lower\n  on public.prospect_index (lower(department))",
    "idx_prospect_index_title_department_lower\n  on public.prospect_index (lower(title_department))",
    "idx_prospect_index_title_sub_department_lower\n  on public.prospect_index (lower(title_sub_department))",
    "idx_prospect_index_title_seniority_lower\n  on public.prospect_index (lower(title_seniority))",
    "idx_companies_industry_lower\n  on public.companies (lower(industry))",
  ]) {
    assert.ok(sql.includes(index), `missing index: ${index.split("\n")[0]}`);
  }

  // lower(state) and lower(city) were measured and deliberately NOT added -
  // through the index, state was slower than the sequential scan it replaced.
  assert.doesNotMatch(sql, /on public\.companies \(lower\(state\)\)/);
  assert.doesNotMatch(sql, /on public\.companies \(lower\(city\)\)/);
});

test("the compiled predicate is asserted against the row function it must match", async () => {
  const sql = await migration();

  // The real hazard: the bulk paths still use the row matchers, so a compiler
  // that drifts means the grid shows one set and a bulk delete acts on another.
  assert.match(sql, /public\.prospect_index_matches_v1\(pi, %L, %L::jsonb\)/);
  assert.match(sql, /public\.company_matches_filters_v1\(c, %L, %L::jsonb\)/);
  assert.match(sql, /compiled %s <> row function %s/);

  // Both sides must read the SAME sample. LIMIT without ORDER BY does not
  // guarantee that, and the first run of this assertion reported fourteen
  // mismatches - including empty/not_empty, which the migration never touches -
  // purely because the two sides got different 20,000-row samples.
  assert.doesNotMatch(sql, /from public\.prospect_index limit/);
  assert.doesNotMatch(sql, /from public\.companies limit/);
  assert.match(sql, /from public\.prospect_index order by id limit 20000/);
  assert.match(sql, /from public\.companies order by id limit 20000/);

  // Counts alone would pass on the luck of a sample, so the shape is asserted too.
  assert.match(sql, /equals still wraps its column in coalesce/);
  assert.match(sql, /not_equals lost the coalesce it needs for null rows/);
  assert.match(sql, /not_contains lost the coalesce it needs for null rows/);
  assert.match(sql, /array_append\(v_problems/);
  assert.doesNotMatch(sql, /v_problems := v_problems \|\| '/);
});

test("the migration records what it fixed and what it did not", async () => {
  const sql = await migration();

  // The indexes that existed, were maintained on every write, and were
  // unreachable by the filters they were built for.
  assert.match(sql, /idx_prospect_index_title_lower/);
  assert.match(sql, /idx_companies_location/);

  // Measured, per shape, rather than asserted in prose.
  assert.match(sql, /2,014x/);
  assert.match(sql, /541x/);
  assert.match(sql, /53 filter shapes/);

  // And the honest limit: this does not fix the reported pivot timeout, because
  // 56% of a table is a sequential scan whatever indexes exist.
  assert.match(sql, /8\.1 s -> 7\.6 s/);
  assert.match(sql, /232,888 of 418,456/);
});
