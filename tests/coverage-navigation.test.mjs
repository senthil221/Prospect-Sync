import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { coverageCompanyFilter } from "../lib/coverage-file.ts";
import { parseFilters } from "../lib/prospect-filters.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const codeOnly = (source) => source.split("\n").filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("--")).join("\n");

const row = (over) => ({
  row: 2, name: "", domain: "", status: "known", matchedBy: "domain",
  matchedCompany: "", matchedCompanyId: "", prospectCount: 0, clientCount: 0, ...over,
});

test("each button opens onto exactly the companies it counted", () => {
  const rows = [
    row({ row: 2, matchedCompanyId: "c1", prospectCount: 12 }),
    row({ row: 3, matchedCompanyId: "c2", prospectCount: 0 }),
    row({ row: 4, matchedCompanyId: "c3", prospectCount: 1 }),
    row({ row: 5, status: "new", matchedCompanyId: "", prospectCount: 0 }),
  ];

  const covered = coverageCompanyFilter(rows, true);
  assert.deepEqual(covered[0].values, ["c1", "c3"]);
  assert.equal(covered[0].field, "__company_ids");
  // equals, not contains: these are exact keys, and the Company DB answers an
  // id set off companies_pkey.
  assert.equal(covered[0].operator, "equals");

  const uncovered = coverageCompanyFilter(rows, false);
  assert.deepEqual(uncovered[0].values, ["c2"]);

  // A net-new row has no company record to open, so it belongs to neither set.
  // Its route out of here is the export.
  assert.equal([...covered[0].values, ...uncovered[0].values].includes(""), false);
});

test("a company listed twice in the file opens once", () => {
  // summary.covered counts ROWS, and a real upload repeats companies. If the
  // button carried the row count it would promise more companies than open.
  const rows = [
    row({ row: 2, matchedCompanyId: "c1", prospectCount: 4 }),
    row({ row: 3, matchedCompanyId: "c1", prospectCount: 4 }),
    row({ row: 4, matchedCompanyId: "c1", prospectCount: 4 }),
  ];
  const covered = coverageCompanyFilter(rows, true);
  assert.deepEqual(covered[0].values, ["c1"]);
});

test("nothing to open produces no filter, never an empty one", () => {
  // An empty values list would compile to a no-op, which opens the WHOLE
  // company database - the opposite of what the button says. The panel disables
  // the button on an empty array instead.
  assert.deepEqual(coverageCompanyFilter([], true), []);
  assert.deepEqual(coverageCompanyFilter([row({ status: "new" })], false), []);
  // A known row whose match somehow carries no id is dropped rather than
  // contributing a blank value.
  assert.deepEqual(coverageCompanyFilter([row({ matchedCompanyId: "" })], false), []);
});

test("the filter survives the request boundary intact", () => {
  const ids = Array.from({ length: 4000 }, (unused, index) => `company-${index}`);
  const rows = ids.map((id, index) => row({ row: index + 2, matchedCompanyId: id, prospectCount: 3 }));
  const [filter] = coverageCompanyFilter(rows, true);
  // A coverage check carries at most 5,000 rows (lib/coverage-file.ts), which
  // has to sit under the per-filter cap or the button would 413 on a full file.
  const [parsed] = parseFilters(JSON.stringify([filter]));
  assert.equal(parsed.values.length, 4000);
  assert.equal(parsed.field, "__company_ids");
});

test("the coverage result carries the company id, not just its name", async () => {
  const route = codeOnly(await read("../app/api/coverage/route.ts"));
  assert.match(route, /matchedCompanyId: match\?\.id \?\? ""/);
  const types = await read("../lib/types.ts");
  assert.match(types, /CoverageRow = \{[^}]*matchedCompanyId: string/);
});

test("the panel is wired to the Company database, and clears the pivot first", async () => {
  const panel = codeOnly(await read("../app/components/CoveragePanel.tsx"));
  assert.match(panel, /onViewCompanies\(withProspects\)/);
  assert.match(panel, /onViewCompanies\(withoutProspects\)/);
  // Both buttons are disabled when their set is empty, which is what keeps the
  // "no filter at all" case above from ever reaching the workspace.
  assert.match(panel, /disabled=\{!withProspects\.length\}/);
  assert.match(panel, /disabled=\{!withoutProspects\.length\}/);

  const dashboard = codeOnly(await read("../app/DashboardApp.tsx"));
  // navigate() first, exactly as the Data Quality buttons do: it clears the
  // search and the pivot scope, so the rows that arrive are the ones counted.
  assert.match(dashboard, /const viewCoverageCompanies = useCallback[\s\S]{0,240}navigate\("companies"\);\s*setCompanyFilters\(filters\);/);
  assert.match(dashboard, /onViewCompanies=\{viewCoverageCompanies\}/);

  // Opaque ids need a label that carries the whole meaning.
  const filters = await read("../app/ApolloFilterPanel.tsx");
  assert.match(filters, /field === "__company_ids"\) return "Selected companies"/);
});

test("__company_ids is exact in all three company filter paths", async () => {
  const code = codeOnly(await read("../supabase/migrations/20260916110000_open_a_named_set_of_companies.sql"));

  // Builder, row matcher and pre-filter. A missed splice leaves two of them
  // disagreeing, which returns wrong rows rather than an error - so each raises.
  for (const guard of [
    /Could not patch company_filter_sql_v3 for __company_ids/,
    /Could not patch company_matches_filters_v1 for __company_ids/,
    /Could not patch company_prefilter_sql for __company_ids/,
  ]) assert.match(code, guard);

  assert.match(code, /c\.id = any \(%L::text\[\]\)/);
  // The exclude arm must stay OUT of the pre-filter: a pre-filter has to be a
  // necessary condition, and "not in this set" is implied by no index probe.
  const prefilterBlock = code.slice(code.indexOf("company_prefilter_sql"));
  assert.doesNotMatch(prefilterBlock.slice(0, 900), /not \(c\.id = any/);

  // The assertions that make "exact" mean something.
  assert.match(code, /a 500-id filter opened onto % companies/);
  assert.match(code, /companies outside the set survived the filter/);
  assert.match(code, /an empty __company_ids compiled to %, not to a no-op/);
  assert.match(code, /an unknown company id matched % rows/);
});
