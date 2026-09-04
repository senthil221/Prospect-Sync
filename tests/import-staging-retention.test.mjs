import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

const purge = () => read("../supabase/migrations/20260902000240_retire_company_import_staging.sql");
const scan = () => read("../supabase/migrations/20260902000250_apply_the_mx_scan_in_one_statement.sql");
const route = () => read("../app/api/email-providers/scan/route.ts");
const maintenance = () => read("../deploy/scripts/maintenance.sh");

// company_import_rows was 1,299 MB - the third-largest object in the database -
// with 4 sequential scans, zero index scans and no application code reading it.
// Three days is the agreed retention.
test("staging rows are retired by age", async () => {
  const statements = statementsOnly(await purge());

  assert.match(statements, /create or replace function public\.purge_company_import_rows_v1/i);
  assert.match(statements, /p_keep_days integer default 3/);
  assert.match(statements, /r\.imported_at < v_cutoff/);
});

// The safety property that matters. At the time of writing, 262,484 of 646,873
// staged rows belonged to nine imports still in 'processing' from six days
// earlier. Staging is the resume point for an unfinished import, so deleting it
// by age alone would turn a stalled import into an unrecoverable one.
test("rows of an unfinished import are never eligible, at any age", async () => {
  const statements = statementsOnly(await purge());

  assert.match(statements, /i\.status <> 'processing'/);
  // The age test and the status test are ANDed, not ORed.
  assert.match(statements, /where r\.imported_at < v_cutoff\s*\n\s*and i\.status <> 'processing'/);
});

// A single delete of several hundred thousand rows holds one transaction open
// long enough to stall autovacuum across the database.
test("the delete is batched and bounded", async () => {
  const statements = statementsOnly(await purge());

  assert.match(statements, /limit v_batch/);
  assert.match(statements, /exit when v_removed = 0;/);
  assert.match(statements, /exit when v_round > greatest\(1, coalesce\(p_max_batches, 200\)\);/);
});

// It deletes rows and nothing in the application needs it; maintenance.sh runs
// as postgres. Granting it to service_role would put a delete behind the API.
test("the purge is not reachable from the API", async () => {
  const statements = statementsOnly(await purge());

  assert.match(statements, /revoke execute on function public\.purge_company_import_rows_v1\(integer, integer, integer\) from public, anon, authenticated;/);
  assert.doesNotMatch(statements, /grant execute on function public\.purge_company_import_rows_v1[^;]*to service_role/);
});

test("maintenance runs the purge and surfaces stuck imports", async () => {
  const script = await maintenance();

  assert.match(script, /select public\.purge_company_import_rows_v1\(3\);/);
  // A stalled import keeps its staging, so it has to be reported or it is
  // invisible until someone wonders why the table is not shrinking.
  assert.match(script, /status = 'processing' and created_at < now\(\) - interval '2 days'/);
  assert.match(script, /vacuum \(analyze\) public\.company_import_rows;/);
});

// pg_stat_statements: 44,185 calls, mean 5 ms, total 224 s - one UPDATE per
// company, each a round trip and a transaction of its own.
test("an MX scan batch is applied in one statement", async () => {
  const statements = statementsOnly(await scan());

  assert.match(statements, /create or replace function public\.apply_email_provider_scan_v1/i);
  assert.match(statements, /from jsonb_to_recordset\(p_rows\) as scanned\(/);
  for (const column of ["esp text", "email_provider_type text", "mx_records text\\[\\]", "mx_status text", "mx_checked_at timestamptz"]) {
    assert.match(statements, new RegExp(column));
  }
  // The caller still reports what actually landed rather than assuming success.
  assert.match(statements, /get diagnostics v_updated = row_count;/);
  // An empty batch must not be an error.
  assert.match(statements, /jsonb_array_length\(p_rows\) = 0 then\s*\n\s*return 0;/);
});

test("the scan route writes once per batch, not once per company", async () => {
  const source = await route();

  assert.match(source, /supabase\.rpc\("apply_email_provider_scan_v1"/);
  // The per-company UPDATE is gone.
  assert.doesNotMatch(source, /supabase\.from\("companies"\)\.update\(/);
  // DNS lookups stay parallel - they are the honest cost and were never the problem.
  assert.match(source, /await Promise\.all\(companies\.map\(/);
  assert.match(source, /await lookupEmailProvider\(domain\)/);
  // A missing migration must say so rather than 500.
  assert.match(source, /applied\.error\.code === "PGRST202" \|\| applied\.error\.code === "42883"/);
});
