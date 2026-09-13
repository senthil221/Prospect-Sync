import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260913020000_bound_the_last_untimed_app_functions.sql";

// Signature and the ceiling it must carry. The signatures are the identity
// arguments pg_proc reports, because to_regprocedure resolves nothing else.
const bounded = [
  ["public.client_company_prospects(text, text, integer, integer)", "30s"],
  ["public.export_parts_present_v1(uuid)", "15s"],
  ["public.enqueue_reindex(text[], text)", "30s"],
  ["public.apply_email_provider_scan_v1(jsonb)", "60s"],
  ["public.merge_prospects(text, text)", "60s"],
  ["public.purge_system_event_log_v1()", "60s"],
  ["public.complete_company_import_v1(text)", "120s"],
  ["public.import_company_batch_v2(text, jsonb, integer)", "120s"],
];

test("every app-called function that had no ceiling gets one", async () => {
  const migration = await read(migrationPath);

  for (const [signature, ceiling] of bounded) {
    const statement = "alter function " + signature + " set statement_timeout = '" + ceiling + "';";
    assert.ok(migration.includes(statement), "missing or wrong ceiling: " + signature);
  }
});

test("run_queue_unit_v1 is left alone, and the migration enforces that", async () => {
  const migration = await read(migrationPath);

  // Its handler is EXCEPTION WHEN OTHERS OR query_canceled followed by
  // fail_v1(). A cancelled statement there does not retry - it marks the export
  // or operation FAILED. A ceiling would turn "slow export" into "broken
  // export", which is the opposite of what was asked for.
  assert.ok(!/alter function prospect_operations\.run_queue_unit_v1/.test(migration));
  assert.ok(migration.includes("run_queue_unit_v1 must not be given a statement_timeout"));
  assert.ok(migration.includes("prospect_ops_worker role has statement_timeout=5min"));
});

test("the migration refuses to run on a premise that has gone stale", async () => {
  const migration = await read(migrationPath);

  // If one of these already carries a timeout, someone changed it by hand and
  // the measured table above is no longer describing reality.
  assert.ok(migration.includes("already has a timeout"));
  assert.ok(migration.includes("this migration assumed it did not"));
  assert.ok(migration.includes("cannot bound a function that does not exist"));
});

test("the pinned search_path survives the ALTER", async () => {
  const migration = await read(migrationPath);

  // ALTER FUNCTION ... SET replaces proconfig wholesale if misused, and the
  // pinned search_path is what stops a SECURITY DEFINER function resolving a
  // name against a caller-controlled schema.
  assert.ok(migration.includes("lost its pinned search_path"));
  assert.ok(migration.includes("privilege-escalation hole"));
  const verified = migration.split("did not take its timeout").length - 1;
  assert.equal(verified, 1, "the verification loop should assert once, over every signature");
});

test("the migration does not overstate what it changes", async () => {
  const migration = await read(migrationPath);

  // The authenticator role already imposes 120s on every one of these paths.
  // Only the ceilings set below 120s alter behaviour today; claiming otherwise
  // would make the next reader trust a bound that was already there.
  assert.ok(migration.includes("authenticator role carries statement_timeout=120s"));
  assert.ok(migration.includes("change no behaviour today"));
  assert.ok(migration.includes("documentation\n-- that the database enforces"));
});

test("the measured maxima are labelled with where they came from", async () => {
  const migration = await read(migrationPath);

  // pg_stat_statements was reset 2026-09-01 and track_functions is 'none', so
  // the numbers are a floor on what these cost, not a census of how often they
  // run. A later reader must not mistake one for the other.
  assert.ok(migration.includes("pg_stat_statements was last reset 2026-09-01"));
  assert.ok(migration.includes("track_functions is 'none'"));
  assert.ok(migration.includes("proves\n-- nothing about whether these run"));
});
