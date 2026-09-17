import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const sqlOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");
const migration = () => read("../supabase/migrations/20260918120000_a_client_company_carries_its_own_prospect_count.sql");

// A client's company carries its own prospect count instead of the listing
// aggregating prospect_index on every request.
//
// Measured on production 2026-09-18, Unassigned (151,188 companies, 675,493
// people), same answer throughout:
//   before 20260918090000                 10,101 ms
//   after it (count stopped joining)       4,580 ms
//   with the stored count                    212 ms
test("the listing reads a stored column and no longer builds the client_counts CTE", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /alter table public\.client_companies\s+add column if not exists prospect_count integer not null default 0/);
  assert.match(sql, /v_prospect_expr := ''k\.prospect_count'';/);
  assert.match(sql, /join public\.client_companies k on k\.company_id = c\.id and k\.client_id = %L/);

  // The CTE must be gone from the function entirely, not merely unused: the
  // fast path added by 20260918090000 referenced it by name.
  assert.match(sql, /client_counts still appears in filter_companies_v4 after the rewrite/);
  assert.match(sql, /no longer contains the membership count source from 20260918090000/);
  assert.match(sql, /v_count_source := ''public\.client_companies k'';/);
});

// Ordering is the reason the index exists; the count is the reason it carries
// company_id.
test("the ranking index matches the order the listing asks for", async () => {
  const sql = sqlOnly(await migration());
  assert.match(sql, /create index if not exists idx_client_companies_ranking\s+on public\.client_companies \(client_id, prospect_count desc, company_id\)/);
});

// A delta would be cheaper and would drift. Recompute cannot.
test("freshness rides the existing statement trigger and recomputes rather than deltas", async () => {
  const sql = sqlOnly(await migration());

  // No new trigger: it is spliced into the one that already computes the
  // affected company ids once per statement.
  assert.doesNotMatch(sql, /create trigger/i,
    "this migration must not add a trigger; it extends the existing statement trigger");
  assert.match(sql, /perform public\.recompute_client_company_counts_bulk\(v_ids\);/);
  assert.match(sql, /sync_company_counts_statement no longer calls recompute_company_counts_bulk where expected/);
  assert.match(sql, /the client company recompute was not added to the statement trigger/);

  // Recompute from prospect_index, and skip pairs that did not change so a
  // large re-index does not bloat the table.
  assert.match(sql, /cc\.prospect_count is distinct from coalesce\(agg\.n, 0\)/);
});

// Both new functions are SECURITY DEFINER, so the migration guard requires
// same-file revokes. Asserted here too, because CI only sees changed files.
test("both new functions are locked down in the same file", async () => {
  const sql = sqlOnly(await migration());

  for (const fn of [
    "public.recompute_client_company_counts_bulk(text[])",
    "public.reconcile_client_company_counts_v1()",
  ]) {
    assert.ok(sql.includes(`revoke execute on function ${fn} from public, anon, authenticated;`),
      `${fn} must be revoked from public, anon and authenticated in this file`);
    assert.ok(sql.includes(`grant execute on function ${fn} to service_role;`),
      `${fn} must be granted to service_role in this file`);
  }
});

// The column must be provable against the table it is derived from, not just
// against itself.
test("drift is measured against prospect_index, in the migration and on demand", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /the backfill left % client\/company pairs disagreeing with prospect_index/);
  assert.match(sql, /create or replace function public\.reconcile_client_company_counts_v1/);
  // It returns what it found, so a maintenance run can print a number.
  assert.match(sql, /returns integer/);
  assert.match(sql, /return v_drift;/);

  // The per-client equivalence compares against prospect_index rather than the
  // new column, or it would only prove the column agrees with itself.
  assert.match(sql, /listing counted % companies, membership has %/);
  assert.match(sql, /listing reported % covered, prospect_index says %/);
  assert.match(sql, /listing summed % people, prospect_index has %/);
});

// client_count moved out of the removed CTE and must still be right per row.
test("the page still reports client_count, proved row by row", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /v_client_expr := format\(\$ce\$\(select count\(distinct cid\)::integer/);
  assert.match(sql, /company % reported % clients, prospect_index says %/);
  assert.match(sql, /company % reported % people, prospect_index says %/);
});

// A recompute cannot drift on a path the trigger fires for. A path that never
// fires it would go unnoticed, so maintenance checks the whole table.
test("maintenance reconciles the stored counts and expects zero drift", async () => {
  const script = (await read("../deploy/scripts/maintenance.sh"))
    .split(/\r?\n/).filter((line) => !line.trimStart().startsWith("#")).join("\n");

  assert.match(script, /select public\.reconcile_client_company_counts_v1\(\);/);
  assert.match(script, /0 pairs drifted - the stored counts match prospect_index/);
  // Non-zero must read as a finding, not a routine line.
  assert.match(script, /a write path is not reaching the trigger, worth investigating/);
  assert.match(script, /reconcile function not present - skipping/);
});

// The trigger is the part that can rot silently, so it is exercised on a real
// row and rolled back.
test("a prospect changing company moves both counts, proved and rolled back", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /update public\.prospect_index set company_id = v_to where id = v_prospect;/);
  assert.match(sql, /moving a prospect off company % left its count at %, expected %/);
  assert.match(sql, /moving a prospect onto company % left its count at %, expected %/);
  assert.match(sql, /errcode = 'ZZ999'/);
  assert.match(sql, /when sqlstate 'ZZ999' then/);
});
