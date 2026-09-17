import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const sqlOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");
const migration = () => read("../supabase/migrations/20260917050000_a_company_stays_in_the_client_after_its_people_leave.sql");

// A company stays in its client's Company DB once the last of that client's
// people leaves it. 20260916180000 claimed this and asserted the wrong thing:
// it checked that the client_companies row survived, which it does, while the
// listing never read that table at all.
//
// Measured on production 2026-09-17 - rows present in client_companies and
// invisible to their own client: 823 in total, 151 of them in Krishify.
test("the client listing scopes by membership, not by whether people are left", async () => {
  const sql = sqlOnly(await migration());

  // The old scope is gone and the new one is in.
  assert.match(sql, /select 1 from public\.client_companies retained/);
  assert.match(sql, /retained\.company_id = c\.id and retained\.client_id = %L/);

  // The splice refuses rather than patching blindly, in both directions: the
  // anchor must be present, and the old predicate must be gone afterwards.
  assert.match(sql, /filter_companies_v4 no longer contains the prospect_index client scope/);
  assert.match(sql, /the membership scope replacement did not take/);
  assert.ok(sql.includes("position('scoped.client_ids @> array[%L]' in v_def) > 0"),
    "the splice must verify the old people-based scope is gone, not merely that the new one arrived");
});

// The whole change rests on client_companies being a superset of "has people
// here". If that ever stopped holding, a company with real people would vanish
// from its client - worse than the bug being fixed.
test("the superset invariant is asserted before anything is rewritten", async () => {
  const sql = sqlOnly(await migration());

  const invariantAt = sql.indexOf("client_companies is not a superset of held people");
  const firstSpliceAt = sql.indexOf("pg_get_functiondef('public.filter_companies_v4'");
  assert.ok(invariantAt > 0, "the drift check must exist");
  assert.ok(invariantAt < firstSpliceAt,
    "the invariant must be checked before the functions are rewritten, not after");
  assert.match(sql, /have people but no membership row/);
});

// A listing that shows companies its own bulk bar refuses is the failure this
// pair of edits exists to prevent, so both resolvers move in the same file.
test("both selection resolvers drop the added_by guard alongside the listing", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /resolve_company_action_selection_v1 no longer contains the added_by guard/);
  assert.match(sql, /resolve_client_company_selection_v1 no longer contains the added_by guard/);
  // Both splices verify the guard is actually gone afterwards.
  assert.equal((sql.match(/the added_by guard survived the replacement/g) ?? []).length, 2,
    "each resolver splice must confirm the guard is gone");

  // And the pair is proved equal on a real row rather than asserted.
  assert.match(sql, /but the action resolver refuses it; the grid would contradict its own bulk bar/);
});

// The asymmetry is the requirement. It must hold in both directions, and the
// company direction is the one that would silently break if membership became
// authoritative without a delete behind it.
test("the two removal directions are proved on real rows and rolled back", async () => {
  const sql = sqlOnly(await migration());

  assert.match(sql, /removing company % from client % left its membership row/);
  assert.match(sql, /the two directions are not meant to be symmetric/);

  // Rolled back via the sentinel, not left behind.
  assert.equal((sql.match(/errcode = 'ZZ999'/g) ?? []).length, 2,
    "each removal probe must roll itself back");
  assert.equal((sql.match(/when sqlstate 'ZZ999' then/g) ?? []).length, 2);

  // The probe picks the smallest company on purpose - it really re-indexes
  // before it rolls back.
  assert.match(sql, /order by count\(\*\) asc/);

  // Widening must not have replaced the old set, only grown it.
  assert.match(sql, /has people in client % and dropped out of the listing/);
});

// Every description of this feature promises the master records are untouched.
test("the rewritten functions only ever read", async () => {
  const sql = sqlOnly(await migration());
  assert.match(sql, /a listing or resolver gained a delete; these functions only ever read/);
  for (const fn of ["filter_companies_v4", "resolve_company_action_selection_v1", "resolve_client_company_selection_v1"]) {
    assert.ok(sql.includes(`pg_get_functiondef('public.${fn}'::regproc) like '%delete from%'`),
      `${fn} must be checked for a delete`);
  }
});

// The company side is what deletes the membership row. If that ever went away,
// making membership authoritative would mean no company could leave a client.
test("company removal still deletes the membership row explicitly", async () => {
  const sql = sqlOnly(await read("../supabase/migrations/20260916180000_a_company_leaves_a_client_with_its_people.sql"));
  assert.match(sql, /delete from public\.client_companies/);
  assert.match(sql, /where client_id = p_client_id and company_id = any\(v_company_ids\)/);
});
