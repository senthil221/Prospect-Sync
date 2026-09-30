import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  completeClientCompanyProfileFilter,
  incompleteClientCompanyProfileFilter,
  withClientWorkspaceCompleteness,
} from "../lib/client-workspace-completeness.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("client workspace completeness is added once and Master stays unchanged", () => {
  const ordinary = [{ field: "__country", operator: "equals", values: ["India"] }];
  assert.equal(withClientWorkspaceCompleteness(ordinary, null), ordinary);

  const client = withClientWorkspaceCompleteness(ordinary, "client-a");
  assert.equal(client.length, 2);
  assert.deepEqual(client.at(-1), completeClientCompanyProfileFilter);
  assert.equal(withClientWorkspaceCompleteness(client, "client-a"), client);

  const incomplete = [incompleteClientCompanyProfileFilter];
  assert.equal(withClientWorkspaceCompleteness(incomplete, "client-a"), incomplete);
});

test("client UI locks both normal and incomplete partitions and hides the internal filter", async () => {
  const [clients, companies, prospects] = await Promise.all([
    read("../app/components/ClientsPanel.tsx"),
    read("../app/components/CompaniesWorkspace.tsx"),
    read("../app/components/ProspectTable.tsx"),
  ]);
  assert.match(clients, /forceClientWorkspaceCompleteness\(initialFilters, profileFilter\)/);
  assert.match(clients, /incompleteCompanyFilters: ProspectFilter\[\] = \[incompleteClientProfileFilter\]/);
  assert.match(companies, /filter\.field !== incompleteCompanyProfileField/);
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
