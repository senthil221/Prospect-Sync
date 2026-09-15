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

test("company keyword search defaults to name, keywords and description", async () => {
  const [panel, transport, migration] = await Promise.all([
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/dashboard-api.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825124148_company_keyword_scope_search.sql", import.meta.url), "utf8"),
  ]);

  assert.match(panel, /id: "__company_keywords", label: "Company keywords"/);
  assert.match(panel, /\["name", "keywords", "description"\]/);
  assert.match(panel, /Company description/);
  assert.match(panel, /Broader coverage/);
  assert.match(panel, /Description is on by default/);
  assert.match(panel, /Company name only/);
  assert.match(transport, /scopes\?\.length/);
  assert.match(migration, /when '__company_keywords' then concat_ws/);
  assert.match(migration, /scope\.selected_scopes \? 'description'/);
  assert.match(migration, /company_prefilter_sql/);
  assert.match(migration, /array_append\(scope_parts, 'c\.name'\)/);
  assert.doesNotMatch(migration, /scope_parts := scope_parts \|\|/);
});

// Total funding is a range with a "Not known" option, not a text box.
//
// Verified against production on 2026-09-15 by compiling each band through
// company_filter_sql_v3 and counting: unknown -> 410,634, and the seven bands
// sum to exactly 8,887, which is every company carrying a parseable funding
// figure. No overlaps and no gaps, so the bands partition the funded set.
test("total funding filters by range and by not-known, not by substring", async () => {
  const [panel, migration] = await Promise.all([
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260915090000_total_funding_is_a_range_not_a_string.sql", import.meta.url), "utf8"),
  ]);

  // A token filter would match 10000000 inside 110000000; a range cannot.
  assert.match(panel, /id: "__total_funding", label: "Total funding", kind: "funding"/);
  assert.match(panel, /presets=\{fundingRanges\} unknownLabel="Funding is not known"/);
  // Open-ended top band: production's maximum is 178 billion.
  assert.match(panel, /\["500000001:", "\$500M\+"\]/);

  // The column, kept true by a trigger rather than by whoever remembers to set
  // it, and indexed only where it is non-null (98% of rows are null).
  assert.match(migration, /add column if not exists total_funding_amount bigint/);
  assert.match(migration, /create trigger companies_total_funding_amount_sync/);
  assert.match(migration, /where total_funding_amount is not null/);

  // Both filter paths are patched, and each splice raises if its anchor moved -
  // a silently missed patch would leave the SQL builder and the row matcher
  // disagreeing, which returns wrong answers rather than errors.
  for (const guard of [
    /raise exception 'Could not patch company_filter_sql_v3 funding unknown branch'/,
    /raise exception 'Could not patch company_filter_sql_v3 funding range branch'/,
    /raise exception 'Could not patch company_matches_filters_v1 range bounds'/,
    /raise exception 'Could not patch company_matches_filters_v1 funding clause'/,
  ]) assert.match(migration, guard);

  // Funding parses its own bigint bounds; the shared ones are ::integer and
  // would raise 22003 on anything past 2,147,483,647.
  assert.match(migration, /minimum_big/);
  assert.match(migration, /total_funding_amount >= %s::bigint/);
  assert.match(migration, /a funding bound above the integer range did not compile/);
});

// Master-DB tagging must name the global tag explicitly.
//
// prospect_tags stopped being globally unique in 20260825040000 - one name key
// became two partial unique indexes, (client_id, lower(name)) and lower(name)
// where client_id is null. An unqualified .eq("name", ...).maybeSingle() can
// therefore match a global tag and a client tag of the same name and answer
// PGRST116, turning a tag action into a 500. Client ICP tags are what populate
// that table, so this guard goes in before them.
test("the master tag action is scoped to agency-wide tags", async () => {
  const route = await readFile(new URL("../app/api/operations/route.ts", import.meta.url), "utf8");
  assert.match(route, /from\("prospect_tags"\)\.select\("id"\)\.eq\("name", tagName\)\.is\("client_id", null\)/);
  // And the row it creates is explicitly global rather than global by omission.
  assert.match(route, /insert\(\{ id: tagId, name: tagName, client_id: null \}\)/);
});

// Client include/exclude in the Master DB, by id.
//
// Verified on production 2026-09-15: 4,497 prospects belong to two or more
// clients, and excluding one of them the way __clients does it left 3,570 rows
// in the result that ARE in that client - the joined name string
// "Krishify | Unassigned" equals neither name on its own. By id: 0.
test("the master DB filters by client id, not by joined client names", async () => {
  const [migration, panel, table] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260915130000_filter_the_master_db_by_client.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ProspectTable.tsx", import.meta.url), "utf8"),
  ]);

  // Ids against the GIN index, never the display names.
  assert.match(migration, /pi\.client_ids && %L::text\[\]/);
  assert.match(migration, /not \(pi\.client_ids && %L::text\[\]\)/);

  // Every splice raises if its anchor moved, and the migration proves the
  // result on real rows before it commits.
  for (const guard of [
    /raise exception 'Could not patch prospect_filter_sql_v1 for __client_ids'/,
    /raise exception 'Could not patch prospect_index_matches_v1 for __client_ids'/,
    /raise exception 'Could not patch prospect_prefilter_sql for __client_ids'/,
  ]) assert.match(migration, guard);
  // Include and exclude must partition the index - the property the name-based
  // filter breaks for anyone in two clients.
  assert.match(migration, /include \(%\) \+ exclude \(%\) <> % rows/);
  assert.match(migration, /prospects in the client survived being excluded/);
  // A pre-filter must be a NECESSARY condition, so it may never return fewer
  // rows than the complete predicate.
  assert.match(migration, /the pre-filter \(% rows\) drops rows the complete filter keeps/);

  // Only the include half is pre-filtered. A GIN index answers "contains",
  // never "does not contain", so a negated overlap there would be wrong rather
  // than merely slow - and the migration says so.
  assert.match(migration, /no index is possible/);

  // __clients keeps working: saved views depend on it.
  assert.doesNotMatch(migration, /drop function public\.prospect_filter_sql_v1/);

  // One control, shared by both Master panels, because two copies of something
  // with this much state in it is how the two export dialogs drifted.
  assert.match(panel, /export function ClientMembershipFilter/);
  assert.match(panel, /field: "__client_ids" \| "__company_client_ids"/);
  // Shows names, sends ids, and never puts one client in both directions.
  assert.match(panel, /operator: "not_contains" as const, values: exclude/);
  assert.match(panel, /A client lands in exactly one list, never both/);
  // Not offered inside a client workspace, where it could only be a no-op or a
  // contradiction.
  assert.match(panel, /!clientId && clients\.length/);
  assert.match(table, /clients=\{clients\}/);

  // The Company half, against client_companies rather than an array column.
  const [companyMigration, companyPanel, workspace] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260915140000_filter_the_master_company_db_by_client.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/CompaniesWorkspace.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(companyMigration, /exists \(select 1 from public\.client_companies cc/);
  // companies.client_count is a stored count, not a membership set; "exclude
  // Krishify" is not a question a number can answer.
  assert.match(companyMigration, /it says how many clients a company touches, not which/);
  for (const guard of [
    /raise exception 'Could not patch company_filter_sql_v3 for __company_client_ids'/,
    /raise exception 'Could not patch company_matches_filters_v1 for __company_client_ids'/,
    /raise exception 'Could not close the wrapped CASE in company_matches_filters_v1'/,
    /raise exception 'Could not patch company_prefilter_sql for __company_client_ids'/,
  ]) assert.match(companyMigration, guard);
  // The anchor lesson: a two-line anchor was split by an earlier splice, so it
  // anchors on the single stable line instead.
  assert.match(companyMigration, /spliced __company_icp_verified in between them/);
  assert.match(companyPanel, /<ClientMembershipFilter field="__company_client_ids"/);
  assert.match(workspace, /<CompanyFilterPanel filters=\{filters\} clients=\{clients\}/);
});
