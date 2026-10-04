import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { csvRows, uniqueHeaders } from "../worker/csv-stream.mjs";
import { mapProspect as mapWorkerProspect } from "../worker/prospect-map.mjs";
import { mapProspect as mapAppProspect } from "../db/normalize.ts";

function chunkedStream(parts) {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const part of parts) controller.enqueue(encoder.encode(part));
      controller.close();
    },
  });
}

test("streaming CSV parser preserves quoted commas, newlines and split escaped quotes", async () => {
  const rows = [];
  for await (const row of csvRows(chunkedStream([
    "\uFEFFName,Company,Note\r\nJane,Acme,\"hello, ",
    "world\"\r\nJohn,Example,\"line one\nline two and a \"",
    "\"quote\"\"\"\r\n",
  ]))) rows.push(row);
  assert.deepEqual(rows, [
    ["Name", "Company", "Note"],
    ["Jane", "Acme", "hello, world"],
    ["John", "Example", "line one\nline two and a \"quote\""],
  ]);
});
test("worker header normalization matches browser duplicate-header behavior", () => {
  assert.deepEqual(uniqueHeaders([" Email ", "email", "", "Email"]), ["Email", "email (2)", "Column 3", "Email (3)"]);
});

test("COPY worker mapping stays identical to the application import mapping", () => {
  const headers = ["Name", "Email", "Personal Email", "LinkedIn URL", "Company", "Website", "Keywords", "Employees", "Location"];
  const values = [" Ada Lovelace ", "ADA@EXAMPLE.COM", "ada@home.test", "https://linkedin.com/in/ada/?trk=1", "Analytical Engines", "https://www.example.com/path", "Math; Computing; math", "51-200", "London, UK"];
  assert.deepEqual(mapWorkerProspect(headers, values), mapAppProspect(headers, values));
});

test("background import migration uses leases, skip-locked claiming and service-role-only RPCs", async () => {
  const sql = await readFile(new URL("../supabase/migrations/20260825151254_durable_background_prospect_imports.sql", import.meta.url), "utf8");
  assert.match(sql, /for update skip locked/i);
  assert.match(sql, /lease_expires_at/i);
  assert.match(sql, /where ingestion_mode = 'background' and status in \('queued', 'processing'\)/i);
  assert.match(sql, /revoke execute on function public\.claim_next_prospect_import_v1[\s\S]*from public, anon, authenticated/i);
  assert.match(sql, /grant execute on function public\.claim_next_prospect_import_v1[\s\S]*to service_role/i);
});

test("fenced background imports publish temporary COPY rows through a rotating claim", async () => {
  const sql = await readFile(new URL("../supabase/migrations/20261004145556_fence_background_prospect_imports.sql", import.meta.url), "utf8");
  assert.match(sql, /import_protocol_version smallint not null default 1/i);
  assert.match(sql, /claim_token uuid/i);
  assert.match(sql, /for update skip locked/i);
  assert.match(sql, /p_temp_table regclass/i);
  assert.match(sql, /relpersistence <> 't'/i);
  assert.match(sql, /source_fingerprint/i);
  assert.match(sql, /IMPORT_CLAIM_LOST/i);
  assert.match(sql, /committed_row_offset<>v_import\.total_rows/i);
  assert.match(sql, /revoke all on prospect_import\.staged_rows_v2[\s\S]*prospect_importer/i);
  assert.doesNotMatch(sql, /grant (?:select|insert|update|delete)[^;]*staged_rows_v2/i);
});

test("background import API opts into v2 without exposing claim credentials", async () => {
  const [startRoute, detailRoute] = await Promise.all([
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/[id]/route.ts", import.meta.url), "utf8"),
  ]);
  assert.match(startRoute, /import_protocol_version: payload\.background === true \? 2 : 1/);
  assert.match(detailRoute, /cancel_background_prospect_import_v2/);
  assert.match(detailRoute, /requeue_background_prospect_import_v2/);
  const getSelect = detailRoute.match(/\.select\("id,client_id,list_id[^\n]+/u)?.[0] ?? "";
  assert.doesNotMatch(getSelect, /claim_token|completion_receipt/i);
  assert.match(detailRoute, /setTimeout\(resolve, 5_000\)/);
});

test("deployment runs storage and one bounded import worker", async () => {
  const [compose, update, bootstrap, worker, concurrencyHarness] = await Promise.all([
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../deploy/postgres/init/00-prospect-bootstrap.sh", import.meta.url), "utf8"),
    readFile(new URL("../worker/import-worker.mjs", import.meta.url), "utf8"),
    readFile(new URL("../scripts/test-import-fencing-concurrency.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(compose, /import-worker:/);
  assert.match(compose, /cpus: "1\.0"/);
  assert.match(compose, /UPLOAD_FILE_SIZE_LIMIT: "1073741824"/);
  assert.match(update, /docker compose up -d db auth rest storage meta studio/);
  assert.match(update, /docker compose exec -T -e VERIFICATION_WORKER_DB_PASSWORD db bash -s < postgres\/init\/00-prospect-bootstrap\.sh/);
  assert.match(bootstrap, /export PGPASSWORD="\$\{POSTGRES_PASSWORD:\?POSTGRES_PASSWORD is required\}"/);
  assert.match(bootstrap, /create role prospect_importer nologin noinherit/i);
  assert.match(bootstrap, /grant prospect_importer to authenticator/i);
  // migrate.sh connects as postgres and CREATE OR REPLACE FUNCTION needs
  // ownership, so anything created through Studio (which connects as
  // supabase_admin) has to be handed back before migrations run - while leaving
  // extension members like pg_trgm alone.
  assert.match(bootstrap, /alter %s owner to postgres/i);
  assert.match(bootstrap, /deptype = 'e'/);
  assert.match(bootstrap, /still owned by supabase_admin/i);
  // The worker used to share authenticator with PostgREST, which made per-role
  // connection limits useless and handed it service_role. It has its own login
  // now; see tests/pool-collapse-protection.test.mjs.
  assert.match(compose, /PGUSER: prospect_import_worker/);
  assert.doesNotMatch(compose, /PGUSER: authenticator/);
  // One slow listing holds a pool connection for its whole run, so a pool this
  // small let a single expensive filter starve every other request with
  // "Timed out acquiring connection from connection pool". Keep the slack.
  const pool = Number(compose.match(/PGRST_DB_POOL: "(\d+)"/)?.[1]);
  assert.ok(pool >= 24, `PGRST_DB_POOL must stay >= 24 for headroom, found ${pool}`);
  assert.match(compose, /PGRST_DB_POOL_ACQUISITION_TIMEOUT: "10"/);
  assert.match(worker, /copyFrom\("copy prospect_import_stage_buffer/);
  assert.match(worker, /publish_temp_stage_v2/);
  assert.match(worker, /process_staged_batch_v2/);
  assert.match(worker, /complete_claim_v2/);
  assert.match(worker, /query_timeout: 10_000/);
  assert.match(worker, /bindAbortToPgSession\(mergeClient, jobAbort\.signal\)/);
  assert.match(worker, /createRenewalTransport\(jobAbort\.signal\)/);
  assert.match(worker, /detachClientAbort = bindAbortToPgSession\(client, shutdownSignal\)/);
  assert.match(worker, /Promise\.all\(\[renewalTransport\?\.close\(\), detachMergeAbort\(\)\]\)/);
  assert.match(worker, /const shutdownRetryBudgetMs = 6_000/);
  assert.match(worker, /application_name: "prospect-import-worker-shutdown-release"/);
  assert.match(worker, /connectionTimeoutMillis: 1_000/);
  assert.match(worker, /bindAbortToPgSession\(client, deadline\.signal, 250\)/);
  assert.match(worker, /backend_start::text backend_start,usename,application_name[\s\S]*where pid=pg_backend_pid\(\)/u);
  assert.match(worker, /pg_cancel_backend\(a\.pid\)[\s\S]*a\.pid=\$1 and a\.backend_start=\$2::timestamptz[\s\S]*a\.usename=\$3 and a\.application_name=\$4/u);
  assert.match(worker, /a\.pid<>pg_backend_pid\(\)/u);
  assert.doesNotMatch(worker, /grant\s+pg_signal_backend/i);
  assert.doesNotMatch(worker, /security definer\s+(?:set|as)/i);
  assert.match(worker, /statement_timeout='4500ms'; set lock_timeout='4s'/);
  assert.match(worker, /query_timeout: 4_750/);
  assert.match(worker, /if \(stopping\) \{[\s\S]*Shutdown retry budget expired/u);
  assert.match(worker, /await importerClient[\s\S]*await failOrRetry/u);
  assert.match(concurrencyHarness, /shutdown did not roll back and release the active batch:[\s\S]*diagnosticWorkerOutput\(\)/u);
  assert.match(concurrencyHarness, /diagnosticWorkerOutput[\s\S]*\[redacted\]/u);
  assert.match(update, /pause_or_restore_fenced_import_worker/);
  assert.match(update, /FENCED_IMPORT_WORKER_IMAGE_FILE/);
});

test("both rollback paths pause an unsafe import worker without claiming the app is fully ready", async () => {
  const [update, health, compose] = await Promise.all([
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../app/api/health/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
  ]);
  assert.match(update, /rollback_on_error\(\)[\s\S]*pause_or_restore_fenced_import_worker/u);
  assert.match(update, /image_has_fenced_import_worker "\$NEW_IMAGE"[\s\S]*pause_or_restore_fenced_import_worker/u);
  assert.match(update, /docker compose stop import-worker/u);
  assert.match(health, /const workerChecks = \{ importWorker: checkImportWorker \}/u);
  assert.match(health, /status: degraded\.length \? "degraded" : "ok"/u);
  assert.match(health, /const failed = coreEntries/u);
  assert.match(compose, /reports a paused import worker as degraded/u);
});

test("fast import staging is private and reuses the active resumable importer", async () => {
  const sql = await readFile(new URL("../supabase/migrations/20260826031412_fast_copy_prospect_imports.sql", import.meta.url), "utf8");
  assert.match(sql, /create schema if not exists prospect_import/i);
  assert.match(sql, /revoke all on schema prospect_import from public, anon, authenticated/i);
  assert.match(sql, /prospect_importer role is missing/i);
  assert.match(sql, /from public\.import_prospect_batch_v5\(p_import_id, p_list_id, rows_payload, p_row_offset\)/i);
  assert.match(sql, /delete from prospect_import\.staged_rows[\s\S]*between first_offset and last_offset/i);
  assert.doesNotMatch(sql, /grant .* to (anon|authenticated)/i);
});
