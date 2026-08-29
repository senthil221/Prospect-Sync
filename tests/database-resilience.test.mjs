import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL("../supabase/migrations/20260816005748_database_resilience.sql", import.meta.url);
const prefilterMigrationUrl = new URL("../supabase/migrations/20260825000000_restore_prefilter_and_bulk_counts.sql", import.meta.url);

test("uses conditional totals in the current workspace RPC", async () => {
  const [migration, route, dashboard] = await Promise.all([
    readFile(prefilterMigrationUrl, "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(migration, /search_prospect_workspace_v12[\s\S]*p_with_total boolean default true/);
  assert.match(migration, /pg_class\.reltuples::bigint/);
  assert.match(migration, /revoke execute on function public\.search_prospect_workspace_v12[\s\S]*from public, anon, authenticated/);
  assert.match(migration, /grant execute on function public\.search_prospect_workspace_v12[\s\S]*to service_role/);
  assert.match(route, /p_with_total: query\.withTotal/);
  assert.match(dashboard, /withTotal: prospectPage === 1 && !prospectTotalCache\.current\.has/);
  assert.match(dashboard, /totalEstimated \? "≈"/);
});

// The whole point of the pre-filter is that the opaque scalar matcher must never
// be the first thing the planner sees. Guard the ordering, not just its presence.
test("the workspace RPC applies the indexed pre-filter before the scalar matcher", async () => {
  const migration = await readFile(prefilterMigrationUrl, "utf8");
  const body = migration.slice(
    migration.indexOf("create or replace function public.search_prospect_workspace_v12"),
    migration.indexOf("revoke execute on function public.search_prospect_workspace_v12"),
  );
  assert.match(body, /prospect_prefilter_sql/);
  assert.ok(
    body.indexOf("prospect_prefilter_sql") < body.indexOf("prospect_index_matches_v1"),
    "the pre-filter must be built before the scalar matcher is appended",
  );
  // Narrow sort set, then hydrate by id - never to_jsonb over every matched row.
  assert.match(body, /matched as materialized/);
  assert.match(body, /hydrated as \(\s*select pi\.\*/);
  // An empty company scope must not join the scope CTE at all, or company-less
  // prospects would silently vanish from unscoped results.
  assert.match(body, /if v_has_scope then/);
});

test("bounds every hot database function to a statement timeout", async () => {
  const [resilience, prefilter] = await Promise.all([
    readFile(migrationUrl, "utf8"),
    readFile(prefilterMigrationUrl, "utf8"),
  ]);
  for (const name of ["import_prospect_batch_v5", "reindex_prospects", "reindex_all"]) {
    assert.match(resilience, new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?set statement_timeout = '15s'`));
  }
  assert.match(prefilter, /create or replace function public\.search_prospect_workspace_v12\([\s\S]*?set statement_timeout = '20s'/);
});

test("analyzes planner statistics after both import completion paths", async () => {
  const [migration, prospectCompletion, companyCompletion] = await Promise.all([
    readFile(migrationUrl, "utf8"),
    readFile(new URL("../app/api/imports/complete/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/complete/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(migration, /create or replace function public\.analyze_prospect_index\(\)[\s\S]*analyze public\.prospect_index;[\s\S]*analyze public\.companies;/);
  assert.match(migration, /revoke execute on function public\.analyze_prospect_index\(\) from public, anon, authenticated/);
  assert.match(migration, /grant execute on function public\.analyze_prospect_index\(\) to service_role/);
  for (const route of [prospectCompletion, companyCompletion]) {
    assert.match(route, /after\(async \(\) =>/);
    assert.match(route, /rpc\("analyze_prospect_index"\)/);
    assert.match(route, /catch \(analyzeError\)/);
  }
});

test("debounces and cancels superseded workspace searches", async () => {
  const dashboard = await readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8");
  assert.match(dashboard, /useDebouncedValue\(deferredSearch, 300\)/);
  assert.match(dashboard, /new AbortController\(\)/);
  assert.match(dashboard, /signal: controller\.signal/);
  assert.match(dashboard, /controller\.abort\(\)/);
  assert.match(dashboard, /!isAbortError\(caught\)/);
  assert.match(dashboard, /const deferredSearch = useDeferredValue\(search\)/);
});
