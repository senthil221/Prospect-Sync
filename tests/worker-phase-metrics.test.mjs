import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createWorkerPhaseMetrics } from "../worker/phase-metrics.mjs";

test("worker phase metrics aggregate into bounded privacy-safe windows", () => {
  let time = 0;
  const written = [];
  const metrics = createWorkerPhaseMetrics({
    worker: "test-worker",
    phases: ["claim", "work"],
    intervalMs: 1_000,
    now: () => time,
    write: entry => written.push(entry),
  });

  assert.equal(metrics.record("claim", "empty", 12), true);
  assert.equal(metrics.record("customer-id", "ok", 1), false);
  time = 1_001;
  metrics.record("work", "ok", 120, 50);

  assert.equal(written.length, 1);
  assert.equal(written[0].event, "worker_phase_metrics");
  assert.deepEqual(written[0].phases.claim.outcomes, { ok: 0, empty: 1, skipped: 0, error: 0 });
  assert.equal(written[0].phases.work.units, 50);
  assert.doesNotMatch(JSON.stringify(written[0]), /customer-id/);
});

test("operations summaries stay serial and both workers emit phase windows", async () => {
  const [operations, imports] = await Promise.all([
    readFile(new URL("../worker/operations-worker.mjs", import.meta.url), "utf8"),
    readFile(new URL("../worker/import-worker.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(operations, /createWorkerPhaseMetrics/);
  assert.match(imports, /createWorkerPhaseMetrics/);
  assert.doesNotMatch(operations, /prospect-operations-snapshot/);
  assert.match(operations, /if \(!stopping\) await runSnapshots\(\);/);
  assert.match(imports, /activeWithinBudget/);
  assert.match(imports, /stagingTimeoutMs \+ 15_000/);
});
