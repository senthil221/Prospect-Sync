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

// The header comment quotes the v3 body it replaces, `union all` and `select ps.*`
// included, so absence assertions have to look at the statements alone.
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

test("filter values build one branch instead of unioning every field", async () => {
  const sql = await migration();

  assert.match(sql, /create or replace function public\.prospect_filter_values_v3/i);
  // Dynamic SQL is what makes the branch selection happen before planning.
  assert.match(sql, /language plpgsql/i);
  assert.match(sql, /return query execute v_sql;/);

  // The three costs that made v3 slow must all be gone.
  const statements = statementsOnly(sql);
  assert.doesNotMatch(statements, /select ps\.\*/, "must not carry all 52 columns");
  assert.doesNotMatch(statements, /union all/i, "must not union every field's branch");

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

// v_conditions is text[]. Appending a bare string literal to it made the parser
// read `array || unknown` as anyarray || anyarray and try to parse the string as
// an array literal, so opening the "Last contacted" filter errored:
//   ERROR: malformed array literal: "ps.last_contacted_at is not null"
// format() returns explicitly typed text and resolves correctly, which is why
// only the one branch that used a bare literal broke.
test("conditions are appended in a form that does not depend on literal typing", async () => {
  const fix = await readFile(
    new URL("../supabase/migrations/20260901000070_fix_last_contacted_filter_values.sql", import.meta.url),
    "utf8",
  );
  const statements = fix.replace(/^\s*--.*$/gm, "");

  assert.match(statements, /v_conditions := array_append\(v_conditions, 'ps\.last_contacted_at is not null'\)/);
  // Any remaining `v_conditions || ...` must wrap its text in format().
  for (const line of statements.split("\n").filter((l) => /v_conditions := v_conditions \|\|/.test(l))) {
    assert.match(line, /\|\| format\(/, `bare literal appended to a text[]: ${line.trim()}`);
  }
});
