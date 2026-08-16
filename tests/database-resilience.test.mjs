import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL("../supabase/migrations/20260816005748_database_resilience.sql", import.meta.url);

test("uses conditional totals in the v11 workspace RPC", async () => {
  const [migration, route, dashboard] = await Promise.all([
    readFile(migrationUrl, "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(migration, /search_prospect_workspace_v11[\s\S]*p_with_total boolean default true/);
  assert.match(migration, /pg_class\.reltuples::bigint/);
  assert.match(migration, /revoke execute on function public\.search_prospect_workspace_v11[\s\S]*from public, anon, authenticated/);
  assert.match(migration, /grant execute on function public\.search_prospect_workspace_v11[\s\S]*to service_role/);
  assert.ok(route.indexOf('search_prospect_workspace_v11') < route.indexOf('search_prospect_workspace_v10'));
  assert.ok(route.indexOf('search_prospect_workspace_v11') < route.indexOf('search_prospect_workspace_v7'));
  assert.match(route, /p_with_total: query\.withTotal/);
  assert.match(dashboard, /withTotal: prospectPage === 1 && !prospectTotalCache\.current\.has/);
  assert.match(dashboard, /totalEstimated \? "≈"/);
});

test("bounds every hot database function to 15 seconds", async () => {
  const migration = await readFile(migrationUrl, "utf8");
  for (const name of ["search_prospect_workspace_v11", "import_prospect_batch_v5", "reindex_prospects", "reindex_all"]) {
    assert.match(migration, new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?set statement_timeout = '15s'`));
  }
});
