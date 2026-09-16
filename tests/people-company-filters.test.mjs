import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseFilters } from "../lib/prospect-filters.ts";
import { standardExportFieldIds } from "../lib/prospect-export.ts";
import { qualityIssues } from "../lib/quality-issues.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
// Prose is not evidence. A comment naming a table or a field would satisfy every
// assertion below without a line of it being true, so the comments come out.
const codeOnly = (source) => source.split("\n").filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("--")).join("\n");

const migration = () => read("../supabase/migrations/20260916090000_people_filters_reach_the_company_profile.sql");
const qualityMigration = () => read("../supabase/migrations/20260916100000_data_quality_counts_the_company_profile.sql");

// The six company-profile fields, spelled the way the People export already
// spells them. Filtering and exporting naming the same field differently is how
// a column you can see becomes a column you cannot narrow by.
const profileFields = [
  "__company_industry", "__company_keywords", "__company_description",
  "__company_technologies", "__company_founded_year", "__company_total_funding",
];

test("the People filters and the People export name the company fields alike", () => {
  for (const field of profileFields) {
    assert.ok(standardExportFieldIds.includes(field), `${field} must already be an export column`);
  }
});

test("the People panel offers the company profile in its own group", async () => {
  const code = codeOnly(await read("../app/ApolloFilterPanel.tsx"));

  // __company_description is the exception since 20260916190000: it became the
  // third tick box of the Company Keywords control rather than a filter of its
  // own. It still COMPILES and still matches - a saved view built on it keeps
  // working - it is simply no longer offered, which is why this asserts the
  // panel and the equivalence battery below still covers the field itself.
  for (const field of profileFields.filter((field) => field !== "__company_description")) {
    assert.ok(code.includes(`id: "${field}"`), `${field} must be offered in the People panel`);
  }
  assert.ok(!code.includes('id: "__company_description"'),
    "Company Description is the Company Keywords description tick box now, not a separate filter");
  assert.match(code, /kind: "company_keywords"/);
  // The two that prospect_index already carried belong in the same group, or
  // "company size" and "company industry" sit in different places for no reason.
  assert.ok(code.includes('id: "__employee_count"'));
  assert.ok(code.includes('id: "__company_location"'));
  assert.match(code, /<small>Company<\/small>\{visibleCompany\.map\(renderDefinition\)\}/);

  // Suggestions for a company field come from the company endpoint. Asking the
  // People one scans prospect_index to return nothing, which is the mistake the
  // Companies panel already made once.
  assert.match(code, /const COMPANY_VALUES_ENDPOINT = "\/api\/companies\/filter-values"/);
  for (const field of ["__company_industry", "__company_keywords", "__company_technologies"]) {
    const line = code.split("\n").find((entry) => entry.includes(`id: "${field}"`));
    assert.match(line, /valuesEndpoint: COMPANY_VALUES_ENDPOINT/, `${field} must autocomplete against companies`);
  }
  // Company location is the exception, and deliberately: its predicate reads the
  // columns prospect_index carries, so the People endpoint offers exactly the
  // values that can match.
  const location = code.split("\n").find((entry) => entry.includes('id: "__company_location"'));
  assert.doesNotMatch(location, /valuesEndpoint/);

  // Filters must survive the URL round trip with a readable name, not a key.
  assert.match(code, /\.\.\.mainFilters, \.\.\.classifierFilters, \.\.\.companyFilters/);
});

test("one range control serves both rails", async () => {
  const [people, companies] = await Promise.all([
    read("../app/ApolloFilterPanel.tsx"),
    read("../app/CompanyFilterPanel.tsx"),
  ]);
  // It existed twice - EmployeeFilter here, RangeFilter there - and the copies
  // had already drifted over whether applying a custom range clears the inputs.
  assert.match(people, /export function RangeFilter\(/);
  assert.doesNotMatch(companies, /^function RangeFilter\(/m);
  assert.doesNotMatch(people, /function EmployeeFilter\(/);
  assert.match(companies, /import \{[^}]*RangeFilter[^}]*\} from "\.\/ApolloFilterPanel"/);
  for (const bands of ["employeeRanges", "foundedYearRanges", "fundingRanges"]) {
    assert.match(people, new RegExp(`export const ${bands} = \\[`), `${bands} belongs beside the control`);
    assert.doesNotMatch(companies, new RegExp(`^const ${bands} = \\[`, "m"), `${bands} must not be copied`);
  }
});

test("a company keyword filter carries its scopes through parseFilters intact", () => {
  // __company_keywords used to mean two different things by surface: the
  // Companies panel's scoped name+keywords+description bundle, and - here - the
  // plain keyword array, whose scopes the People compiler ignored. Since
  // 20260916190000 both rails render the same control and both compilers honour
  // the same scopes, so the two surfaces can no longer answer the same question
  // differently. What must still not happen is the value list changing shape.
  const [filter] = parseFilters(JSON.stringify([{ field: "__company_keywords", operator: "contains", values: ["fintech"] }]));
  assert.deepEqual(filter.values, ["fintech"]);
  assert.equal(filter.operator, "contains");

  // Ranges reach the compiler intact, including the open-ended top band and the
  // bigint bound that would overflow an integer.
  const [funding] = parseFilters(JSON.stringify([{ field: "__company_total_funding", operator: "number_ranges", values: ["500000001:", "unknown"] }]));
  assert.deepEqual(funding.values, ["500000001:", "unknown"]);
  assert.throws(() => parseFilters(JSON.stringify([{ field: "__company_founded_year", operator: "number_ranges", values: ["2019:2010"] }])), /bounds/);
});

test("the migration reads companies rather than widening prospect_index", async () => {
  const code = codeOnly(await migration());

  // The whole point: no column, no backfill, no index. A single added column
  // would be 1.7 GB of duplication and a backfill no migration can hold.
  assert.doesNotMatch(code, /alter table (public\.)?prospect_index add column/i);
  assert.doesNotMatch(code, /create index/i);
  assert.match(code, /exists \(select 1 from public\.companies co where co\.id = pi\.company_id/);

  // Both compilers are patched, and each splice raises if its anchor moved. A
  // silently missed patch leaves the grid and a bulk action disagreeing, which
  // returns wrong answers rather than errors.
  for (const guard of [
    /refusing to patch blindly/,
    /prospect_filter_sql_v1 no longer opens its column CASE where expected/,
    /prospect_index_matches_v1 no longer opens its operator CASE where expected/,
    /prospect_index_matches_v1 number_ranges branch is not in the expected shape/,
  ]) assert.match(code, guard);

  // Funding bounds are bigint on both sides. Production's maximum is 178
  // billion, and the shared lateral was ::integer.
  assert.match(code, /total_funding_amount >= %s::bigint/);
  assert.match(code, /split_part\(selected\.value, ':', 1\)::bigint end as minimum/);

  // Equality on a tag array is membership over the GIN index, and the row
  // matcher mirrors the same function rather than approximating it with lower().
  assert.match(code, /co\.keywords && %L::text\[\]/);
  assert.match(code, /&& public\.keyword_tag_variants_v1\(/);

  // And the two are proved equal rather than assumed, on a sample built to hold
  // the shapes that could disagree.
  assert.match(code, /compiled SQL and the row matcher disagree on/);
  assert.match(code, /selected % of % sampled rows and so tests nothing/);
});

test("the Boolean filter stops inheriting the previous filter's values", async () => {
  const code = codeOnly(await migration());
  // Live before this migration: a Boolean filter after any contains filter
  // compiled to (A) and (A or B), which is A - so the Boolean search silently
  // did nothing. One line clears the accumulator, and the check is permanent.
  assert.match(code, /value_parts := array\[\]::text\[\];\s*\n\s*foreach value_text in array raw_values loop\s*\n\s*value_parts := value_parts \|\| format\('to_tsvector/);
  assert.match(code, /the Boolean branch is still inheriting the previous filter/);
});

test("autocomplete answers the People spelling and refuses what it cannot suggest", async () => {
  const code = codeOnly(await migration());
  assert.match(code, /'__technologies', '__company_technologies'/);
  assert.match(code, /when '__company_industry' then c\.industry/);
  // An unmapped field used to fall through to `else ''` and GROUP 418,151
  // companies to return nothing, once per keystroke.
  assert.match(code, /if p_field not in \('__industry', '__company_industry'/);
  assert.match(code, /returned % suggestions for a description field/);
});

test("Data Quality counts the company profile and each tile opens onto it", async () => {
  const code = codeOnly(await qualityMigration());

  assert.match(code, /'missingEmployees', count\(\*\) filter \(where c\.employee_count_min is null and c\.employee_count_max is null\)/);
  // Counted through array_to_string, not array_length: a keywords array holding
  // one empty string has length 1 and is empty to the filter, and the tile and
  // the button would have disagreed on exactly those rows.
  assert.match(code, /'missingCompanyKeywords', count\(\*\) filter \(where btrim\(coalesce\(array_to_string\(c\.keywords, ' \| '\), ''\)\) = ''\)/);
  assert.match(code, /'missingCompanyDescription', count\(\*\) filter \(where btrim\(coalesce\(c\.short_description, ''\)\) = ''\)/);

  // The cached snapshot skips a key whose data version has not moved, so
  // without this the tab would read three zeroes until some unrelated write.
  assert.match(code, /delete from public\.dashboard_snapshot where key = 'dataQuality'/);
  assert.match(code, /refresh_dashboard_snapshots_v1\(\)/);

  // Tile equals filter, whole table, or the migration refuses to commit.
  assert.match(code, /the % tile reads % but its filter selects %/);
  assert.match(code, /the dataQuality snapshot predates the new checks/);

  // And the three checks are in the queue, ranked below the gaps that stop an
  // email going out entirely.
  const issues = qualityIssues({
    total: 683_784, missingEmail: 23, missingTitle: 0, missingLinkedin: 0, missingCompany: 0,
    missingDomain: 0, staleRecords: 0, potentialDuplicateGroups: 0,
    missingEmployees: 78_995, missingCompanyKeywords: 94_089, missingCompanyDescription: 94_444,
  });
  const byId = Object.fromEntries(issues.map((issue) => [issue.id, issue]));
  assert.equal(byId.employees.severity, "medium");
  assert.equal(byId.company_keywords.severity, "medium");
  assert.equal(byId.company_description.severity, "low");
  assert.equal(issues[0].id, "email", "a gap that blocks outreach still outranks a targeting gap");
});

test("a database without the migration reports the new checks as clear, not as an error", () => {
  // The snapshot is recomputed inside 20260916100000, so the only window is a
  // deploy that runs ahead of its migration. It must degrade, not throw.
  const issues = qualityIssues({
    total: 683_784, missingEmail: 0, missingTitle: 0, missingLinkedin: 0, missingCompany: 0,
    missingDomain: 0, staleRecords: 0, potentialDuplicateGroups: 0,
  });
  const byId = Object.fromEntries(issues.map((issue) => [issue.id, issue]));
  for (const id of ["employees", "company_keywords", "company_description"]) {
    assert.equal(byId[id].count, 0);
    assert.equal(byId[id].severity, "clear");
  }
});

// Company Keywords in the People rail is the Companies rail's control, and both
// compilers honour its tick boxes.
//
// The risk this covers is the one 20260916090000 was written for: the compiler
// builds SQL and the row matcher walks a row, so a scope handled by one and not
// the other shows up as a grid that disagrees with its own bulk actions.
test("the company keyword scopes reach both halves of the People pair", async () => {
  const code = codeOnly(await read("../supabase/migrations/20260916190000_company_keywords_in_people_search_the_same_three_fields.sql"));

  // One resolution function, called by both sides. Neither may decide for
  // itself what an absent or empty scopes array means.
  assert.match(code, /create or replace function public\.company_keyword_scopes_v1/);
  assert.ok((code.match(/company_keyword_scopes_v1\(filter_item->''scopes''\)/g) ?? []).length >= 3,
    "both the compiler and the row matcher must resolve scopes through the shared function");

  // Absent scopes keep meaning keywords-only. Widening them would silently
  // change what every saved view and frozen result set already returns.
  assert.match(code, /else '\["keywords"\]'::jsonb/);

  // Each splice refuses if its anchor moved, rather than patching blindly.
  for (const guard of [
    /prospect_filter_sql_v1 no longer contains the company keyword expression/,
    /prospect_filter_sql_v1 no longer contains the keyword tag branch/,
    /prospect_index_matches_v1 no longer contains the company keyword arm/,
    /prospect_index_matches_v1 no longer contains the tag-array arm/,
  ]) assert.match(code, guard);

  // Unticking Keywords must also switch off the tag-array shortcut, or the box
  // would still match through it and do nothing.
  assert.match(code, /or public\.company_keyword_scopes_v1\(filter_item->''scopes''\) \? ''keywords''/);

  // Proved equal rather than assumed, across every scope combination, and
  // bounded: the row matcher is PL/pgSQL with a correlated subquery per row, so
  // an unbounded sweep of 683,784 prospects is minutes inside a transaction.
  assert.match(code, /the compiler matched % rows and the row matcher matched %/);
  assert.match(code, /limit 3000/);
  assert.match(code, /limit 2000/);
  // And the battery cannot pass by both sides being equally wrong.
  assert.match(code, /unticking Keywords changed nothing/);
});
