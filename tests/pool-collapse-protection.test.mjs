import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { admissionState, overloadedResponse, withInteractiveSlot } from "../lib/admission.ts";

// Release 1C: the interactive pool cannot be taken by abandoned requests, by a
// burst, or by the import worker.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const requestWith = (signal) => new Request("https://example.test/api/prospects", { signal });

test("a burst is admitted up to the limit, then refused rather than queued forever", async () => {
  const { limit } = admissionState();
  let release;
  const held = new Promise((resolve) => { release = resolve; });

  // Fill every slot with work that does not finish yet.
  const running = Array.from({ length: limit }, () =>
    withInteractiveSlot(requestWith(), async () => { await held; return Response.json({ ok: true }); }));
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(admissionState().inFlight, limit, "every slot should be taken");

  // One more waits rather than failing instantly...
  const queued = withInteractiveSlot(requestWith(), async () => Response.json({ ok: true }));
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(admissionState().waiting, 1, "a burst should wait briefly, not fail immediately");

  // ...and is admitted as soon as a slot frees, without a round trip.
  release();
  assert.equal((await queued).status, 200);
  await Promise.all(running);
  assert.equal(admissionState().inFlight, 0, "every slot must be given back");
  assert.equal(admissionState().waiting, 0);
});

test("a slot is returned even when the work throws", async () => {
  const before = admissionState().inFlight;
  await assert.rejects(withInteractiveSlot(requestWith(), async () => { throw new Error("boom"); }));
  assert.equal(admissionState().inFlight, before, "a thrown request must not leak its slot");
});

test("a caller that has already gone away does not take a slot", async () => {
  const controller = new AbortController();
  controller.abort();
  const response = await withInteractiveSlot(requestWith(controller.signal), async () => {
    throw new Error("must not run for an aborted caller");
  });
  assert.equal(response.status, 503);
  assert.equal(admissionState().inFlight, 0);
});

test("an overload is a non-cacheable 503 with Retry-After and a stable capacity code", async () => {
  const response = overloadedResponse();
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("Retry-After"), "2");
  const body = await response.json();
  assert.equal(body.retryable, true);
  assert.equal(body.code, 'capacity_limited');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
});

test("every interactive route is admitted through the guard and carries an abort signal", async () => {
  const routes = [
    "../app/api/prospects/route.ts",
    "../app/api/companies/route.ts",
    "../app/api/prospects/export/route.ts",
    "../app/api/prospects/filter-values/route.ts",
    "../app/api/companies/filter-values/route.ts",
  ];
  // A streaming export is not one query: it is dozens, with CSV going to the
  // client in between. Those take a slot per database call through acquireSlot
  // rather than one for the whole request, because holding an interactive slot
  // while the browser writes a file is exactly the pool collapse this guards
  // against. Both shapes are admitted; neither may query without a slot.
  const streamed = new Set(["../app/api/prospects/export/route.ts", "../app/api/companies/route.ts"]);
  for (const path of routes) {
    const source = await read(path);
    assert.match(source, /withInteractiveSlot\(request,|await acquireSlot\(signal\)/, `${path} must be admitted through the guard`);
    if (streamed.has(path)) {
      assert.match(source, /await acquireSlot\(signal\)/, `${path} must take a slot per streamed page`);
      assert.match(source, /release\(\);/, `${path} must give the per-page slot back`);
    }
    // PostgREST does not cancel on disconnect, so the signal does not free the
    // database - but it must still stop this process waiting on a dead request.
    assert.match(source, /\.abortSignal\(/, `${path} must propagate an abort signal`);
  }
});

test("the client backs off with jitter on reads and never retries a mutation", async () => {
  const api = await read("../lib/dashboard-api.ts");

  assert.match(api, /function fetchWithBackpressure/);
  assert.match(api, /idempotent/);
  // Only GET is retried; a mutation without an idempotency key must not be.
  assert.match(api, /fetchWithBackpressure\(path, options, method === "GET"\)/);
  // Jitter, or a refused burst returns as a synchronised burst.
  assert.match(api, /0\.5 \+ Math\.random\(\)/);
  assert.match(api, /Retry-After/);
  // An overload response says nothing about the data and must not be cached.
  assert.match(api, /if \(cacheable && generation === apiCacheGeneration && !isOverloaded\(response\)\)/);
});

test("the import worker has its own login role, bounded and unprivileged", async () => {
  const [bootstrap, compose, guard] = await Promise.all([
    read("../deploy/postgres/init/00-prospect-bootstrap.sh"),
    read("../deploy/docker-compose.yml"),
    read("../supabase/migrations/20260902000090_separate_the_import_worker_login.sql"),
  ]);

  // Created where the password lives and where superuser is available.
  assert.match(bootstrap, /create role prospect_import_worker login/);
  assert.match(bootstrap, /grant prospect_importer to prospect_import_worker/);
  assert.match(bootstrap, /revoke service_role from prospect_import_worker/);

  // Both pools bounded database-side, which is the authority the in-process
  // guard cannot be.
  assert.match(bootstrap, /alter role authenticator connection limit 30/);
  assert.match(bootstrap, /alter role prospect_import_worker connection limit 4/);
  assert.match(bootstrap, /alter role prospect_import_worker set statement_timeout/);

  // The worker actually uses it.
  assert.match(compose, /PGUSER: prospect_import_worker/);
  assert.doesNotMatch(compose, /PGUSER: authenticator/);

  // And a deploy that skips the bootstrap fails loudly instead of starting a
  // worker that cannot log in.
  assert.match(guard, /prospect_import_worker role is missing/);
  assert.match(guard, /00-prospect-bootstrap\.sh/);
  assert.match(guard, /it is a member of service_role, which defeats the separation/);
  assert.match(guard, /authenticator has no CONNECTION LIMIT/);
});

test("the measured cancellation gap is written down where it changes decisions", async () => {
  const [guard, bootstrap, admission] = await Promise.all([
    read("../supabase/migrations/20260902000090_separate_the_import_worker_login.sql"),
    read("../deploy/postgres/init/00-prospect-bootstrap.sh"),
    read("../lib/admission.ts"),
  ]);

  // Because PostgREST does not cancel, the statement timeout is the only bound
  // on how long an abandoned request holds its connection - so it comes down.
  assert.match(guard, /set statement_timeout = '10s'/);
  assert.match(guard, /does not cancel/);
  for (const source of [guard, bootstrap, admission]) {
    assert.match(source, /7\.9\s?s|7\.9 s/, "the measurement itself should travel with the reasoning");
  }
});
