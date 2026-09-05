import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { withInteractiveSlot } from "../lib/admission.ts";
import { observabilitySnapshot, outcomeFor, recordRequest, resetObservability, routeOf } from "../lib/observability.ts";

// Releases 1A-1C added three ways to refuse a request that did not exist before.
// Each is the right answer and each is invisible unless it is counted, so a cap
// or a limit set wrong for real traffic would only show up as users retrying.

test("each new refusal is classified as its own outcome", () => {
  assert.equal(outcomeFor(200), "ok");
  assert.equal(outcomeFor(202), "pending");
  assert.equal(outcomeFor(413), "over_cap");     // filter set past the cap
  assert.equal(outcomeFor(503), "overloaded");   // interactive guard full
  assert.equal(outcomeFor(429), "overloaded");
  assert.equal(outcomeFor(504), "timed_out");    // statement passed its ceiling
  assert.equal(outcomeFor(500), "server_error");
  assert.equal(outcomeFor(400), "client_error");
});

test("the route is recorded without its query string", () => {
  // A filter set of thousands of values travels in the query string; only the
  // path identifies the query family.
  assert.equal(routeOf("https://example.test/api/prospects?filters=%5B%5D&search=secret"), "/api/prospects");
  assert.equal(routeOf("not a url"), "unknown");
  assert.equal(routeOf('https://example.test/api/clients/private-client-id/lists'), '/api/clients');
  assert.equal(routeOf('https://example.test/api/private-arbitrary-path'), 'unknown');
});

test('pending latency never counts as completed results and route labels stay bounded', () => {
  resetObservability();
  recordRequest('/api/prospects', 202, 50);
  recordRequest('/api/prospects', 200, 1500);
  for (let i = 0; i < 50; i++) recordRequest(`/api/clients/private-${i}`, 200, 1);
  const snapshot = observabilitySnapshot();
  assert.equal(snapshot.outcomes.pending, 1);
  assert.equal(Object.keys(snapshot.routes).length, 2);
  assert.equal(snapshot.latency.buckets['/api/prospects:pending'][0], 1);
  assert.equal(snapshot.latency.buckets['/api/prospects:ok'][4], 1);
  resetObservability();
});

test("counts are kept per outcome and per route", () => {
  resetObservability();
  recordRequest("/api/prospects", 200, 12);
  recordRequest("/api/prospects", 200, 900);
  recordRequest("/api/prospects", 413, 3);
  recordRequest("/api/companies", 503, 2001);

  const snapshot = observabilitySnapshot();
  assert.equal(snapshot.requests, 4);
  assert.equal(snapshot.outcomes.ok, 2);
  assert.equal(snapshot.outcomes.over_cap, 1);
  assert.equal(snapshot.outcomes.overloaded, 1);
  assert.deepEqual(snapshot.routes["/api/prospects"], { ok: 2, over_cap: 1 });
  assert.deepEqual(snapshot.routes["/api/companies"], { overloaded: 1 });
  // The slowest request per route is what warns before the ceiling is crossed.
  assert.equal(snapshot.slowestMs["/api/prospects"], 900);
  resetObservability();
});

test("a request through the guard is counted with its real status", async () => {
  resetObservability();
  const request = new Request("https://example.test/api/prospects?filters=%5B%5D");

  await withInteractiveSlot(request, async () => Response.json({ ok: true }));
  await withInteractiveSlot(request, async () => Response.json({ error: "too big" }, { status: 413 }));
  await assert.rejects(withInteractiveSlot(request, async () => { throw new Error("boom"); }));

  const snapshot = observabilitySnapshot();
  assert.equal(snapshot.outcomes.ok, 1);
  assert.equal(snapshot.outcomes.over_cap, 1, "a 413 raised inside the handler must still be counted");
  assert.equal(snapshot.outcomes.server_error, 1, "a throw must be counted, not lost");
  resetObservability();
});

test("health reports load alongside readiness, and never caches it", async () => {
  const health = await readFile(new URL("../app/api/health/route.ts", import.meta.url), "utf8");
  assert.match(health, /observabilitySnapshot/);
  assert.match(health, /admissionState/);
  // Both the healthy and unhealthy answers carry it, or it disappears exactly
  // when it is most wanted.
  assert.match(health, /status: "ok", checks: checkStatus, load/);
  assert.match(health, /status: "unhealthy", checks: checkStatus, load/);
  assert.match(health, /no-store/);
});

test("the counters are not readable by an anonymous caller", async () => {
  const health = await readFile(new URL("../app/api/health/route.ts", import.meta.url), "utf8");
  // The endpoint has to stay publicly reachable: the deploy smoke test reads its
  // status and X-App-Version from a GitHub runner. But the admission limit is
  // exactly the number of slow requests needed to fill the guard, so the
  // counters go only to a signed-in caller. Readiness itself stays public.
  assert.match(health, /const authorized = await getAuthorizedUser\(\)/);
  assert.match(health, /authorized \? \{ admission: admissionState\(\), \.\.\.observabilitySnapshot\(\) \} : undefined/);
  // Resolving the user must never take readiness down with it.
  assert.match(health, /getAuthorizedUser\(\)\.catch\(\(\) => null\)/);
});
