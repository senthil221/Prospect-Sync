import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseCsv } from "../lib/dashboard-helpers.ts";
import { keywordListCsv, keywordRowsFromTable } from "../lib/title-keywords.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// 2026-10-08: the keyword lists are downloaded, extended and uploaded from the
// Job titles tab instead of only through the developer sync script.
test("a downloaded keyword list uploads back as the same rows, # notes skipped", () => {
  const csv = keywordListCsv("department", [
    { keyword: "sales", department: "Sales", sub_department: "", notes: "" },
    { keyword: "r&d head", department: "R&D", sub_department: "Research", notes: "has, a comma" },
  ]);
  const table = parseCsv(csv);
  assert.deepEqual(keywordRowsFromTable("department", table.headers, table.rows), [
    { line: 3, keyword: "sales", department: "Sales", sub_department: "", notes: "" },
    { line: 4, keyword: "r&d head", department: "R&D", sub_department: "Research", notes: "has, a comma" },
  ]);
});

test("an upload needs the keyword and value columns; loose header names are fine", () => {
  assert.throws(() => keywordRowsFromTable("seniority", ["keyword"], [["ceo"]]), /needs a tier column/);
  assert.deepEqual(keywordRowsFromTable("seniority", ["Keyword", "Tier"], [["Chief Bottle Washer", "c_suite"], ["", ""]]),
    [{ line: 2, keyword: "Chief Bottle Washer", tier: "c_suite", notes: "" }]);
});

test("uploads are checked by the database first and never delete keywords", async () => {
  const migration = await read("../supabase/migrations/20261008100000_title_keyword_lists_from_the_app.sql");
  assert.match(migration, /public\.normalize_job_title_v1\(coalesce\(r\.value->>'keyword', ''\)\)/);
  assert.doesNotMatch(migration, /delete from public\.title_(seniority|department)_keywords/);
  for (const fn of ["title_keywords_export_v1(text)", "apply_title_keywords_v1(text, jsonb, boolean)"]) {
    assert.ok(migration.includes(`revoke execute on function public.${fn} from public, anon, authenticated;`), fn);
  }
  assert.match(migration, /Title keyword proof passed/);
  const route = await read("../app/api/prospects/title-keywords/route.ts");
  assert.equal((route.match(/await authorizeApi\(\)/g) ?? []).length, 2);
  assert.match(route, /p_dry_run: payload\.apply !== true/);
  const panel = await read("../app/components/TitleClassifierPanel.tsx");
  assert.match(panel, /postKeywords\(kind, rows, false\)/);
  assert.match(panel, /saved = await postKeywords\(upload\.kind, upload\.rows, true\);/);
  assert.match(panel, /await reclassify\(\);\n  \}/);
  const script = await read("../scripts/sync-title-keywords.mjs");
  assert.match(script, /const stale = prune \?/);
});
