import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { readinessLogDecision, resetReadinessLog, sustainedFailureMs } from "../lib/readiness-log.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("a deploy blip leaves one warning, not an error", () => {
  resetReadinessLog();
  const t = 1_000_000;
  // update.sh restarts the import worker mid-rollout; the app still serving
  // traffic correctly reports it down. That is the check working, not a fault.
  assert.deepEqual(readinessLogDecision(["importWorker"], t), { level: "warn", log: true });
  // The healthcheck polls every 10s. The next four polls must not each write.
  for (const dt of [10_000, 20_000, 30_000, 40_000]) {
    assert.equal(readinessLogDecision(["importWorker"], t + dt).log, false);
  }
  // Worker back. One warn row for the whole rollout.
  assert.equal(readinessLogDecision([], t + 45_000).log, false);
});

test("a failure that outlasts a restart escalates to error by itself", () => {
  resetReadinessLog();
  const t = 2_000_000;
  assert.equal(readinessLogDecision(["importWorker"], t).level, "warn");
  assert.equal(readinessLogDecision(["importWorker"], t + sustainedFailureMs - 1).log, false);
  // Nobody has to be watching for this to become an error.
  assert.deepEqual(readinessLogDecision(["importWorker"], t + sustainedFailureMs), { level: "error", log: true });
  // And it stays an error without writing a row every 10 seconds.
  assert.equal(readinessLogDecision(["importWorker"], t + sustainedFailureMs + 10_000).log, false);
  assert.deepEqual(readinessLogDecision(["importWorker"], t + sustainedFailureMs + 300_000),
    { level: "error", log: true });
});

test("recovery clears the clock, so a later blip is a blip again", () => {
  resetReadinessLog();
  const t = 3_000_000;
  readinessLogDecision(["importWorker"], t);
  readinessLogDecision([], t + 20_000);
  // An hour later, unrelated. Without the clock being cleared on recovery this
  // reads as a failure that has been running for an hour and escalates on its
  // first poll - which is why the healthy path calls the decision too.
  assert.deepEqual(readinessLogDecision(["importWorker"], t + 3_600_000), { level: "warn", log: true });
});

test("a different set of failing checks is a different incident", () => {
  resetReadinessLog();
  const t = 4_000_000;
  assert.equal(readinessLogDecision(["importWorker"], t).log, true);
  // Storage failing too is news, even five seconds in, and gets its own row.
  assert.deepEqual(readinessLogDecision(["importWorker", "storage"], t + 5_000), { level: "warn", log: true });
  // Order must not matter - it is which checks, not what order they arrived in.
  assert.equal(readinessLogDecision(["storage", "importWorker"], t + 10_000).log, false);
});

test("the health route uses the decision and clears state when healthy", async () => {
  const route = await read("../app/api/health/route.ts");

  assert.match(route, /const readiness = readinessLogDecision\(failed\);/);
  assert.match(route, /if \(readiness\.log\)/);
  assert.match(route, /level: readiness\.level/);
  // The decision has to be taken before the healthy early-return, or the clock
  // is never cleared and every later blip escalates immediately.
  const decision = route.indexOf("readinessLogDecision(failed)");
  const healthyReturn = route.indexOf('if (!failed.length) return Response.json');
  assert.ok(decision >= 0 && healthyReturn > decision,
    "the decision must run before the healthy return, or recovery never resets it");
  // No unconditional error level left behind.
  assert.doesNotMatch(route, /level: "error", source: "health"/);
});
