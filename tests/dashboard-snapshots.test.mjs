import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260911120000_dashboards_are_read_not_computed.sql";

test("the tabs read a row instead of scanning the database", async () => {
  const [quality, taxonomy] = await Promise.all([
    read("../app/api/data-quality/route.ts"),
    read("../app/api/prospects/title-taxonomy/route.ts"),
  ]);

  // 13.3s and 12.2s today; past their own ceilings at 10M rows. Neither needs
  // computing at the instant somebody looks.
  assert.ok(quality.includes('rpc("dashboard_snapshot_v1", { p_key: "dataQuality" })'));
  assert.ok(quality.includes('rpc("dashboard_snapshot_v1", { p_key: "indexDrift" })'));
  assert.ok(!quality.includes('rpc("data_quality_overview")'));
  assert.ok(!quality.includes('rpc("prospect_index_drift")'));

  // A client-scoped taxonomy is per workspace and narrower, so it still
  // computes; only the master-wide one - the same answer for everyone - is
  // snapshotted.
  assert.ok(taxonomy.includes('rpc("dashboard_snapshot_v1", { p_key: "titleTaxonomy" })'));
  assert.ok(taxonomy.includes('rpc("prospect_title_taxonomy_v1", { p_client_id: clientId })'));
});

test("the API says when the numbers were computed", async () => {
  const quality = await read("../app/api/data-quality/route.ts");

  // After an import these lag by one refresh cycle. That is the right trade for
  // a quality summary, but it has to be said rather than implied.
  assert.ok(quality.includes("computedAt:"));
  assert.ok(quality.includes("current:"));
});

test("a snapshot is keyed on the data version, so it is exact when nothing changed", async () => {
  const migration = await read(migrationPath);

  // The whole version object, not one number: the quality summary depends on
  // prospects and companies both.
  assert.ok(migration.includes("data_versions_v1(array['prospect', 'company'])"));
  assert.ok(migration.includes("where s.key = v_key and s.data_version = v_versions"));
  // Skipping unchanged keys is the point - a quiet database costs three
  // comparisons per cycle, not three full scans.
  assert.ok(migration.includes("continue;"));
  assert.ok(migration.includes("the refresh recomputed an unchanged snapshot"));
});

test("the refresh belongs to the worker role, not the web role", async () => {
  const migration = await read(migrationPath);

  // The worker role is deliberately not service_role and gets only what it needs.
  assert.ok(migration.includes("create or replace function prospect_operations.refresh_dashboard_snapshots_v1"));
  assert.ok(migration.includes("grant execute on function prospect_operations.refresh_dashboard_snapshots_v1() to prospect_operator, service_role;"));
  assert.ok(migration.includes("revoke all on public.dashboard_snapshot from public, anon, authenticated;"));
  assert.ok(migration.includes("alter table public.dashboard_snapshot enable row level security;"));
});

test("the tabs are never blank, because the migration fills the snapshot first", async () => {
  const migration = await read(migrationPath);

  // Populated before commit, so there is no window where the tab waits for the
  // first worker pass.
  const populate = migration.indexOf("select prospect_operations.refresh_dashboard_snapshots_v1();");
  const assertions = migration.indexOf("no snapshot was written for");
  assert.ok(populate > 0 && assertions > populate, "populate before asserting");
  assert.ok(migration.includes("would blank the tab"));
});

test("the worker refresh has its own deadline, inside a transaction", async () => {
  const worker = await read("../worker/operations-worker.mjs");

  // Retention runs every 5s under a 3s statement timeout; a whole-database
  // summary fits neither, so this is a separate pass.
  assert.ok(worker.includes("OPERATIONS_SNAPSHOT_MS"));
  assert.ok(worker.includes("await runSnapshots();"));
  // SET LOCAL means nothing outside a transaction.
  const fn = worker.slice(worker.indexOf("async function runSnapshots"), worker.indexOf("async function main"));
  assert.ok(fn.includes("await client.query('BEGIN');"));
  assert.ok(fn.includes("SET LOCAL statement_timeout = '300s'"));
  assert.ok(fn.includes("ROLLBACK"));
  // A stale summary must not take the worker down with it.
  assert.ok(fn.includes("Dashboard snapshot refresh failed"));
});
