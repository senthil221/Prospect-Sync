import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { api, clearApiCache, filterPayload } from "../lib/dashboard-api.ts";
import { prospectImportObjectPath, validProspectImportObjectPath } from "../lib/import-storage.ts";
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

test("prospect signed uploads are scoped to the authenticated owner", async () => {
  const userId = "123e4567-e89b-42d3-a456-426614174000";
  const otherUserId = "123e4567-e89b-42d3-a456-426614174001";
  const fingerprint = "a".repeat(64);
  const path = prospectImportObjectPath(userId, fingerprint);
  assert.equal(path, `pending/${userId}/${fingerprint}.csv`);
  assert.equal(validProspectImportObjectPath(path, userId), true);
  assert.equal(validProspectImportObjectPath(path, otherUserId), false);
  assert.equal(validProspectImportObjectPath(`pending/${fingerprint}.csv`, userId), false);

  const [tokenRoute, startRoute, resumable] = await Promise.all([
    readFile(new URL("../app/api/imports/upload-token/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/resumable-upload.ts", import.meta.url), "utf8"),
  ]);
  assert.match(tokenRoute, /prospectImportObjectPath\(user\.id, normalizedFingerprint\)/);
  assert.match(startRoute, /validProspectImportObjectPath\(payload\.storageObjectPath, user\.id\)/);
  assert.match(resumable, /storage\/v1\/upload\/resumable\/sign/);
  assert.match(resumable, /fingerprint: \(\) => Promise\.resolve\(`prospect-import:\$\{objectPath\}`\)/);
});

test("Date Contacted, bounded pivots, Storage, and worker readiness are wired end to end", async () => {
  const [migration, pivotMigration, startRoute, clientRoute, healthRoute, worker, compose, update, row, table] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260829004125_client_date_contacted.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260828010000_client_dates_pivot_limits.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/health/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../worker/import-worker.mjs", import.meta.url), "utf8"),
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ProspectTableRow.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ProspectTable.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(startRoute, /prospect_date_added: dateContacted/);
  assert.match(startRoute, /if \(value === null\) return null/);
  assert.match(migration, /alter column date_added drop not null/);
  assert.match(migration, /client_date_contacted/);
  assert.match(migration, /set_client_date_contacted_v1/);
  assert.match(clientRoute, /action === "set_date_contacted"/);
  assert.match(table, /Set Date Contacted/);
  assert.match(table, /No contact date \(clear existing date\)/);
  assert.match(pivotMigration, /limit %s[\s\S]*250000/);
  assert.match(row, /formatClientDate\(prospect\.client_date_contacted\)/);
  assert.match(healthRoute, /checkStorage[\s\S]*checkImportWorker/);
  assert.match(worker, /createServer[\s\S]*\/health[\s\S]*lastProgressAt/);
  assert.match(compose, /IMPORT_WORKER_HEALTH_URL: http:\/\/import-worker:9090\/health/);
  assert.ok(update.indexOf("wait_for_container prospect-import-worker") < update.indexOf("Waiting for backend-aware candidate health"));
});
