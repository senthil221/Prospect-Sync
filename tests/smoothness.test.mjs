import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("screens other than Overview, People and Companies load on demand, then preload when idle", async () => {
  const app = await read("../app/DashboardApp.tsx");
  for (const screen of ["ClientsPanel", "CoveragePanel", "DataQualityPanel", "ImportsPanel", "IntegrationsPanel", "ReplyBlocklistPanel", "EmailVerificationWorkspace", "IcpChecksWorkspace", "LogsPanel"]) {
    assert.doesNotMatch(app, new RegExp(`^import ${screen} from`, "m"), `${screen} must not be a static import`);
    assert.ok(app.includes(`const ${screen} = dynamic(`), `${screen} must load through next/dynamic`);
  }
  assert.match(app, /requestIdleCallback/);
  assert.match(app, /usePreloadScreens\(isAdmin\);/);
});

test("verification results move the prospect cache version at most once a minute", async () => {
  const migration = await read("../supabase/migrations/20260930200000_verification_results_move_the_cache_version_once_a_minute.sql");
  assert.match(migration, /current_setting\('prospect_verification\.projection_only', true\) = 'on'/);
  assert.match(migration, /perform set_config\('prospect_verification\.projection_only', 'on', true\);\s+update public\.prospect_index set/);
  // The mark is cleared right after the projection statement, so nothing else in
  // the transaction is coalesced.
  assert.match(migration, /where id = new\.id;\s+perform set_config\('prospect_verification\.projection_only', '', true\);/);
  assert.match(migration, /Cache version proof passed and was rolled back/);
  const harness = await read("../scripts/test-email-verification-migration.mjs");
  assert.ok(harness.includes("20260930200000_verification_results_move_the_cache_version_once_a_minute.sql"));
});
