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

test("deployment runs storage and one bounded import worker", async () => {
  const [compose, update, bootstrap, worker] = await Promise.all([
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../deploy/postgres/init/00-prospect-bootstrap.sh", import.meta.url), "utf8"),
    readFile(new URL("../worker/import-worker.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(compose, /import-worker:/);
  assert.match(compose, /cpus: "1\.0"/);
  assert.match(compose, /UPLOAD_FILE_SIZE_LIMIT: "1073741824"/);
  assert.match(update, /docker compose up -d db auth rest storage meta studio/);
  assert.match(update, /docker compose exec -T db bash -s < postgres\/init\/00-prospect-bootstrap\.sh/);
  assert.match(bootstrap, /export PGPASSWORD="\$\{POSTGRES_PASSWORD:\?POSTGRES_PASSWORD is required\}"/);
  assert.match(bootstrap, /create role prospect_importer nologin noinherit/i);
  assert.match(bootstrap, /grant prospect_importer to authenticator/i);
  assert.match(compose, /PGUSER: authenticator/);
  assert.match(worker, /copyFrom\("copy prospect_import\.staged_rows/);
  assert.match(worker, /process_staged_batch_v1/);
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
