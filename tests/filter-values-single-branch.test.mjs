import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// pg_stat_statements put prospect_filter_values_v3 at the top of real user
// traffic: 17 calls, 39,406 ms mean. It is the filter type-ahead, so every filter
// interaction paid ~40s for 50 dropdown rows.
//
// The cost was structural: `select ps.*` over 674,804 rows, eight UNION ALL
// branches each gated by a run-time `p_field = '...'` test the planner cannot
// prune, and p_search applied only after every row's value had been computed.

const migration = () =>
  readFile(new URL("../supabase/migrations/20260901000040_filter_values_scan_one_column.sql", import.meta.url), "utf8");

test("filter values build one branch instead of unioning every field", async () => {
  const sql = await migration();

  assert.match(sql, /create or replace function public\.prospect_filter_values_v3/i);
  // Dynamic SQL is what makes the branch selection happen before planning.
  assert.match(sql, /language plpgsql/i);
  assert.match(sql, /return query execute v_sql;/);

  // The three costs that made v3 slow must all be gone.
  assert.doesNotMatch(sql, /select ps\.\*/, "must not carry all 52 columns");
  assert.doesNotMatch(sql, /union all/i, "must not union every field's branch");

  // The search predicate belongs in the scan, so a trigram index can serve it.
  assert.match(sql, /v_conditions := v_conditions \|\| format\('\(%s\) ilike %L'/);
});

test("the rewrite preserves v3's result semantics", async () => {
  const sql = await migration();

  // A prospect with a repeated keyword must still count once -- count(*) would
  // silently inflate array-valued fields.
  assert.match(sql, /count\(distinct source\.prospect_id\)/);
  // Display form, grouping, blank handling and ordering are all unchanged.
  assert.match(sql, /min\(source\.candidate\) as value/);
  assert.match(sql, /group by lower\(source\.candidate\)/);
  assert.match(sql, /where source\.candidate <> ''/);
  assert.match(sql, /order by grouped\.match_count desc, lower\(grouped\.value\)/);

  // v3 returned nothing for __employee_count and for unknown fields; that stays
  // an explicit early return rather than an accident of the query shape.
  assert.match(sql, /if v_value_expr is null then return; end if;/);
});

test("the SECURITY DEFINER function revokes EXECUTE in the same file", async () => {
  const sql = await migration();
  assert.match(sql, /security definer/i);
  assert.match(
    sql,
    /revoke execute on function public\.prospect_filter_values_v3\(text, text, text, integer\) from public, anon, authenticated;/,
  );
});
