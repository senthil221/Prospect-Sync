import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { emptyTaxonomy, orderedDepartments, orderedTiers, tierLabel } from "../lib/title-taxonomy.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const codeOnly = (source) => source.split("\n").filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("--")).join("\n");

test("management levels are offered in the classifier's rank order, not alphabetically", () => {
  // Deliberately shuffled: the database returns them sorted by value.
  const tiers = ["entry", "c_suite", "senior_ic", "owner", "manager", "vp", "director"]
    .map((value) => ({ value, count: 1 }));
  assert.deepEqual(orderedTiers(tiers).map((tier) => tier.value),
    ["owner", "c_suite", "vp", "director", "manager", "senior_ic", "entry"]);

  // A tier the CSVs grow that the UI has not been taught about is still offered,
  // after the known ones, rather than disappearing from the picker.
  const withNew = orderedTiers([...tiers, { value: "board_member", count: 3 }]);
  assert.equal(withNew.at(-1).value, "board_member");
  assert.equal(withNew.length, 8);
});

test("stored tier values are labelled as words", () => {
  assert.equal(tierLabel("c_suite"), "C-Suite");
  assert.equal(tierLabel("senior_ic"), "Senior IC");
  assert.equal(tierLabel("vp"), "VP");
  // Unknown values still read as words rather than as column names.
  assert.equal(tierLabel("board_member"), "Board Member");
});

test("departments with people come first, then the rest alphabetically", () => {
  const ordered = orderedDepartments([
    { name: "Quality", count: 0, subs: [] },
    { name: "Sales", count: 67021, subs: [{ name: "Inside Sales", count: 12 }] },
    { name: "Admin", count: 0, subs: [] },
    { name: "Operations", count: 43413, subs: [] },
  ]);
  assert.deepEqual(ordered.map((department) => department.name), ["Operations", "Sales", "Admin", "Quality"]);
  // An empty department is still offered - it reads 0 rather than vanishing, so
  // the picker shows the whole taxonomy and not just what happens to be in the
  // data today.
  assert.equal(ordered.filter((department) => department.count === 0).length, 2);
  assert.deepEqual(emptyTaxonomy.tiers, []);
});

test("the taxonomy is one scan, and the picker owns its nested sub-department", async () => {
  const migration = codeOnly(await read("../supabase/migrations/20260910130000_title_taxonomy_for_the_filter_panel.sql"));
  // Three separate counts would be three passes over 681,785 rows.
  assert.match(migration, /group by grouping sets/);
  // Referenced by three CTEs, so without MATERIALIZED the scan runs three times
  // - measured at 3.0s against 0.7s.
  assert.match(migration, /with counted as materialized/);
  // The structure comes from the keyword tables, so a sub-department added to a
  // CSV reaches the picker with no code change.
  assert.match(migration, /from public\.title_department_keywords/);
  // 'none' is the suppression tier and is never a value anything carries.
  assert.match(migration, /where tier <> 'none'/);

  const panel = await read("../app/ApolloFilterPanel.tsx");
  assert.match(panel, /label: "Management Level", kind: "tiers"/);
  assert.match(panel, /label: "Departments & Job Function", kind: "departments"/);
  // Sub-department is no longer a section of its own: filtering on it alone
  // drops every generic title, because a blank sub means "slice unknown".
  assert.doesNotMatch(codeOnly(panel), /id: "__title_sub_department", label:/);
  // Clearing the section has to take the nested filter with it.
  assert.match(panel, /field === "__title_department" \? \["__title_department", "__title_sub_department"\]/);
  // Checking several levels is one filter carrying several values, which the
  // compiler turns into an IN - verified on production as owner + c_suite
  // returning exactly the sum of the two.
  assert.match(panel, /operator: "equals", values: \[\.\.\.next\]/);
});
