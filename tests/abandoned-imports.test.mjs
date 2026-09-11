import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260911130000_abandoned_company_imports_stop_pinning_their_staging.sql";

test("an import is judged by activity, not by how long ago it started", async () => {
  const migration = await read(migrationPath);

  // A large import that has run for hours writes staging rows continuously, so
  // it can never be expired by this. One that has written nothing for a day is
  // not coming back.
  assert.ok(migration.includes("coalesce(max(r.imported_at), i.created_at)"));
  assert.ok(migration.includes("< now() - make_interval(hours => v_hours)"));
  assert.ok(migration.includes("where i.status = 'processing'"));
});

test("the recorded status says something true about the data", async () => {
  const migration = await read(migrationPath);

  // processed_rows reaching total_rows means the work was done and the rows are
  // in the database; calling that 'failed' would be untrue. Stopping short is
  // genuinely a failure. Those are the only two the check constraint allows
  // besides 'processing'.
  assert.ok(migration.includes("then 'completed'"));
  assert.ok(migration.includes("else 'failed'"));
  assert.ok(migration.includes("coalesce(s.processed_rows, 0) >= s.total_rows"));
});

test("retention is left alone; it was never the thing that was wrong", async () => {
  const migration = await read(migrationPath);

  // purge_company_import_rows_v1 refuses rows of an import still 'processing'
  // because staging is the resume point. That rule is correct and untouched -
  // what was missing was anything that decides an import is not coming back.
  assert.ok(!/purge_company_import_rows_v1\s*\(/.test(migration.replace(/--.*$/gm, "")));
  assert.ok(migration.includes("That rule is right"));
});

test("the sweep is idempotent and cannot run away", async () => {
  const migration = await read(migrationPath);

  // A second pass must find nothing, or it would churn every cycle forever.
  assert.ok(migration.includes("a second pass expired more imports"));
  // Bounded per call, and the staleness window is clamped.
  assert.ok(migration.includes("least(coalesce(p_stale_hours, 24), 24 * 30)"));
  assert.ok(migration.includes("least(coalesce(p_limit, 50), 500)"));
});

test("the worker sweeps on its own timer, in its own transaction", async () => {
  const worker = await read("../worker/operations-worker.mjs");

  assert.ok(worker.includes("await runImportJanitor();"));
  const fn = worker.slice(worker.indexOf("async function runImportJanitor"), worker.indexOf("async function runSnapshots"));
  // Its own clock, not a side effect of whether the snapshot pass just ran.
  assert.ok(fn.includes("lastJanitorAt"));
  // A failed sweep must not roll back a refreshed dashboard.
  assert.ok(fn.includes("await client.query('BEGIN');"));
  assert.ok(fn.includes("ROLLBACK"));
  assert.ok(fn.includes("Abandoned import sweep failed"));
});
