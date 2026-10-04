import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  clientSegPolicyFilter,
  completeClientCompanyProfileFilter,
  incompleteClientCompanyProfileFilter,
  withClientWorkspaceCompleteness,
} from "../lib/client-workspace-completeness.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("client workspace completeness is added once and Master stays unchanged", () => {
  const ordinary = [{ field: "__country", operator: "equals", values: ["India"] }];
  assert.equal(withClientWorkspaceCompleteness(ordinary, null), ordinary);

  const client = withClientWorkspaceCompleteness(ordinary, "client-a");
  assert.equal(client.length, 3);
  assert.deepEqual(client.at(-2), completeClientCompanyProfileFilter);
  // The client's SEG emails setting, applied by the database (20261003100000).
  assert.deepEqual(client.at(-1), clientSegPolicyFilter("client-a"));
  assert.deepEqual(withClientWorkspaceCompleteness(client, "client-a"), client);

  const incomplete = [incompleteClientCompanyProfileFilter];
  assert.deepEqual(withClientWorkspaceCompleteness(incomplete, "client-a"), [...incomplete, clientSegPolicyFilter("client-a")]);

  const spoofed = [
    incompleteClientCompanyProfileFilter,
    clientSegPolicyFilter("other-client"),
    clientSegPolicyFilter("client-a"),
  ];
  const normalized = withClientWorkspaceCompleteness(spoofed, "client-a");
  assert.deepEqual(normalized, [incompleteClientCompanyProfileFilter, clientSegPolicyFilter("client-a")]);
  assert.equal(normalized.filter(filter => filter.field === "__client_seg_policy").length, 1);
});

test("client UI locks both normal and incomplete partitions and hides the internal filter", async () => {
  const [clients, companies, prospects] = await Promise.all([
    read("../app/components/ClientsPanel.tsx"),
    read("../app/components/CompaniesWorkspace.tsx"),
    read("../app/components/ProspectTable.tsx"),
  ]);
  assert.match(clients, /forceClientWorkspaceCompleteness\(initialFilters, profileFilter\)/);
  assert.match(clients, /incompleteCompanyFilters: ProspectFilter\[\] = \[incompleteClientProfileFilter\]/);
  assert.match(companies, /!internalClientFilterFields\.has\(filter\.field\)/);
  assert.match(prospects, /filter\.field !== "__incomplete_company_profile"/);
});

test("additive migration partitions compilers, counts, exports and explicit ICP writes", async () => {
  const [migration, summaryHotfix, fixture, runner, workflow] = await Promise.all([
    read("../supabase/migrations/20260929120000_segregate_incomplete_client_records.sql"),
    read("../supabase/migrations/20260929160000_client_summaries_subtract_incomplete_only.sql"),
    read("../supabase/tests/incomplete_info_segregation.sql"),
    read("../scripts/test-incomplete-info-migration.mjs"),
    read("../.github/workflows/ci.yml"),
  ]);
  assert.match(migration, /create or replace function public\.company_effective_filter_sql_v1/);
  assert.match(migration, /create or replace view public\.client_summaries/);
  assert.match(migration, /create or replace function public\.set_icp_verified_v1/);
  assert.match(migration, /create or replace function public\.set_company_icp_verified_v2/);
  assert.match(migration, /grant execute on function public\.set_company_icp_verified_v2[\s\S]*to service_role/);
  assert.match(summaryHotfix, /incomplete_company_ids as materialized/);
  assert.match(summaryHotfix, /from public\.client_prospects membership[\s\S]*membership\.status = 'active'/);
  assert.match(summaryHotfix, /- coalesce\(incomplete_people_counts\.prospect_count, 0\)/);
  assert.doesNotMatch(summaryHotfix, /create (?:table|function|index|trigger)/);
  assert.match(fixture, /push_prospects_to_client_v2/);
  assert.match(fixture, /push_companies_to_client_v2/);
  assert.match(fixture, /People partitions overlap or do not cover/);
  assert.match(fixture, /Company partitions overlap or do not cover/);
  assert.equal(fixture.match(/public\.request_result_set_v1\(/g)?.length, 5);
  assert.equal(fixture.match(/prospect_results\.build_batch_v1\(/g)?.length, 5);
  assert.match(fixture, /Complete client People result set differs from the interactive workspace/);
  assert.match(fixture, /Incomplete client Company result set differs from the interactive workspace/);
  assert.match(fixture, /segregation-outsider-incomplete-company/);
  assert.match(fixture, /__company_client_ids filter already used by streamed company exports/);
  assert.match(fixture, /Master result set was partitioned or differs from the interactive workspace/);
  assert.match(fixture, /Enrichment did not promote/);
  assert.match(fixture, /Client summary did not subtract only the incomplete slice/);
  assert.match(fixture, /Client summary did not promote enriched memberships/);
  assert.match(runner, /push, result-set parity, disjoint-union, and enrichment behavior/);
  assert.match(runner, /least-privilege and bounded summary contract/);
  assert.match(runner, /20260929160000_client_summaries_subtract_incomplete_only\.sql/);
  assert.match(workflow, /incomplete-info-contract:/);
  assert.match(workflow, /node scripts\/test-incomplete-info-migration\.mjs/);
});

test("a failed client-directory request is recoverable and never becomes an empty directory", async () => {
  const [dashboard, clients] = await Promise.all([
    read("../app/DashboardApp.tsx"),
    read("../app/components/ClientsPanel.tsx"),
  ]);
  assert.match(dashboard, /const \[clientLoadError, setClientLoadError\] = useState\(""\)/);
  assert.match(dashboard, /Promise\.allSettled/);
  assert.match(dashboard, /return null;[\s\S]*A failed directory read is not an empty directory|A failed directory read is not an empty directory[\s\S]*return null;/);
  assert.match(clients, /Client directory unavailable/);
  assert.match(clients, /no clients or client data were removed/i);
  assert.match(clients, /onClick=\{onRefresh\}>Retry/);
});

test("measured client-summary migration preserves grants and adds synthetic transition parity", async () => {
  const [migration, fixture, runner, workflow] = await Promise.all([
    read("../supabase/migrations/20261004004258_inline_client_summary_ctes.sql"),
    read("../supabase/tests/client_summary_inline_parity.sql"),
    read("../scripts/test-production-hardening-migrations.mjs"),
    read("../.github/workflows/ci.yml"),
  ]);
  const viewBody = migration.slice(0, migration.indexOf("revoke all on public.client_summaries"));
  assert.equal((viewBody.match(/as not materialized/gi) ?? []).length, 5);
  assert.match(migration, /revoke all on public\.client_summaries from public, anon, authenticated/);
  assert.match(fixture, /summary-inline-discard/);
  assert.match(fixture, /SEG-to-mailbox transition mismatch/);
  assert.match(fixture, /Keep-to-discard transition mismatch/);
  assert.match(runner, /cursor baseline differs from the reviewed deterministic fixture/);
  assert.match(runner, /where id not in \('cursor-client-a', 'cursor-client-b'\)/);
  assert.match(runner, /offset 200000 limit 1/);
  assert.match(runner, /offset 100 limit 1/);
  assert.match(runner, /sql\.split\(anchor\)\.length !== 2/);
  assert.match(runner, /from generate_series\(1, 1049\) n/);
  assert.match(runner, /exactly 1,200 canonical and projected rows/);
  assert.match(workflow, /production-hardening-contract:/);
});
