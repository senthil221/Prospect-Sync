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
  assert.match(route, /search_prospect_workspace_v13/);
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
  // The control itself moved to ApolloFilterPanel in 20260916190000 so the
  // People rail could render the same one; CompanyFilterPanel now imports it.
  // Both files are read, because the point of the move is that there is exactly
  // one of it.
  const [panel, companyPanel, transport, migration] = await Promise.all([
    readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/dashboard-api.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825124148_company_keyword_scope_search.sql", import.meta.url), "utf8"),
  ]);

  assert.match(companyPanel, /id: "__company_keywords", label: "Company keywords"/);
  assert.match(companyPanel, /CompanyKeywordFilter/);
  assert.doesNotMatch(companyPanel, /function CompanyKeywordFilter/);
  assert.match(panel, /\["name", "keywords", "description"\]/);
  assert.match(panel, /Company description/);
  assert.match(panel, /Broader coverage/);
  assert.match(panel, /Description is on by default/);
  assert.match(companyPanel, /Company name only/);
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
  const [panel, people, migration] = await Promise.all([
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260915090000_total_funding_is_a_range_not_a_string.sql", import.meta.url), "utf8"),
  ]);

  // A token filter would match 10000000 inside 110000000; a range cannot.
  assert.match(panel, /id: "__total_funding", label: "Total funding", kind: "funding"/);
  assert.match(panel, /presets=\{fundingRanges\} unknownLabel="Funding is not known"/);
  // The bands live beside the control that renders them, and both rails import
  // them from there - see 20260916090000, which gave the People panel the same
  // funding filter. Two copies would let the two databases disagree about what
  // "$100M - $500M" means.
  assert.match(people, /export const fundingRanges = \[/);
  assert.doesNotMatch(panel, /const fundingRanges = \[/);
  // Open-ended top band: production's maximum is 178 billion.
  assert.match(people, /\["500000001:", "\$500M\+"\]/);

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

// Agency-wide tags are retired; nothing may create another one.
//
// They were prospect_tags rows with client_id null, made from a window.prompt
// in the Master People DB. That was a second tag vocabulary running beside the
// client ICPs and indistinguishable from them once it reached
// prospect_index.tags, so the only writer left is set_client_prospect_tag_v1,
// which an ICP owns. What already carries an agency-wide tag keeps it.
test("no path creates an agency-wide tag any more", async () => {
  // Comment lines stripped: both files explain the retirement in prose that
  // names the button and the table it used to write to.
  const codeOnly = (source) => source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("//")).join("\n");
  const route = codeOnly(await readFile(new URL("../app/api/operations/route.ts", import.meta.url), "utf8"));
  const table = codeOnly(await readFile(new URL("../app/components/ProspectTable.tsx", import.meta.url), "utf8"));

  // The route answers 410 rather than tagging, and rather than a bare 400 that
  // would reach a stale tab as "Unsupported bulk action".
  assert.match(route, /payload.action === "tag"/);
  assert.match(route, /status: 410/);
  // Nothing inserts into prospect_tags or links a prospect to one from here.
  assert.doesNotMatch(route, /from\("prospect_tags"\)\.insert/);
  assert.doesNotMatch(route, /prospect_tag_links/);

  // And the button and its prompt are gone from the bulk bar.
  assert.doesNotMatch(table, /Add tag/);
  assert.doesNotMatch(table, /window\.prompt\("Tag name"\)/);
  // The ICP path is what replaced it, and is still wired up.
  assert.match(table, /clientTagAction\("add_tag"\)/);
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
  // Generalised to any id-and-name list, so the same control serves the client
  // filter and the client ICP tag filter on both entities.
  assert.match(panel, /__client_ids, __company_client_ids, __client_tags, __company_tags or __list_ids/);
  assert.match(panel, /options: Array<\{ id: string; name: string \}>/);
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

// First and last names are title-cased on import and were backfilled once.
test("names are title-cased only where nobody has already cased them", async () => {
  const { titleCaseName, mapProspect } = await import("../db/normalize.ts");

  // Entirely one case carries no decision, so it is corrected.
  assert.equal(titleCaseName("PRAKHAR"), "Prakhar");
  assert.equal(titleCaseName("prakhar"), "Prakhar");
  assert.equal(titleCaseName("JEAN-LUC"), "Jean-Luc");
  assert.equal(titleCaseName("o'brien"), "O'Brien");
  assert.equal(titleCaseName("MARY ANN"), "Mary Ann");

  // Mixed case is somebody's decision. Blind title-casing turns McDonald into
  // Mcdonald; production carries 889 such names, 98 of them Mc/Mac/De/Van/O.
  assert.equal(titleCaseName("McDonald"), "McDonald");
  assert.equal(titleCaseName("DeShawn"), "DeShawn");
  assert.equal(titleCaseName("SenthilKumar"), "SenthilKumar");
  assert.equal(titleCaseName("Prakhar"), "Prakhar");

  // Nothing to case.
  assert.equal(titleCaseName(""), "");
  assert.equal(titleCaseName("   "), "");
  assert.equal(titleCaseName("123"), "123");

  // Applied on import, to both columns.
  const mapped = mapProspect(["First Name", "Last Name"], ["PRAKHAR", "KESHARIYA"]);
  assert.equal(mapped.firstName, "Prakhar");
  assert.equal(mapped.lastName, "Keshariya");
  // A full name we DERIVE inherits the correction...
  assert.equal(mapped.fullName, "Prakhar Keshariya");
  // ...but a supplied one is never rewritten.
  const supplied = mapProspect(["First Name", "Last Name", "Full Name"], ["PRAKHAR", "KESHARIYA", "PRAKHAR KESHARIYA"]);
  assert.equal(supplied.firstName, "Prakhar");
  assert.equal(supplied.fullName, "PRAKHAR KESHARIYA");
});

test("the name backfill cannot touch an already-cased name", async () => {
  const migration = await readFile(new URL("../supabase/migrations/20260915160000_first_and_last_names_are_title_case.sql", import.meta.url), "utf8");

  // The guard: only values equal to their own upper() or lower() are in range.
  assert.match(migration, /\(first_name = upper\(first_name\) or first_name = lower\(first_name\)\)/);
  assert.match(migration, /\(last_name = upper\(last_name\) or last_name = lower\(last_name\)\)/);
  // Counted before and after, so a widened predicate is caught rather than
  // discovered later in somebody's export.
  assert.match(migration, /the backfill changed % names that were already cased/);
  assert.match(migration, /names remain wrongly cased after the backfill/);

  // prospect_index carries first_name and last_name, so it is corrected in the
  // same statement - but search_text is built from full_name, which is not
  // changing, so no re-index is queued.
  assert.match(migration, /update public\.prospect_index pi/);
  assert.doesNotMatch(migration.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n"), /enqueue_reindex|reindex_scope_v1|reindex_prospects/);
  assert.match(migration, /prospect_index still disagrees with prospects about a name/);
  // full_name is deliberately untouched, and the file says what that costs.
  assert.match(migration, /FULL NAME IS DELIBERATELY NOT TOUCHED/);
});

// The Tags filter offers the tags it can match.
//
// prospect_filter_values_v3's '__tags' branch joined prospect_tags with
// "and pt.client_id is null" hard-coded, so the picker only ever listed
// agency-wide tags - one of them exists - while the predicate it feeds matches
// on pi.tag_text, which carries every tag a prospect has. Inside a client
// workspace the list therefore opened empty even though every ICP the client
// had applied was matchable by name.
test("the tag value picker is scoped like the predicate it feeds", async () => {
  const migration = await readFile(new URL("../supabase/migrations/20260916140000_the_tag_filter_offers_the_tags_it_can_match.sql", import.meta.url), "utf8");

  // Spliced onto the live definition, and refusing to run if the line it
  // replaces has moved - a restated copy of a 90-line field mapping is a copy
  // that drifts.
  assert.match(migration, /pg_get_functiondef\('public\.prospect_filter_values_v3/);
  assert.match(migration, /raise exception 'prospect_filter_values_v3 no longer contains/);

  // Client set: agency-wide plus that client's own. Client null (the Master
  // DB): everything, because tag_text is not scoped by client either.
  assert.match(migration, /pt\.client_id is null or pt\.client_id = %L/);
  assert.match(migration, /case when p_client_id is null then ''/);

  // Proved on rows rather than on the SQL text, because what was wrong was
  // never the text - and the probe rows are removed inside the transaction.
  assert.match(migration, /a client workspace still cannot see its own ICP tag/);
  assert.match(migration, /one client is being offered another client''s ICP tag/);
  assert.match(migration, /delete from public\.prospect_tag_links where tag_id = v_tag/);
  assert.match(migration, /the migration probe tag was not removed/);

  // And the agency-wide list the Master DB has always shown is unchanged.
  assert.match(migration, /the master tag list lost agency-wide tags/);
});
