import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Release 1B, items 1-3: the People listing stops early instead of building
// every match first, sorts through a static allow-listed branch, and says which
// kind of number each total is.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000060_bound_the_people_listing.sql");
// The header explains the old shape by naming it, so "is it gone" has to be
// asked of the executable SQL rather than of the whole file.
const executable = (sql) => sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");

test("the page and the count are independent scans, each with its own limit", async () => {
  const sql = await migration();

  // The whole point: no materialised match set that both then read.
  assert.doesNotMatch(executable(sql), /matched as materialized/);
  assert.doesNotMatch(executable(sql), /select count\(\*\) from matched/);

  // The page scan carries the page's LIMIT/OFFSET...
  assert.match(sql, /order by %7\$s\s*\n\s*limit %8\$s offset %9\$s/);
  // ...and the count is a separate scan that stops at the cap.
  assert.match(sql, /counted as \(\s*\n\s*select count\(\*\)::bigint as matched_rows from \(/);
  assert.match(sql, /limit %s\s*\n\s*\) capped/);
  assert.match(sql, /v_count_cap constant integer := 50001;/);
});

test("sorting picks a static branch instead of building an ORDER BY from input", async () => {
  const sql = await migration();

  // p_sort and p_direction choose a branch; neither is interpolated as text.
  assert.match(sql, /case coalesce\(p_sort, 'created_at'\)/);
  assert.match(sql, /v_sort_dir := case when lower\(coalesce\(p_direction, 'desc'\)\) = 'asc' then 'asc' else 'desc' end;/);
  for (const [branch, expression] of [
    ["name", "lower(pi.full_name)"],
    ["company", "lower(pi.company_name)"],
    ["title", "lower(pi.title)"],
    ["last_contacted", "pi.last_contacted_at"],
  ]) {
    assert.ok(sql.includes(`when '${branch}' then`), `${branch} needs its own branch`);
    assert.ok(sql.includes(`v_sort_expr := '${expression}'`), `${branch} must sort on ${expression}`);
  }
  // Unknown sorts fall to created_at rather than reaching the SQL.
  assert.match(sql, /else\s*\n\s*v_sort_expr := 'pi\.created_at';/);

  // One tie-breaker, always id, so a page is a total order and a keyset cursor
  // has something to carry.
  assert.match(sql, /v_order := format\('%s %s%s, pi\.id'/);

  // last_contacted_at's null ordering has to match the index in both
  // directions, or the sort cannot be index-served.
  assert.match(sql, /case when v_sort_dir = 'asc' then ' nulls first' else ' nulls last' end/);
});

test("what 1B built to bound the total is still in this migration", async () => {
  const sql = await migration();

  // This file is history now: 20260902000260 took the cap off after measuring
  // an exact People count at 0.18-1.25 s. What 1B shipped is still asserted
  // here, because the file is what it is - the CURRENT behaviour is asserted in
  // exact-people-counts.test.mjs, and the two together are the record of the
  // change rather than a rewrite that pretends the cap never existed.
  assert.match(sql, /RETURNS TABLE\(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean\)/);
  assert.match(sql, /least\(counted\.matched_rows, %s\)/);
  assert.match(sql, /counted\.matched_rows > %s/);
  assert.match(sql, /pg_class\.reltuples::bigint/);
});

test("the rewrite keeps its grants and its evidence", async () => {
  const sql = await migration();

  // DROP takes grants with it, so they have to be restored in the same file --
  // which is also what the SECURITY DEFINER check in CI requires.
  assert.match(sql, /DROP FUNCTION IF EXISTS public\.search_prospect_workspace_v12/);
  assert.match(sql, /revoke execute on function public\.search_prospect_workspace_v12\(text, jsonb, text, text, integer, integer, text, jsonb, boolean\) from public, anon, authenticated;/);
  assert.match(sql, /grant execute on function public\.search_prospect_workspace_v12\(text, jsonb, text, text, integer, integer, text, jsonb, boolean\) to service_role;/);

  // Two things the plan expected to matter were measured and did not, so the
  // reasons are recorded here rather than the work being done silently.
  assert.match(sql, /constant-folds/);
  assert.match(sql, /Incremental Sort/);
  assert.match(sql, /Not built\./);
  assert.match(sql, /p50 262 B/);
});
