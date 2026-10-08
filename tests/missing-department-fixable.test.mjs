import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseCsv } from "../lib/dashboard-helpers.ts";
import { keywordDepartments, keywordRowsFromTable } from "../lib/title-keywords.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// 2026-10-08: of 425,703 people with no department, only the ~104k whose title
// names an unknown function count as missing one; Education and Healthcare join.
test("the gap list asks for a department only where a keyword could give one", async () => {
  const migration = await read("../supabase/migrations/20261008120000_missing_department_means_fixable.sql");
  assert.match(migration, /p\.title_department = '' and not p\.title_top_management as no_department/);
  assert.match(migration, /c\.no_department and n\.needs_department as no_department/);
  assert.match(migration, /join needs n on n\.title_normalized = coalesce\(c\.title_normalized, ''\)/, "hashable join, not is not distinct from");
  assert.ok(migration.includes("revoke execute on function public.title_needs_department_v1(text) from public, anon, authenticated;"));
  assert.match(migration, /'R&D', 'Education', 'Healthcare'\)/);
  assert.match(migration, /Missing department proof passed/);
});

test("Education and Healthcare are departments, and the supplied additions upload cleanly", async () => {
  assert.ok(keywordDepartments.includes("Education") && keywordDepartments.includes("Healthcare"));
  assert.match(await read("../scripts/sync-title-keywords.mjs"), /"R&D", "Education", "Healthcare",/);
  const table = parseCsv(await read("../data/department_additions_2026-10-08.csv"));
  const rows = keywordRowsFromTable("department", table.headers, table.rows);
  assert.equal(rows.length, 132);
  for (const row of rows) assert.ok(keywordDepartments.includes(row.department), `${row.keyword}: ${row.department}`);
  assert.equal(new Set(rows.map((row) => row.keyword)).size, rows.length);
});
