import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");
const migration = () => read("../supabase/migrations/20260902000230_bulk_selection_stops_calling_the_row_function.sql");

// Found by auditing the other entry points after "See People" turned out to have
// missed the plan chooser. resolve_company_action_selection_v1 turns "select
// everything this filter matches" into the ids a bulk action works on, and it
// was the last caller applying company_matches_filters_v1 per row -- 419,214
// invocations, none of them inlinable. Against SET statement_timeout '30s':
//
//   51-keyword filter   219,460 ms -> 8,561 ms
//   single keyword       64,504 ms ->   310 ms
//   no filter at all     29,292 ms ->    67 ms
//
// Every filtered bulk selection was failing, not just large ones.
test("the selection resolver prefers the translated predicate", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.resolve_company_action_selection_v1/i);
  assert.match(statements, /v_match := coalesce\(\s*\n\s*public\.company_full_scan_filter_sql_v1\(/);
  // The row function survives only as the fallback for shapes the translator
  // cannot express, which is what every other caller does.
  assert.match(statements, /format\('public\.company_matches_filters_v1\(c, %L, %L::jsonb\)'/);
});

// The worse half of the bug: the row function is a separate implementation, so
// 20260902000210's case fix never reached it. It returned 38,448 ids where the
// listing showed 41,057 for the same filter -- a bulk action would have deleted
// or pushed a set the user could not see.
test("the resolver and the listing now answer the same question", async () => {
  const statements = statementsOnly(await migration());

  // Asking the same chooser as filter_companies_v4 and company_scope_ids_v2 is
  // what makes them agree; there is no second copy of the rule to drift.
  const asks = statements.match(/public\.company_full_scan_filter_sql_v1\(/g) ?? [];
  assert.equal(asks.length, 1, "one call, to the shared chooser");
  assert.doesNotMatch(statements, /tablesample|v_broad_fraction/,
    "re-deriving the threshold here would be a second decision to drift");
});

// An explicit id list is a different question and must not pay for the filters.
test("an explicit id list skips the filter work entirely", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /if p_company_ids is not null then/);
  assert.match(statements, /'c\.id = any\(\$2\[1:50000\]\)'/);
  // The two branches number their parameters differently, so each is executed
  // with its own USING list rather than one template with a gap in it.
  const usings = statements.match(/using p_client_id/g) ?? [];
  assert.equal(usings.length, 2, "each branch binds its own parameters");
});

// PostgREST resolves this function by argument name and omits what the caller
// does not send; dropping the defaults would break every existing call.
test("the parameter defaults are preserved exactly", async () => {
  const statements = statementsOnly(await migration());

  for (const parameter of [
    /p_client_id text default null::text/,
    /p_company_ids text\[\] default null::text\[\]/,
    /p_search text default ''::text/,
    /p_filters jsonb default '\[\]'::jsonb/,
    /p_people_scope jsonb default null::jsonb/,
    /p_excluded_ids text\[\] default null::text\[\]/,
    /p_limit integer default 250000/,
  ]) {
    assert.match(statements, parameter);
  }
});

// The client-membership, people-scope and exclusion conditions all have to
// survive, or the selection silently widens.
test("every scoping condition survives the rewrite", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /from public\.client_companies membership/);
  assert.match(statements, /membership\.added_by not in \('membership-backfill', 'prospect-membership', 'prospect-company-change'\)/);
  assert.match(statements, /public\.people_scope_company_ids_v1\(%1\$s, %3\$s\)/);
  assert.match(statements, /not \(c\.id = any\(%4\$s\)\)/);
  assert.match(statements, /order by c\.id/);
});

test("the rewritten function is locked to service_role", async () => {
  const statements = statementsOnly(await migration());
  const signature = "public\\.resolve_company_action_selection_v1\\(text, text\\[\\], text, jsonb, jsonb, text\\[\\], integer\\)";
  assert.match(statements, new RegExp(`revoke execute on function ${signature} from public, anon, authenticated;`));
  assert.match(statements, new RegExp(`grant execute on function ${signature} to service_role;`));
});
