import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { csvRows, uniqueHeaders } from "../worker/csv-stream.mjs";

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

test("background import migration uses leases, skip-locked claiming and service-role-only RPCs", async () => {
  const sql = await readFile(new URL("../supabase/migrations/20260825151254_durable_background_prospect_imports.sql", import.meta.url), "utf8");
  assert.match(sql, /for update skip locked/i);
  assert.match(sql, /lease_expires_at/i);
  assert.match(sql, /where ingestion_mode = 'background' and status in \('queued', 'processing'\)/i);
  assert.match(sql, /revoke execute on function public\.claim_next_prospect_import_v1[\s\S]*from public, anon, authenticated/i);
  assert.match(sql, /grant execute on function public\.claim_next_prospect_import_v1[\s\S]*to service_role/i);
});

test("deployment runs storage and one bounded import worker", async () => {
  const [compose, update, worker] = await Promise.all([
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../worker/import-worker.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(compose, /import-worker:/);
  assert.match(compose, /cpus: "0\.75"/);
  assert.match(compose, /UPLOAD_FILE_SIZE_LIMIT: "1073741824"/);
  assert.match(update, /docker compose up -d db auth rest storage meta studio/);
  assert.match(worker, /Math\.min\(250/);
  assert.match(worker, /rows\.length > 25/);
});
