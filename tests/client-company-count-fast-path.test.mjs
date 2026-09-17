import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const sqlOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");
const shellOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("#")).join("\n");
const migration = () => read("../supabase/migrations/20260918090000_an_unfiltered_client_company_count_reads_the_membership_table.sql");

// An unfiltered client Company DB counts membership rows instead of probing
// every company's primary key.
//
// Measured on production 2026-09-18, Unassigned (151,188 of 160,543 rows):
//   counted CTE alone            977 ms, 559,931 of 561,031 buffers in the probe
//   the same count by membership  17 ms
//   filter_companies_v4 overall  10,101 ms -> 2,418 ms
test("the count reads client_companies, and the page still reads companies", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /public\.client_companies cc left join client_counts k on k\.company_id = cc\.company_id/);
  assert.match(sql, /cc\.client_id = %L/);

  // Only the count changed. If the page stopped reading companies it would lose
  // the name and domain it renders.
  assert.match(sql, /the page query stopped reading public\.companies; only the count was meant to change/);
});

// The rewrite depends entirely on the foreign key: without it a membership row
// could outlive its company and the two counts would diverge.
test("the foreign key the rewrite depends on is asserted, not assumed", async () => {
  const sql = sqlOnly(await migration());

  const fkAt = sql.indexOf("client_companies has no foreign key to companies");
  const spliceAt = sql.indexOf("pg_get_functiondef('public.filter_companies_v4'");
  assert.ok(fkAt > 0, "the FK check must exist");
  assert.ok(fkAt < spliceAt, "the FK must be checked before the function is rewritten");
  assert.match(sql, /confrelid = 'public\.companies'::regclass/);
});

// The guard has to be narrow: anything that mentions the companies row in the
// predicate cannot be answered by counting membership.
test("the fast path is gated on a client, no people scope, and an empty filter", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /if p_client_id is not null/);
  assert.match(sql, /and p_people_scope is null/);
  assert.match(sql, /and btrim\(v_counting_clause\) = ''true''/);

  // The default keeps the existing plan, so anything outside the guard is
  // unchanged rather than merely untested.
  assert.match(sql, /v_count_source := ''public\.companies c'' \|\| v_join;/);
  assert.match(sql, /v_count_pred := v_where_counting;/);
});

// A format() string that references a placeholder it was not given fails at
// runtime, not at create time, so all four edits must land together.
test("declaration, assignment, template and argument list are one rewrite", async () => {
  const sql = sqlOnly(await migration());

  for (const guard of [
    "no longer declares v_where_counting where expected",
    "no longer assigns v_where_counting where expected",
    "no longer contains the counted CTE this migration rewrites",
    "no longer passes the format arguments this migration extends",
  ]) {
    assert.ok(sql.includes(guard), `the splice must refuse when: ${guard}`);
  }

  assert.match(sql, /v_count_source, v_count_pred\);/);
  assert.match(sql, /the membership-count replacement did not take/);
});

// Proved against both the number it now reads and the number it replaces, for
// every client rather than a sampled one.
test("the fast path is proved equal to the join it replaces, per client", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /for v_client in select id, name from public\.clients order by id loop/);
  assert.match(sql, /the foreign key is not holding/);
  assert.match(sql, /the function returned % where the join counts %/);

  // The other two aggregates still come from client_counts and must not have
  // been dropped along with the companies scan.
  assert.match(sql, /covered_count or prospect_total went null when the count changed source/);
  assert.match(sql, /covered_count % exceeds total_count %/);

  // And a filtered request must not take it, or the filter would be ignored.
  assert.match(sql, /the fast path firing when it must not/);
});

// client_companies had never been vacuumed, so its "index only" scans were
// hitting the heap for every row.
test("maintenance vacuums client_companies so its index-only scans stay index-only", async () => {
  const script = shellOnly(await read("../deploy/scripts/maintenance.sh"));

  assert.match(script, /vacuum \(analyze\) public\.client_companies;/);
  assert.match(script, /relname = 'client_companies'/);
  // Reported rather than silent, in the style of the import-rows vacuum above it.
  assert.match(script, /dead tuple\(s\) before/);
  assert.match(script, /visibility map refreshed/);
  // Absent table must skip rather than fail the whole maintenance run.
  assert.match(script, /client_companies not present - skipping/);
});
