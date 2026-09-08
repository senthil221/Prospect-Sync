import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// The main-filter list is deliberately narrow: only the mandatory person fields
// plus Location are offered up front, and everything else arrives through the
// whitelisted custom fields in "MORE FILTERS". Assert the fields that must be
// reachable and the interaction modes each one supports.
test("Apollo panel exposes the requested main filters and interaction modes", async () => {
  const panel = await readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8");
  for (const field of ["__name", "__company", "__email", "__linkedin", "__title_seniority", "__title_department", "__esp_type"]) {
    assert.match(panel, new RegExp(`id: "${field}"`), `${field} is missing from the filter panel`);
  }
  assert.match(panel, />Include</);
  assert.match(panel, />Exclude</);
  assert.match(panel, /Boolean Search/);
  assert.match(panel, /AND\/OR\/NOT/);
  assert.match(panel, /onPaste/);
  // Pasted lists go through the shared parser so a URL is trimmed to the stored
  // domain the same way in every picker, in the Company DB box, and the blocklist.
  assert.match(panel, /mergeBulkValues/);
  assert.match(panel, /splitPastedValues/);
  // Bulk paste mode: a large textarea with its own scroll, not a one-line input.
  assert.match(panel, /Paste list/);
  assert.match(panel, /token-bulk/);
  assert.match(panel, /chipCollapseThreshold/);
});

test("new filters are applied globally before pagination and are available to exports", async () => {
  const [migration, route, dashboard, filtersLib, exportLib] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260810000000_apollo_prospect_filters.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/prospect-filters.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/prospect-export.ts", import.meta.url), "utf8"),
  ]);
  assert.match(migration, /add column if not exists keywords text\[\]/);
  assert.match(migration, /employee_count_min integer/);
  assert.match(migration, /company_location/);
  assert.match(migration, /when 'boolean' then/);
  assert.match(migration, /to_tsvector\('simple'/);
  assert.match(migration, /when 'number_ranges' then/);
  assert.match(migration, /custom:%/);
  const viewDefinition = migration.slice(migration.indexOf("create or replace view public.prospect_summaries"), migration.indexOf("create or replace function public.import_prospect_batch_v4"));
  assert.doesNotMatch(viewDefinition, /select p\.\*/);
  assert.ok(viewDefinition.indexOf("co.name as company_name") < viewDefinition.indexOf("p.keywords"), "new view columns must be appended after the existing view contract");
  assert.match(migration, /filtered as materialized/);
  assert.ok(migration.indexOf("filtered as materialized") < migration.indexOf("limit greatest", migration.indexOf("filtered as materialized")));
  // The route calls exactly one workspace function - no version ladder to fall
  // through, so a filter contract can never be silently downgraded.
  assert.match(route, /search_prospect_workspace_v12/);
  assert.equal(route.match(/search_prospect_workspace_v\d+/g).length, 1);
  assert.match(filtersLib, /compileBooleanSearch/);
  assert.match(filtersLib, /operator === "number_ranges"/);
  assert.match(exportLib, /header: "Keywords"/);
  assert.match(exportLib, /header: "# Employees"/);
  assert.match(dashboard, /ApolloFilterPanel/);
  assert.match(dashboard, /Company Employee Count/);
});

test("person geography is retired while company geography remains available", async () => {
  const [people, companies, schema] = await Promise.all([
    readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/import-schema.ts", import.meta.url), "utf8"),
  ]);

  // The single Location field is offered in both panels...
  assert.doesNotMatch(people, /id: "__person_location"/);
  assert.match(companies, /id: "__company_location", label: "Company location"/);

  // ...and the three parts are not offered as separate filters anywhere. They
  // remain real columns for exports and enrichment; they are just not three
  // things to filter on. Asserted by absence rather than by the filter lists
  // being literally empty, so an unrelated filter (Tags) can live there without
  // weakening the guarantee this test exists for.
  for (const part of ["__city", "__state", "__country", "__company_city", "__company_state", "__company_country"]) {
    assert.ok(!people.includes(`id: "${part}"`), `${part} must not be a People filter`);
    assert.ok(!companies.includes(`id: "${part}"`), `${part} must not be a Company filter`);
  }

  // The fixed contract has the three approved geography fields and does not
  // retain a legacy free-form Company Location import column.
  assert.match(schema, /companyGeographyFields/);
  assert.match(schema, /companyGeographyFields = \["Company City", "Company State", "Company Country"\]/);
  assert.match(schema, /\.\.\.companyGeographyFields/);
  assert.doesNotMatch(schema, /Company Location \(or/);
});

test("company keyword search defaults to name and keywords with optional description", async () => {
  const [panel, transport, migration] = await Promise.all([
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/dashboard-api.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825124148_company_keyword_scope_search.sql", import.meta.url), "utf8"),
  ]);

  assert.match(panel, /id: "__company_keywords", label: "Company keywords"/);
  assert.match(panel, /\["name", "keywords"\]/);
  assert.match(panel, /Company description/);
  assert.match(panel, /Broader coverage/);
  assert.match(panel, /Description increases recall/);
  assert.match(panel, /Company name only/);
  assert.match(transport, /scopes\?\.length/);
  assert.match(migration, /when '__company_keywords' then concat_ws/);
  assert.match(migration, /scope\.selected_scopes \? 'description'/);
  assert.match(migration, /company_prefilter_sql/);
  assert.match(migration, /array_append\(scope_parts, 'c\.name'\)/);
  assert.doesNotMatch(migration, /scope_parts := scope_parts \|\|/);
});
