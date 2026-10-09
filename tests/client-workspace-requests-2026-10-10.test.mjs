import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseFilters } from "../lib/prospect-filters.ts";
import { usesChip } from "../lib/dashboard-helpers.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// The seven asks of 2026-10-10.
test("0. Pull people accepts Top management, in the database and the dialog", async () => {
  const sql = await read("../supabase/migrations/20261010090000_pull_top_management_blocklist_reason_contactable_email.sql");
  assert.match(sql, /'__title_department', '__title_sub_department',\s+'__title_top_management'\)/);
  assert.match(await read("../app/api/clients/[id]/pull-people/route.ts"), /"__title_sub_department", "__title_top_management"\]\)/);
  assert.match(await read("../app/components/PullPeopleDialog.tsx"), /<TopManagementFilter filters=\{all\.filter\(\(filter\) => topManagementFields\.has\(filter\.field\)\)\}/);
});

test("1. The blocklist filters by reason through the shared selection function", async () => {
  const sql = await read("../supabase/migrations/20261010090000_pull_top_management_blocklist_reason_contactable_email.sql");
  assert.match(sql, /and \(f\.reason is null or b\.reason = case f\.reason when '\(none\)' then '' else f\.reason end\)/);
  const route = await read("../app/api/clients/[id]/blocklist/route.ts");
  assert.match(route, /p_kind: reasonFilter \? `\$\{kind\}\|\$\{reasonFilter\}` : kind/);
  assert.match(route, /query = query\.eq\("reason", filters\.reasonFilter === "\(none\)" \? "" : filters\.reasonFilter\)/);
  assert.match(await read("../app/components/BlocklistPanel.tsx"), /aria-label="Filter blocklist reason"/);
});

test("5. Contactable requires a work email in both filter paths", async () => {
  const sql = await read("../supabase/migrations/20261010090000_pull_top_management_blocklist_reason_contactable_email.sql");
  assert.match(sql, /and btrim\(coalesce\(pi\.work_email, ''\)\) <> ''/);
  assert.match(sql, /and btrim\(coalesce\(\(p_row\)\.work_email, ''\)\) <> ''/);
  assert.match(sql, /contactable people have no email/);
});

test("4. Number of Uses counts Date Contacted changes, filters and shows per client", async () => {
  const sql = await read("../supabase/migrations/20261010100000_client_prospect_number_of_uses.sql");
  assert.match(sql, /new\.date_added is not null and new\.date_added is distinct from old\.date_added then\s+new\.use_count := coalesce\(old\.use_count, 0\) \+ 1;/);
  assert.match(sql, /before insert or update of date_added on public\.client_prospects/);
  assert.match(sql, /cp\.use_count as client_use_count,/);
  assert.match(sql, /cp\.use_count < %s/);
  assert.deepEqual(parseFilters(JSON.stringify([{ field: "__client_use_count", operator: "equals", values: ["c1", "3"] }])),
    [{ field: "__client_use_count", operator: "equals", values: ["c1", "3"] }]);
  assert.throws(() => parseFilters(JSON.stringify([{ field: "__client_use_count", operator: "equals", values: ["c1", "x"] }])), /Number of Uses/);
  assert.equal(usesChip(["c1", "1"]), "Never used");
  assert.equal(usesChip(["c1", "3"]), "Fewer than 3 uses");
  assert.match(await read("../app/components/ProspectTableRow.tsx"), /\{Number\(prospect\.client_use_count \?\? 0\)\}/);
});

test("6. A blocked domain blocks its email domain everywhere, never for free mail", async () => {
  const sql = await read("../supabase/migrations/20261010110000_blocked_domains_block_email_domains.sql");
  assert.match(sql, /create or replace function public\.email_domain_v1\(p_email text\)/);
  for (const fn of ["add_client_blocklist_v1", "apply_client_blocklist_v1", "remove_client_blocklist_v1", "push_prospects_to_client_v1", "push_prospects_to_client_v2", "pull_master_people_v1"]) {
    assert.ok(sql.includes(`'${fn}'`), fn);
  }
  assert.match(sql, /add_client_blocklist_batch_v2\(text,text\[\],text\[\],text,text,text,integer\)/);
  assert.match(sql, /client_block_reason_v1\(text,text\)/);
  assert.match(sql, /not public\.is_free_email_domain_v1\(b\.value\)/);
  assert.match(sql, /Email domain proof passed/);
});

test("2+3. FITs get the ICP tag; the ICP Invalid blocklist can be re-checked and lifted", async () => {
  const sql = await read("../supabase/migrations/20261010120000_icp_fit_tags_and_blocklist_recheck.sql");
  assert.match(sql, /add column if not exists applied_tagged boolean/);
  assert.match(sql, /insert into public\.company_tag_links \(company_id, tag_id\)/);
  assert.match(sql, /insert into public\.prospect_tag_links \(prospect_id, tag_id\)/);
  assert.match(sql, /b\.value = r->>'domain' and b\.reason = 'ICP Invalid'\n\s+where r->>'verdict' = 'FIT'/);
  assert.match(sql, /'all', 'unchecked', 'selection', 'unverified', 'blocklisted'/);
  assert.match(sql, /set apply_pending = true\n\s+from public\.icp_strategy_checks k\n\s+where k\.id = s\.check_id and s\.verdict = 'FIT' and s\.applied = 'FIT' and not s\.applied_tagged/);
  assert.match(await read("../app/api/icp-checks/route.ts"), /"selection", "blocklisted"\]\)/);
  const dialog = await read("../app/components/IcpInvalidRecheckDialog.tsx");
  assert.match(dialog, /scope: "blocklisted", autoApply: true/);
  assert.match(await read("../app/components/BlocklistPanel.tsx"), />Re-check ICP Invalid<\/button>/);
});
