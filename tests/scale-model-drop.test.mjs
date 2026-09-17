import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const sqlOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");
const migration = () => read("../supabase/migrations/20260918150000_the_two_million_row_scale_model_is_dropped.sql");

// audit_2m held a 2,000,000-row copy of prospect_index with its index set
// mirrored, built 2026-09-14 to read plans at ~3x production volume.
//
// Measured 2026-09-18: 1,958 MB, 15% of a 13 GB database, n_tup_upd 0,
// n_tup_del 0, seq_scan 20, and idx_scan 0 summed across all eight indexes -
// not one of them was ever used. Inert for four days, and in every nightly
// pg_dump because that dump has no --exclude-schema.
test("the schema is dropped, and the drop is a cascade with the schema named", async () => {
  const sql = sqlOnly(await migration());
  assert.match(sql, /drop schema if exists audit_2m cascade;/);
  // if exists, because a fresh environment never had it.
  assert.doesNotMatch(sql, /drop schema audit_2m/);
});

// A cascade on a schema that has quietly acquired a dependent takes the
// dependent with it. Every guard must refuse rather than proceed.
test("it refuses to drop a schema that is not the one it was written for", async () => {
  const sql = sqlOnly(await migration());

  const dropAt = sql.indexOf("drop schema if exists audit_2m cascade");
  for (const guard of [
    "holds objects this migration did not expect",
    "tables, expected exactly one",
    "routines; refusing to drop it cascade",
    "the cascade would take them too",
  ]) {
    assert.ok(sql.includes(guard), `missing guard: ${guard}`);
    assert.ok(sql.indexOf(guard) < dropAt, `guard must run before the drop: ${guard}`);
  }

  // Absent schema is a notice and a return, not a failure: this migration has
  // to be a no-op everywhere it never existed.
  assert.match(sql, /audit_2m is not present; nothing to drop/);
});

// The dropped table and the real one share a relname. A mistake there would be
// the expensive kind, so it is checked explicitly afterwards.
test("the real prospect_index is asserted to survive", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /audit_2m survived the drop/);
  assert.match(sql, /public\.prospect_index is missing after dropping audit_2m/);
  assert.ok(sql.includes("n.nspname = 'public' and c.relname = 'prospect_index'"),
    "the survival check must name the public schema explicitly");
});

// Undoing this depends on the snapshots, and that dependency has an expiry.
test("the recovery path and its limit are written down", async () => {
  const source = await migration();

  assert.match(source, /pg_restore --schema=audit_2m/);
  assert.match(source, /20260917T031731Z/);
  assert.match(source, /retention window/);
});
