import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL("../supabase/migrations/20260812210224_request_2_company_people_workflows.sql", import.meta.url);

test("company DB supports name/website filters and direct company CSV imports", async () => {
  const [dashboard, companiesRoute, startRoute, chunkRoute, migration] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/chunk/route.ts", import.meta.url), "utf8"),
    readFile(migrationUrl, "utf8"),
  ]);
  assert.match(dashboard, /Import names &amp; websites/);
  assert.match(dashboard, /Company Name and\/or Website column/);
  assert.match(dashboard, /Import companies/);
  // Names and websites are no longer separate RPC arguments: both arrive as
  // ordinary __company / __website filters in the shared filter payload, which
  // filter_companies_v4 resolves through the indexed company pre-filter.
  assert.match(companiesRoute, /filter_companies_v4/);
  assert.match(companiesRoute, /p_filters: filters/);
  assert.match(startRoute, /Choose a data source before importing/);
  assert.match(chunkRoute, /import_company_batch_v2/);
  assert.match(migration, /primary key \(import_id, source_row_number\)/);
  assert.match(migration, /primary key \(company_id, data_source\)/);
});

test("data source is required and stored separately for prospect imports", async () => {
  const [dashboard, sources, startRoute, migration] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/data-source.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(migrationUrl, "utf8"),
  ]);
  assert.match(dashboard, /commonDataSources/);
  assert.match(sources, /Scraper.*Apollo.*Prospeo.*SalesQL.*BetterContact/);
  assert.match(dashboard, /Data source/);
  assert.match(startRoute, /normalizeDataSource/);
  assert.match(startRoute, /data_source: dataSource/);
  assert.match(migration, /imports_data_source_required/);
  assert.match(migration, /lists_data_source_required/);
  assert.match(migration, /jsonb_array_length\(l\.field_headers\)::integer as field_count,\s+l\.data_source/);
});

test("client prospect removal preserves the canonical Master DB record by default", async () => {
  const [dashboard, removeRoute, clientRoute, listRoute, importRoute, migration] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/prospects/[prospectId]/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/lists/[id]/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/[id]/route.ts", import.meta.url), "utf8"),
    readFile(migrationUrl, "utf8"),
  ]);
  assert.match(dashboard, /The Master DB record will be preserved/);
  assert.match(dashboard, /useState\(false\)/);
  assert.match(removeRoute, /masterProspectPreserved: true/);
  assert.match(migration, /delete from public\.list_memberships/);
  assert.doesNotMatch(migration.slice(migration.indexOf("remove_prospect_from_client_v1"), migration.indexOf("prospect_index_matches_v1")), /delete from public\.prospects/);
  // Orphan cleanup is not caller-controlled anywhere: a client, list, or import
  // delete can never take a master People/Company record down with it, not even
  // via a malformed request. The routes go through one shared helper, and both
  // the helper's fallback and the server-side functions pin the flag to false.
  for (const route of [clientRoute, listRoute, importRoute]) {
    assert.match(route, /deleteAndReindex\(/);
    assert.doesNotMatch(route, /p_delete_orphans/, "routes must not choose the orphan policy themselves");
  }
  const [cleanup, reindexMigration] = await Promise.all([
    readFile(new URL("../lib/delete-cleanup.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825020000_reindex_reliability.sql", import.meta.url), "utf8"),
  ]);
  assert.match(cleanup, /p_delete_orphans:\s*false/);
  assert.doesNotMatch(cleanup, /p_delete_orphans:(?!\s*false\b)/);
  for (const fn of ["delete_client_with_cleanup", "delete_list_with_cleanup", "delete_import_with_cleanup"]) {
    assert.match(reindexMigration, new RegExp(`${fn}\\([^)]*false\\)`), `${fn} must be called with orphan cleanup disabled`);
  }
});

test("People and Company DB pivots preserve the source filter contract", async () => {
  const [dashboard, prospectsRoute, companiesRoute, exportRoute, migration] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/export/route.ts", import.meta.url), "utf8"),
    readFile(migrationUrl, "utf8"),
  ]);
  assert.match(dashboard, /See People/);
  assert.match(dashboard, /See Companies/);
  assert.match(dashboard, /companyScope/);
  assert.match(dashboard, /peopleScope/);
  assert.match(prospectsRoute, /search_prospect_workspace_v12/);
  assert.match(companiesRoute, /p_people_scope: peopleScope/);
  assert.match(exportRoute, /search_prospect_export_v5/);
  assert.match(migration, /company_matches_scope_v1/);
  assert.match(migration, /prospect_index_matches_v1/);
});
