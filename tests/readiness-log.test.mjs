import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { readinessLogDecision, resetReadinessLog, sustainedFailureMs } from "../lib/readiness-log.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("a deploy blip leaves one warning, not an error", () => {
  resetReadinessLog();
  const t = 1_000_000;
  // A core check failing is news on its first poll: the container cannot serve.
  assert.deepEqual(readinessLogDecision(["storage"], t), { level: "warn", log: true });
  // The healthcheck polls every 10s. The next four polls must not each write.
  for (const dt of [10_000, 20_000, 30_000, 40_000]) {
    assert.equal(readinessLogDecision(["storage"], t + dt).log, false);
  }
  // Back. One warn row for the whole incident.
  assert.equal(readinessLogDecision([], t + 45_000).log, false);
});

test("a rollout's own worker restart writes nothing at all", () => {
  resetReadinessLog();
  const t = 1_500_000;
  // update.sh restarts the import worker mid-rollout, so the app still serving
  // traffic correctly reports it down - every single deploy. That row never
  // meant anything, and the worker no longer decides whether this container is
  // fit to serve, so the caller asks for the first poll not to be written.
  assert.deepEqual(readinessLogDecision(["importWorker"], t, false), { level: "warn", log: false });
  for (const dt of [10_000, 20_000, 30_000, 40_000]) {
    assert.equal(readinessLogDecision(["importWorker"], t + dt, false).log, false);
  }
  assert.equal(readinessLogDecision([], t + 45_000).log, false);
});

test("a worker that never comes back still escalates on its own", () => {
  resetReadinessLog();
  const t = 1_750_000;
  // Suppressing the first row must not suppress the incident: the clock still
  // starts, so a worker that outlasts a restart is an error row with nobody
  // watching - which is the whole point of not needing the first row.
  assert.equal(readinessLogDecision(["importWorker"], t, false).log, false);
  assert.equal(readinessLogDecision(["importWorker"], t + sustainedFailureMs - 1, false).log, false);
  assert.deepEqual(readinessLogDecision(["importWorker"], t + sustainedFailureMs, false), { level: "error", log: true });
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

  // Everything that is away is handed to the decision - a dead worker has to
  // escalate too - but only a core failure makes the first poll news.
  assert.match(route, /const readiness = readinessLogDecision\(unavailable, Date\.now\(\), failed\.length > 0\);/);
  assert.match(route, /if \(readiness\.log\)/);
  assert.match(route, /level: readiness\.level/);
  // The decision has to be taken before the healthy early-return, or the clock
  // is never cleared and every later blip escalates immediately.
  const decision = route.indexOf("readinessLogDecision(unavailable");
  const healthyReturn = route.indexOf('if (!failed.length) return Response.json');
  assert.ok(decision >= 0 && healthyReturn > decision,
    "the decision must run before the healthy return, or recovery never resets it");
  // No unconditional error level left behind.
  assert.doesNotMatch(route, /level: "error", source: "health"/);
});

// The app router reads /api/health and drops the slot on anything but a 200,
// so whatever is allowed into `failed` decides whether the SITE is up.
test("a background worker cannot take the container out of the load balancer", async () => {
  const [route, router] = await Promise.all([
    read("../app/api/health/route.ts"), read("../deploy/caddy/AppRouter.Caddyfile"),
  ]);

  // The import worker is checked, reported and escalated - but it is not one
  // of the checks that can answer 503.
  assert.match(route, /const coreChecks = \{ auth: checkAuth, dataApi: checkDataApi, storage: checkStorage \};/);
  assert.match(route, /const workerChecks = \{ importWorker: checkImportWorker \};/);
  assert.match(route, /const failed = coreEntries\.filter/);
  assert.match(route, /const degraded = workerEntries\.filter/);
  assert.match(route, /features = \{[^}]*importWorker: checkStatus\.importWorker/);

  // And one failed REQUEST is not a failed container: passive 5xx ejection
  // took the whole site down for 30s over a single bad import chunk, because
  // only one app slot normally runs. Checked against the directives alone -
  // the config's comments name what was removed, and should.
  const directives = router.split("\n").filter((line) => !line.trim().startsWith("#")).join("\n");
  assert.doesNotMatch(directives, /unhealthy_status/);
  assert.doesNotMatch(directives, /max_fails/);
  assert.match(directives, /health_uri \/api\/health/);
  // update.sh rewrites this exact line per slot and fails the release if it
  // cannot find it, so it must survive any edit here.
  assert.match(router, /reverse_proxy app-blue:3000 app-green:3000 \{/);
});
