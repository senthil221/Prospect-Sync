import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { ESP_OUTCOMES, ESP_PROVIDERS, classifyMxRecords, lookupEmailProvider } from "../worker/email-provider-core.mjs";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const segMigration = "../supabase/migrations/20261003100000_client_seg_emails_and_esp_filters.sql";
const pullMigration = "../supabase/migrations/20261003110000_pull_master_people_for_companies.sql";

test("one provider list serves the scan, the worker and the ESP picker", async () => {
  const seg = ESP_PROVIDERS.filter((provider) => provider.category === "SEG").map((provider) => provider.name);
  for (const name of ["Mimecast", "Proofpoint", "Barracuda", "Cisco Secure Email"]) assert.ok(seg.includes(name), name);
  assert.ok(ESP_PROVIDERS.some((provider) => provider.name === "Google Workspace" && provider.category === "Mailbox provider"));
  assert.deepEqual(ESP_OUTCOMES, ["Custom / unknown", "No MX record", "Lookup failed"]);
  assert.equal(classifyMxRecords(["mx1.pphosted.com"]).category, "SEG");
  // The resolver is injected, so the module never imports node:dns itself.
  const found = await lookupEmailProvider("example.test", { resolveMx: async () => [{ exchange: "eu-smtp-inbound-1.mimecast.com", priority: 10 }] });
  assert.equal(found.esp, "Mimecast");
  const core = await read("../worker/email-provider-core.mjs");
  assert.doesNotMatch(core, /from ["']node:/);
  const lib = await read("../lib/email-provider.ts");
  assert.match(lib, /from "\.\.\/worker\/email-provider-core\.mjs"/);
});

test("a client keeps or discards SEG emails, and every client view carries the setting", async () => {
  const migration = await read(segMigration);
  assert.match(migration, /add column if not exists seg_emails text not null default 'keep'/);
  assert.match(migration, /check \(seg_emails in \('keep', 'discard'\)\)/);
  // Read when the query runs, so the compiled SQL is the same either way...
  assert.ok(migration.includes("(not (pi.email_provider_type = 'SEG' and (select coalesce(bool_or(s.seg_emails = 'discard'), false) from public.client_settings s where s.client_id = %L)))"));
  assert.ok(migration.includes("(not (c.email_provider_type = 'SEG' and (select coalesce(bool_or(s.seg_emails = 'discard'), false) from public.client_settings s where s.client_id = %L)))"));
  // ...and changing it moves the caches keyed on that SQL.
  assert.match(migration, /after insert or update of seg_emails on public\.client_settings/);
  for (const sequence of ["data_version_prospect", "data_version_company", "data_version_client_counts"]) {
    assert.ok(migration.includes(`perform nextval('public.${sequence}');`), sequence);
  }
  // Compilers and row matchers patched together, and proved to agree.
  for (const fn of ["prospect_filter_sql_v1", "prospect_index_matches_v1", "company_filter_sql_v3", "company_matches_filters_v1"]) {
    assert.ok(migration.includes(`pg_get_functiondef('public.${fn}(`), fn);
  }
  assert.match(migration, /SEG\/ESP proof passed and was rolled back/);
  // The Clients list and ICP checks follow the same rule.
  assert.match(migration, /- coalesce\(seg_people_counts\.prospect_count, 0\) as prospect_count/);
  assert.match(migration, /- coalesce\(seg_company_counts\.company_count, 0\) as company_count/);
  assert.ok(migration.includes("start_icp_strategy_check_v2(text,text,text,text,text[],text,jsonb,jsonb,text[],boolean,text,text)"));
  assert.ok(migration.includes("icp_strategy_scope_counts_v2(text,text)"));

  const helper = await read("../lib/client-workspace-completeness.ts");
  assert.match(helper, /export const clientSegPolicyField = "__client_seg_policy";/);
  const prospects = await read("../app/components/ProspectTable.tsx");
  assert.match(prospects, /filter\.field !== "__client_seg_policy"/);
});

test("the setting is edited in the client's Settings and validated by the API", async () => {
  const route = await read("../app/api/clients/[id]/route.ts");
  assert.match(route, /payload\.segEmails !== "keep" && payload\.segEmails !== "discard"/);
  assert.match(route, /upsert\(\{ client_id: id, seg_emails: payload\.segEmails/);
  const list = await read("../app/api/clients/route.ts");
  assert.match(list, /select\("client_id,cooldown_days,seg_emails"\)/);
  const panel = await read("../app/components/ClientsPanel.tsx");
  assert.match(panel, /JSON\.stringify\(\{ segEmails: next \}\)/);
  assert.match(panel, /className="seg-setting"/);
});

test("companies filter by ESP like people do, from one picker", async () => {
  const migration = await read(segMigration);
  assert.match(migration, /if field_key in \('__esp_type', '__esp', '__email_provider_type'\) then/);
  assert.match(migration, /when filter_item->>'field' in \('__esp_type', '__esp', '__email_provider_type'\) then \(/);
  const people = await read("../app/ApolloFilterPanel.tsx");
  assert.match(people, /\{ id: "__esp_type", label: "ESP", kind: "esp"/);
  assert.match(people, /export function EspFilter\(/);
  const companies = await read("../app/CompanyFilterPanel.tsx");
  assert.match(companies, /\{ id: "__esp_type", label: "ESP", kind: "esp"/);
  assert.match(companies, /<EspFilter filters=\{fieldFilters\}/);
});

test("the ICP worker scans MX records continuously and never marks a DNS outage as results", async () => {
  const worker = await read("../worker/icp-worker.mjs");
  assert.match(worker, /const mxScanner = mxScanLoop\(\);/);
  assert.match(worker, /public\.claim_mx_scan_batch_v2\(\$1\)/);
  assert.match(worker, /public\.apply_email_provider_scan_v2\(\$1::jsonb\)/);
  // The outage guard judges first-time lookups only, so retries of domains
  // that already failed can never stall the loop.
  assert.match(worker, /if \(fresh\.length && freshFailed > fresh\.length \/ 2\) \{/);
  const retry = await read("../supabase/migrations/20261005120000_retry_failed_mx_lookups.sql");
  assert.match(retry, /c\.mx_checked_at < now\(\) - interval '7 days'/);
  assert.match(retry, /limit greatest\(0, least\(coalesce\(p_limit, 100\), 500\) - \(select count\(\*\) from fresh\)\)/);
  assert.match(retry, /grant execute on function public\.claim_mx_scan_batch_v2\(integer\) to prospect_icp_validator/);
  assert.match(retry, /MX retry proof passed and was rolled back/);
  const migration = await read(segMigration);
  assert.match(migration, /where c\.normalized_domain <> '' and c\.mx_checked_at is null/);
  assert.match(migration, /grant execute on function public\.claim_mx_scan_batch_v1\(integer\) to prospect_icp_validator/);
  assert.match(migration, /grant execute on function public\.apply_email_provider_scan_v2\(jsonb\) to prospect_icp_validator/);
  for (const fn of ["claim_mx_scan_batch_v1(integer)", "apply_email_provider_scan_v2(jsonb)", "client_settings_seg_changed_v1()"]) {
    assert.ok(migration.includes(`revoke execute on function public.${fn} from public, anon, authenticated;`), fn);
  }
  const route = await read("../app/api/email-providers/scan/route.ts");
  assert.doesNotMatch(route, /reindexProspectsOfCompanies/);
});

test("a pull adds Master DB people at the client's companies, by job title only, through the push", async () => {
  const migration = await read(pullMigration);
  assert.match(migration, /\('__title', '__title_seniority', '__title_seniority_tier', '__title_department', '__title_sub_department'\)/);
  // The client's own companies, and the push's blocklist, batch and re-index.
  assert.match(migration, /from public\.resolve_company_action_selection_v1\(\s*p_client_id,/);
  assert.match(migration, /v_push := public\.push_prospects_to_client_v2\(\s*p_client_id, '', '\[\]'::jsonb, null, v_new, null/);
  assert.match(migration, /if not coalesce\(p_apply, false\) then\s*return v_counts;/);
  assert.match(migration, /people_pull_filters = excluded\.people_pull_filters/);
  assert.match(migration, /revoke execute on function public\.pull_master_people_v1\(text, text\[\], text, jsonb, jsonb, text\[\], jsonb, boolean, text, text\) from public, anon, authenticated;/);
  assert.match(migration, /Pull proof passed and was rolled back/);

  const route = await read("../app/api/clients/[id]/pull-people/route.ts");
  assert.match(route, /readIcpSelection\(id, body/);
  assert.match(route, /p_apply: action === "pull"/);
  const dialog = await read("../app/components/PullPeopleDialog.tsx");
  assert.match(dialog, /action: "preview"/);
  assert.match(dialog, /action: "pull", requestId: requestId\.current/);
  const companies = await read("../app/components/CompaniesWorkspace.tsx");
  assert.match(companies, /<PullPeopleDialog clientId=\{clientId\}/);
});
