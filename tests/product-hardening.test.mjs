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

test("API errors remain actionable when a proxy returns an empty or non-JSON body", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (path) => {
    if (String(path).includes("plain")) {
      return new Response("Upstream database request timed out.", {
        status: 502,
        statusText: "Bad Gateway",
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    return new Response("", { status: 504, statusText: "Gateway Timeout" });
  };
  try {
    clearApiCache();
    await assert.rejects(api("/empty-error"), /Gateway Timeout/);
    await assert.rejects(api("/plain-error"), /Upstream database request timed out/);
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

test("company description filters retain the indexed prefilter before exact verification", async () => {
  const migration = await readFile(new URL(
    "../supabase/migrations/20260831130211_restore_indexed_company_filter_prefilter.sql",
    import.meta.url,
  ), "utf8");
  assert.match(migration, /company_effective_filter_sql_v1/);
  assert.match(migration, /v_prefilter <> 'true'/);
  assert.match(migration, /return '\(' \|\| v_prefilter \|\| '\) and \(' \|\| v_complete/);
  assert.match(migration, /built_sql not like '%c\.short_description ilike%'/);
  assert.match(migration, /field_key = '__keywords'[\s\S]*c\.keywords &&/);
  assert.match(migration, /field_key = '__technologies'[\s\S]*c\.technologies &&/);
  assert.match(migration, /v_complete := public\.company_effective_filter_sql_v1/g);
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

test("large filter sets travel in a body, not the request line", async () => {
  const [companies, prospects, transport] = await Promise.all([
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/dashboard-api.ts", import.meta.url), "utf8"),
  ]);
  // Bulk domains pastes up to 1000 values into one filter. Measured against
  // production: 400 domains is a 12.9KB URL and is accepted, 600 is 19.3KB and
  // Node answers 431 before any handler runs. Both listings must accept the same
  // query in a POST body, and the client must switch before reaching the wall.
  for (const route of [companies, prospects]) {
    assert.match(route, /export async function POST\(request: Request\)/);
    assert.match(route, /respondTo(Company|Prospect)Query/);
  }
  assert.match(transport, /export async function fetchCompanies/);
  assert.match(transport, /export async function fetchProspects/);
  const limit = Number(transport.match(/maxCompanyQueryUrlBytes = (\d+)/)?.[1]);
  assert.ok(limit > 0 && limit <= 12000, `URL switch threshold must stay under the 16KB wall, found ${limit}`);
});

test("company listing counts are bounded, but only when a filter narrows the set", async () => {
  const [migration, workspace] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260831200000_cap_company_listing_counts.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/components/CompaniesWorkspace.tsx", import.meta.url), "utf8"),
  ]);
  // Counting every match was ~98 percent of the request and grew with the data,
  // which is what pushed a cold description-scope filter past the timeout. The
  // page itself is cheap because it is ordered off an index.
  assert.match(migration, /limit %8\$s/);
  assert.match(migration, /total_capped/);
  // The unfiltered listing is the headline "how many companies do I have"
  // number. It must never be capped.
  assert.match(migration, /v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all'/);
  // And a bounded total has to read as a floor, not as an exact count.
  assert.match(workspace, /totalCapped \? `\$\{formatNumber\(total\)\}\+`/);
});
