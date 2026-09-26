import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260926170000_a_bulk_action_reindexes_a_bounded_slice_inline.sql";

test("a bulk action re-indexes at most 200 prospects inline and queues the rest", async () => {
  const migration = await read(migrationPath);

  // 53 s for a 5,000-prospect scope before, 0.8 s after, measured on
  // production. The bound is what keeps a large selection from holding an
  // interactive connection; the backlog is how the rest still lands.
  assert.match(migration, /if cardinality\(v_ids\) > 200 then/);
  assert.match(migration, /perform public\.enqueue_reindex\(v_ids\[201 : cardinality\(v_ids\)\], ''''\);/);
  assert.match(migration, /v_ids := v_ids\[1 : 200\];/);
  // The migration proves both halves on real rows and cleans up after itself.
  assert.match(migration, /v_row\.reindexed <> 200 or v_row\.queued <> 1000/);
  assert.match(migration, /the proof left rows in the reindex backlog/);
});

test("the TypeScript re-index path applies the same bound", async () => {
  const reindex = await read("../lib/reindex.ts");

  assert.match(reindex, /const inlineLimit = 200;/);
  // Deferred ids are queued without an error message: they are not failures.
  assert.match(reindex, /const deferred = unique\.slice\(inlineLimit\);/);
  assert.match(reindex, /await enqueue\(supabase, deferred, ""\)/);
  assert.match(reindex, /const inline = unique\.slice\(0, inlineLimit\);/);
  // The inline loop walks the bounded slice, never the whole selection.
  assert.match(reindex, /for \(let index = 0; index < inline\.length; index \+= batchSize\)/);
});

test("the worker drains a backlog back to back instead of every 15 seconds", async () => {
  const worker = await read("../worker/operations-worker.mjs");

  assert.match(worker, /const reindexCatchUpMs = setting\('OPERATIONS_REINDEX_CATCHUP_MS', 2000, 500, 600000\);/);
  // Only while there is progress and something left, so an empty or failing
  // backlog still waits the full interval.
  assert.match(worker, /if \(processed && remaining > 0\) \{\n\s+lastReindexDrainAt = Date\.now\(\) - reindexDrainIntervalMs \+ reindexCatchUpMs;/);
});
