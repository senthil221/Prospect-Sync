import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const sqlOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");

// A People search filtered by the company profile stops counting at 50,000.
//
// Measured on production 2026-09-17: three /api/prospects requests died at
// 10,048 / 10,087 / 10,171 ms against the function's own statement_timeout=10s.
// With p_with_total the query scans the whole table TWICE - once for `counted`,
// once for `ordered` - and a company-profile predicate can use no index, so the
// plan is 683,784 prospect_index rows feeding a Memoize'd probe of ~152,000
// distinct companies. Bounding the count took the same call from 14.1s to 7.2s.
test("a company-profile filter bounds its count; every other filter still counts exactly", async () => {
  const migration = await read("../supabase/migrations/20260917030000_a_company_filter_stops_counting_at_the_cap.sql");
  const sql = sqlOnly(migration);

  // The bound, and the flag that stops 50,000 being read as exact.
  assert.match(sql, /limit 50001/);
  assert.match(sql, /least\(\(select counted\.matched_rows from counted\), 50000\)/);
  assert.match(sql, /\(\(select counted\.matched_rows from counted\) > 50000\)/);

  // Only for the filters that force the per-row company lookup. Employee count
  // and company location read prospect_index and must keep an exact count.
  assert.match(sql, /elsif public\.prospect_filters_need_company_lookup_v1\(p_filters\) then/);
  for (const field of ["__company_industry", "__company_keywords", "__company_description",
                       "__company_technologies", "__company_founded_year", "__company_total_funding"]) {
    assert.ok(sql.includes(`'${field}'`), `${field} must be classified as needing the company lookup`);
  }
  assert.doesNotMatch(sql.slice(sql.indexOf("prospect_filters_need_company_lookup_v1"), sql.indexOf("$$;")), /__employee_count|__company_location/);

  // The unbounded branch survives for everything else - 20260911140000 removed
  // the old blanket cap deliberately and this must not put it back.
  // Three occurrences, not two: the anchor being searched for, plus the two
  // branches that replace it - the bounded one and the exact one.
  assert.equal((sql.match(/select count\(\*\)::bigint as matched_rows/g) ?? []).length, 3,
    "the anchor plus both the bounded and the exact count branches must be present");
  assert.ok(sql.indexOf("limit 50001") < sql.lastIndexOf("select count(*)::bigint as matched_rows"),
    "the exact-count branch must still follow the bounded one");

  // The splice refuses rather than patching blindly.
  assert.match(sql, /search_prospect_workspace_v12 no longer contains the unbounded count branch/);
  assert.match(sql, /the bounded-count replacement did not take/);

  // Proved on real rows: the heavy filter caps, the ordinary one does not.
  assert.match(sql, /a capped count returned %, which is above the cap/);
  assert.match(sql, /the count stopped at the cap without setting total_capped/);
  assert.match(sql, /an ordinary filter must not be capped/);
});

// A cap nobody can see is a lie, not an optimisation.
test("the capped total reaches the grid as 50,000+ rather than as an exact number", async () => {
  const [route, workspace, table] = await Promise.all([
    read("../app/api/prospects/route.ts"),
    read("../app/components/ProspectsWorkspace.tsx"),
    read("../app/components/ProspectTable.tsx"),
  ]);

  // API -> controller -> grid, unbroken.
  assert.match(route, /totalCapped: summary\.total_capped === true/);
  assert.match(workspace, /capped: data\.totalCapped === true/);
  assert.match(workspace, /totalCapped=\{controller\.totalCapped\}/);
  // And the grid prints the "+" and can still be asked for the real number.
  assert.match(table, /totalCapped \? "\+" : ""/);
  assert.match(table, /exactTotal/);
});
