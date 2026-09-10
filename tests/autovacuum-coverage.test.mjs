import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260911110000_autovacuum_reaches_the_insert_only_tables.sql";
const tables = ["client_prospects", "list_memberships", "prospect_identifiers", "companies", "prospects", "list_rows"];

test("the insert-only tables get the setting that actually triggers on them", async () => {
  const migration = await read(migrationPath);

  // Autovacuum's main trigger is dead tuples, and an insert creates none - so
  // client_prospects, list_memberships and prospect_identifiers had never been
  // autovacuumed once since they were created. The vacuum scale factor alone
  // would not have fixed that; insert_scale_factor is the one that fires.
  for (const table of tables) {
    assert.ok(migration.includes("alter table public." + table + " set ("), "missing: " + table);
  }
  const insertFactors = migration.split("autovacuum_vacuum_insert_scale_factor = 0.05").length - 1;
  assert.equal(insertFactors, tables.length, "every table needs the insert scale factor, not just the append-only ones");
});

test("prospect_index keeps its tighter setting", async () => {
  const migration = await read(migrationPath);

  // 20260910150000 gave prospect_index 0.02 because an index-only scan there is
  // on the hottest path in the app. This migration must not loosen it, and it
  // checks rather than assumes.
  assert.ok(!/alter table public\.prospect_index/.test(migration));
  assert.ok(migration.includes("prospect_index lost its tighter setting"));
  // 0.05 for the rest: these are large but far less hot, and autovacuum that
  // runs too eagerly on a 2-vCPU box competes with the imports it supports.
  assert.ok(migration.includes("0.05 rather than the 0.02 given to prospect_index"));
});

test("the migration verifies the settings took, naming what matters", async () => {
  const migration = await read(migrationPath);

  assert.ok(migration.includes("kept its default autovacuum settings"));
  assert.ok(migration.includes("that is the one that matters for an append-only table"));
  // A settings-only change cannot repair a map that is already stale, and
  // VACUUM cannot run inside a transaction - which every migration here is.
  assert.ok(migration.includes("WHAT THIS DOES NOT DO"));
  assert.ok(migration.includes("VACUUM cannot run inside a transaction"));
});
