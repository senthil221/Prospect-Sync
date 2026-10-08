import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseCsv, filterChipValue } from "../lib/dashboard-helpers.ts";
import { keywordListCsv, keywordRowsFromTable, isKeywordKind } from "../lib/title-keywords.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// 2026-10-08: Top management - founders, owners, CEOs, MDs and the like - read
// from the job title with an include and an exclude keyword list.
test("the migration seeds both supplied lists and decides with the longest-phrase scan", async () => {
  const migration = await read("../supabase/migrations/20261008110000_top_management_from_job_title.sql");
  const include = parseCsv(await read("../data/top_management_include.csv")).rows.filter((row) => row[0].trim());
  const exclude = parseCsv(await read("../data/top_management_exclude.csv")).rows.filter((row) => row[0].trim());
  assert.equal(include.length, 239);
  assert.equal(exclude.length, 1450);
  for (const [keyword] of [...include, ...exclude]) assert.ok(migration.includes(`('${keyword.replace(/'/g, "''")}', `), keyword);
  assert.match(migration, /order by n\.len desc, n\.start_pos asc/);
  assert.match(migration, /where not \(v_healthcare and n\.phrase = 'md'\)/);
  assert.match(migration, /new\.title_top_management := public\.title_is_top_management_v1\(/);
  assert.match(migration, /title_top_management = public\.title_is_top_management_v1\(classified\.normalized_title/);
  assert.match(migration, /new\.title_is_former, new\.title_normalized, new\.title_top_management/);
  assert.ok(migration.includes("revoke execute on function public.title_is_top_management_v1(text, text) from public, anon, authenticated;"));
  assert.ok(migration.includes("('Vice President Sales', '', false)") && migration.includes("('Founder & CEO', '', true)"));
  assert.match(migration, /Top management proof passed/);
});

test("both top management lists download and upload in the layout of their files", () => {
  assert.ok(isKeywordKind("top_management_include") && isKeywordKind("top_management_exclude") && !isKeywordKind("top"));
  const table = parseCsv(keywordListCsv("top_management_exclude", [{ keyword: "vice president", protects: "president" }]));
  assert.deepEqual(table.headers, ["keyword", "protects"]);
  assert.deepEqual(keywordRowsFromTable("top_management_exclude", table.headers, table.rows), [{ line: 3, keyword: "vice president", protects: "president" }]);
  assert.deepEqual(keywordRowsFromTable("top_management_include", ["keyword"], [["Founder"]]), [{ line: 2, keyword: "Founder", notes: "" }]);
});

test("the People filter offers Top Management", async () => {
  const panel = await read("../app/ApolloFilterPanel.tsx");
  assert.match(panel, /\{ id: "__title_top_management", label: "Top Management", kind: "top_management"/);
  assert.match(panel, /field: "__title_top_management", operator: "equals", values: \[value\]/);
  assert.equal(filterChipValue("__title_top_management", "yes"), "Top management");
  assert.equal(filterChipValue("__title_top_management", "no"), "Not top management");
});
