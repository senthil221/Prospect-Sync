import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = () =>
  readFile(new URL("../supabase/migrations/20260901000060_client_companies_read_stored_client_count.sql", import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

// 20260815010000 denormalized companies.client_count onto the table, maintained by
// a trigger, so listings would stop aggregating it live. company_summaries honours
// that; client_company_workspace_v2 recomputed it on both paths -- a CTE over the
// whole client_companies table when unfiltered, and a per-row lateral when not.
test("the client company listing reads the stored client_count on both paths", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.client_company_workspace_v2/i);
  assert.match(statements, /c\.client_count/);

  // Neither way of recomputing it may survive.
  assert.doesNotMatch(statements, /coverage_counts/,
    "the unfiltered path must not aggregate client_companies");
  assert.doesNotMatch(statements, /all_memberships/,
    "the filtered path must not run a per-row lateral for client_count");
  assert.doesNotMatch(statements, /coalesce\(coverage\.client_count, 0\)/);

  // The per-client prospect count is genuinely client-scoped and stays computed:
  // companies.prospect_count is global, so it cannot answer this.
  assert.match(statements, /client_counts as \(/);
  assert.match(statements, /pi\.client_ids @> array\[%L\]/);
});

test("the listing keeps its bounded count and its exact unfiltered total", async () => {
  const statements = statementsOnly(await migration());
  // Removing the aggregate must not disturb the capping behaviour added in
  // 20260831200000: unfiltered stays exact, anything narrowing is capped.
  assert.match(statements, /v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all' else '50001' end;/);
  assert.match(statements, /count\(\*\) > 50000 and %8\$L <> 'all'/);
  assert.match(statements, /order by prospect_count desc, lower\(name\), id/);
});

test("the SECURITY DEFINER listing revokes EXECUTE in the same file", async () => {
  const sql = await migration();
  assert.match(sql, /security definer/i);
  assert.match(
    sql,
    /revoke execute on function public\.client_company_workspace_v2\(text, text, jsonb, jsonb, integer, integer\) from public, anon, authenticated;/,
  );
});
