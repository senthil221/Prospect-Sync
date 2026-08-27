import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { api, clearApiCache, filterPayload } from "../lib/dashboard-api.ts";
import { parseCompanyScope, parsePeopleScope } from "../lib/workspace-scopes.ts";

test("polling requests bypass the client response cache", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => new Response(JSON.stringify({ sequence: ++calls }), {
    headers: { "content-type": "application/json" },
  });
  try {
    clearApiCache();
    assert.equal((await api("/poll-cache-test")).sequence, 1);
    assert.equal((await api("/poll-cache-test")).sequence, 1);
    assert.equal(calls, 1);
    assert.equal((await api("/poll-cache-test", { cache: "no-store" })).sequence, 2);
    assert.equal((await api("/poll-cache-test", { cache: "no-store" })).sequence, 3);
  } finally {
    globalThis.fetch = originalFetch;
    clearApiCache();
  }
});

test("company keyword scopes survive every workspace serialization boundary", () => {
  const filters = [{ id: "keywords", field: "__company_keywords", operator: "contains", values: ["security"], scopes: ["description"] }];
  const payload = filterPayload(filters);
  assert.deepEqual(payload[0].scopes, ["description"]);
  assert.deepEqual(parsePeopleScope(JSON.stringify({ search: "", filters: payload, limit: 999999 }))?.filters[0].scopes, ["description"]);
  assert.deepEqual(parseCompanyScope(JSON.stringify({ search: "", filters: payload, limit: 999999 }))?.filters[0].scopes, ["description"]);
  assert.equal(parseCompanyScope(JSON.stringify({ filters: payload, limit: 999999 }))?.limit, 250000);
});

test("client date, bounded pivots, Storage, and worker readiness are wired end to end", async () => {
  const [migration, startRoute, healthRoute, worker, compose, update, row] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260828010000_client_dates_pivot_limits.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/health/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../worker/import-worker.mjs", import.meta.url), "utf8"),
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ProspectTableRow.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(startRoute, /prospect_date_added: dateAdded/);
  assert.match(migration, /add column if not exists date_added date not null default current_date/);
  assert.match(migration, /least\(public\.client_prospects\.date_added, excluded\.date_added\)/);
  assert.match(migration, /client_date_added/);
  assert.match(migration, /limit %s[\s\S]*250000/);
  assert.match(row, /formatClientDate\(prospect\.client_date_added\)/);
  assert.match(healthRoute, /checkStorage[\s\S]*checkImportWorker/);
  assert.match(worker, /createServer[\s\S]*\/health[\s\S]*lastProgressAt/);
  assert.match(compose, /IMPORT_WORKER_HEALTH_URL: http:\/\/import-worker:9090\/health/);
  assert.ok(update.indexOf("wait_for_container prospect-import-worker") < update.indexOf("Waiting for backend-aware candidate health"));
});
