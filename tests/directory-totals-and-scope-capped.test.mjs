import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

// prospect_summaries is a live aggregating view: it joins lists and clients and
// computes count(DISTINCT ...) per prospect. Counting rows through it re-ran that
// aggregation for all 674,804 prospects to produce one stat card -- 26,131 ms
// cold, 10,685 ms mean warm, on every unfiltered Companies page load.
test("the linked-prospect total comes off the index, not the aggregating view", async () => {
  const [migration, route] = await Promise.all([
    read("../supabase/migrations/20260901000050_directory_totals_and_scope_capped.sql"),
    read("../app/api/companies/route.ts"),
  ]);

  assert.match(migration, /create or replace function public\.linked_prospect_total_v1/i);
  assert.match(statementsOnly(migration), /from public\.prospect_index pi/);
  assert.doesNotMatch(statementsOnly(migration), /prospect_summaries/,
    "the whole point is to stop counting through the view");

  assert.match(route, /rpc\("linked_prospect_total_v1", \{ p_search: search \}\)/);
  assert.doesNotMatch(route, /from\("prospect_summaries"\)/,
    "no route should count through prospect_summaries again");
  // The RPC returns a scalar, so the count arrives as data rather than as `count`.
  assert.match(route, /prospectTotal: Number\(prospects\.data \?\? 0\)/);
});

// company_scope_ids_v2 caps at 250,000 companies. Before 20260901000010 an
// unfiltered scope silently truncated to that and lost 151,465 prospects. That
// case no longer joins, but a scope that genuinely restricts can still hit the
// cap -- and a short answer that looks complete is the failure worth surfacing.
test("a company scope that hits its cap is reported all the way to the UI", async () => {
  const [migration, route, workspace, table] = await Promise.all([
    read("../supabase/migrations/20260901000050_directory_totals_and_scope_capped.sql"),
    read("../app/api/prospects/route.ts"),
    read("../app/components/ProspectsWorkspace.tsx"),
    read("../app/components/ProspectTable.tsx"),
  ]);

  // Return type gains a column, so it must be DROP + CREATE, not CREATE OR REPLACE.
  assert.match(migration, /drop function if exists public\.search_prospect_workspace_v12/i);
  assert.match(migration, /returns table\(result_rows jsonb, total_count bigint, scope_capped boolean\)/i);
  // The cap compared against must be the one company_scope_ids_v2 actually used.
  assert.match(migration, /greatest\(1000, least\(\(v_scope->>'limit'\)::bigint, 250000\)\)/);
  assert.match(migration, /v_capped_expr := format\('\(\(select count\(\*\) from eligible_companies\) >= %s\)'/);

  assert.match(route, /scopeCapped: summary\.scope_capped === true/);
  assert.match(workspace, /setScopeCapped\(data\.scopeCapped === true\)/);
  assert.match(workspace, /scopeCapped=\{controller\.scopeCapped\}/);
  assert.match(table, /scopeCapped \? "capped" : ""/);
  assert.match(table, /matched more than \{formatNumber\(companyScope\.limit\)\} companies/);
});

// Crossing exactMatchThreshold changes the operator, which changes how many rows
// come back. Both paste surfaces must say which mode is in force.
test("both paste surfaces state whether matching is exact or substring", async () => {
  const [bulkValues, people, company] = await Promise.all([
    read("../lib/bulk-values.ts"),
    read("../app/ApolloFilterPanel.tsx"),
    read("../app/CompanyFilterPanel.tsx"),
  ]);

  assert.match(bulkValues, /export function describeMatchMode/);
  assert.match(bulkValues, /Matching these \$\{valueCount\.toLocaleString\("en-IN"\)\} \$\{noun\}s exactly\./);
  assert.match(people, /describeMatchMode\(result\.values\.length\)/);
  assert.match(company, /describeMatchMode\(result\.values\.length, "domain"\)/);
});

test("the new SECURITY DEFINER functions revoke EXECUTE in the same file", async () => {
  const migration = await read("../supabase/migrations/20260901000050_directory_totals_and_scope_capped.sql");
  assert.match(migration, /revoke execute on function public\.linked_prospect_total_v1\(text\) from public, anon, authenticated;/);
  assert.match(
    migration,
    /revoke execute on function public\.search_prospect_workspace_v12\(text, jsonb, text, text, integer, integer, text, jsonb, boolean\) from public, anon, authenticated;/,
  );
});
