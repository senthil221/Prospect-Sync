import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
// The migration explains the bug it fixes by quoting the code it replaces, so
// absence checks have to look at the SQL rather than the prose.
const sqlOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");

// Removing a company from a client takes that client's people with it.
// Removing a person never takes the company. The asymmetry is the requirement.
test("a company leaves a client with its people, and a person never takes the company", async () => {
  const migration = await read("../supabase/migrations/20260916180000_a_company_leaves_a_client_with_its_people.sql");
  const sql = sqlOnly(migration);

  // People first, then the membership row. Order matters: the membership is
  // what keeps the company listed, and nothing else removes it -
  // sync_client_company_membership does not fire on delete.
  assert.ok(sql.indexOf("remove_prospects_from_client_v2(\n      p_client_id => p_client_id") < sql.indexOf("delete from public.client_companies"),
    "people must be removed before the company membership row");
  assert.match(sql, /delete from public\.client_companies\s*\n\s*where client_id = p_client_id and company_id = any\(v_company_ids\)/);

  // Scoped to this client's people only - another client's people at the same
  // company are not in the set at all.
  assert.match(sql, /pi\.client_ids @> array\[p_client_id\]/);

  // NOTHING IS DELETED. This is the contract the whole feature rests on, and
  // the migration proves it on real rows rather than asserting it in prose.
  assert.doesNotMatch(sql, /delete from public\.companies/);
  assert.doesNotMatch(sql, /delete from public\.prospects\b/);
  assert.match(sql, /'masterRecordsPreserved', true/);
  assert.match(sql, /the company was deleted from the master database/);
  assert.match(sql, /prospects were deleted from the master database/);

  // The reverse direction is asserted, not assumed.
  assert.match(sql, /removing a person removed its company from the client/);
});

// The probe removes real rows and must put them all back.
//
// migrate.sh wraps each file in one transaction and COMMITS it, so an assertion
// that removed a real company from a real client would be a migration that took
// production data with it.
test("the migration's destructive probe rolls itself back", async () => {
  const migration = await read("../supabase/migrations/20260916180000_a_company_leaves_a_client_with_its_people.sql");
  const sql = sqlOnly(migration);

  // A sentinel SQLSTATE, so a genuine failure inside the block is NOT caught by
  // the rollback handler and still aborts the migration.
  assert.match(sql, /raise exception using errcode = 'ZZ999', message = 'probe-rollback'/);
  assert.match(sql, /exception when sqlstate 'ZZ999' then/);
  const raises = sql.match(/errcode = 'ZZ999'/g) ?? [];
  const handlers = sql.match(/when sqlstate 'ZZ999' then/g) ?? [];
  assert.equal(raises.length, handlers.length, "every rollback sentinel needs exactly one handler");
  assert.ok(raises.length >= 2, "both probes must roll back");

  // And it checks the rollback actually happened, rather than trusting it.
  assert.match(sql, /the probe did not roll back; the client lost people/);
  assert.match(sql, /the probe did not roll back; the client lost a company membership/);
});

// The preview cannot write, and the cap refuses rather than truncating.
test("the removal is previewed before it happens and capped when it is too big", async () => {
  const [migration, route, workspace] = await Promise.all([
    read("../supabase/migrations/20260916180000_a_company_leaves_a_client_with_its_people.sql"),
    read("../app/api/clients/[id]/companies/route.ts"),
    read("../app/components/CompaniesWorkspace.tsx"),
  ]);
  const sql = sqlOnly(migration);

  // STABLE by declaration, and the migration asserts the catalogue agrees -
  // a preview that can write is not a preview.
  assert.match(sql, /create or replace function public\.client_company_removal_preview_v1[\s\S]{0,400}?\bstable\b/);
  assert.match(migration, /a preview that can write is not a preview/);

  // Refused, never truncated: removing 49,999 of 60,000 and reporting success
  // is neither what was asked for nor obviously wrong afterwards.
  assert.match(sql, /errcode = '54000'/);
  assert.match(sql, /above the %s limit/);
  assert.match(sql, /the people cap did not refuse an over-limit removal/);
  // A refusal must leave everything where it was.
  assert.match(sql, /a refused removal still took % people/);

  // The ceiling reaches the user as "narrow your selection", not a 500.
  assert.match(route, /code: "too_many_people"/);
  assert.match(route, /status: 413/);

  // The preview and the removal are given the identical selection, so the
  // confirmation cannot describe a different set from the one that is acted on.
  assert.match(route, /const selectionArgs = \{/);
  assert.match(workspace, /function companySelectionPayload\(\)/);
  assert.match(workspace, /action: "remove_preview", \.\.\.companySelectionPayload\(\)/);
  assert.match(workspace, /action: "remove", \.\.\.companySelectionPayload\(\)/);

  // The confirmation names both numbers, which is the entire reason the preview
  // exists - one company can carry hundreds of people.
  assert.match(workspace, /will be taken out of this client too/);
  assert.match(workspace, /Nothing is deleted/);
});

// The count this feature is specified in terms of had never been right.
test("removing prospects from a client reports what it actually removed", async () => {
  const migration = await read("../supabase/migrations/20260916180000_a_company_leaves_a_client_with_its_people.sql");
  const sql = sqlOnly(migration);

  // trg_client_prospects_delete on list_memberships runs
  // sync_client_prospects_from_lists(), which takes the client_prospects rows
  // with it - so the function's own DELETE finds nothing and row_count is 0.
  // Measured on production: 19 prospects, client_prospects 19 -> 0, and
  // {"removed": 0}. Counted before and after instead, so it no longer matters
  // which statement did the work.
  assert.match(sql, /select count\(\*\) into v_linked_before/);
  assert.match(sql, /select count\(\*\) into v_linked_after/);
  assert.match(sql, /v_removed := greatest\(0, v_linked_before - v_linked_after\)/);
  // The old shape must not come back.
  assert.doesNotMatch(sql, /delete from public\.client_prospects[\s\S]{0,120}?get diagnostics v_removed = row_count/);

  // Same signature, so every existing caller keeps working.
  assert.match(sql, /create or replace function public\.remove_prospects_from_client_v2\(/);
  assert.match(sql, /revoke execute on function public\.remove_prospects_from_client_v2[^\n]*from public, anon, authenticated/);
});

// Remove and Delete are different words, different buttons, different dialogs.
test("removing from a client is never presented as deleting", async () => {
  const [people, companies] = await Promise.all([
    read("../app/components/ProspectTable.tsx"),
    read("../app/components/CompaniesWorkspace.tsx"),
  ]);

  // People: the client workspace gets Remove, and never the master Delete.
  assert.match(people, /clientId \? <div className="bulk-action-group bulk-action-group-danger">/);
  assert.match(people, /const canDeleteMaster = !clientId;/);
  assert.match(people, /The People database records are preserved/);
  assert.match(people, /The People database records are unchanged/);

  // Companies: same, and the master Delete stays gated on being outside a client.
  assert.match(companies, /const canDelete = !clientId;/);
  assert.match(companies, /Remove company \+ its people from client/);
  assert.match(companies, /The Company and People databases are unchanged/);
});
