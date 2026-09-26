import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("interactive reads carry limits sized from their measured cost", async () => {
  const migration = await read("../supabase/migrations/20260926180000_interactive_reads_get_limits_sized_to_their_real_cost.sql");

  // Each is roughly 1.5-3x the slowest call pg_stat_statements has recorded
  // since 2026-09-01, so nothing that has ever succeeded would now fail.
  for (const [fn, limit] of [
    ["client_company_workspace_v2", "20s"],
    ["prospect_filter_values_v3", "15s"],
    ["prospect_title_taxonomy_v1", "15s"],
    ["title_class_filter_values_v1", "10s"],
    ["list_workspace", "10s"],
    ["client_company_prospects", "10s"],
    ["dashboard_workspace", "10s"],
  ]) {
    assert.match(migration, new RegExp(`alter function public\\.${fn}\\b[^;]*set statement_timeout = '${limit}';`));
  }

  // The genuinely slow three are named as needing their own fixes, not a
  // tighter limit that would only turn slow pages into errors.
  for (const fn of ["filter_companies_v4", "find_duplicate_candidates", "enrichment_preview_v1"]) {
    assert.ok(migration.includes(fn), `${fn} should be documented as deliberately untouched`);
    assert.doesNotMatch(migration, new RegExp(`alter function public\\.${fn}\\b`));
  }
});

test("the web role's backstop is 30 seconds, not 120", async () => {
  const bootstrap = await read("../deploy/postgres/init/00-prospect-bootstrap.sh");

  assert.match(bootstrap, /alter role authenticator set statement_timeout = '30s';/);
  assert.doesNotMatch(bootstrap, /alter role authenticator set statement_timeout = '120s';/);
});
