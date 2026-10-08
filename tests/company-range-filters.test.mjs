import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// 2026-10-08: People filtered by Total funding timed out - one company probe per
// person. Ranges now resolve the matching companies first.
test("company range filters compile to a companies-first IN, with Not known kept as NOT EXISTS", async () => {
  const sql = await readFile(new URL("../supabase/migrations/20261009100000_company_range_filters_resolve_companies_first.sql", import.meta.url), "utf8");
  assert.ok(sql.includes("company_inner := format('pi.company_id in (select co.id from public.companies co where (%s))',"));
  assert.ok(sql.includes("company_inner := format('exists (select 1 from public.companies co where co.id = pi.company_id and (%s))',"), "the replaced anchor");
  assert.match(sql, /"unknown"/);
  assert.match(sql, /prospect_index_matches_v1\(pi, '''', %L::jsonb\)/);
  assert.match(sql, /Company range proof passed/);
});
