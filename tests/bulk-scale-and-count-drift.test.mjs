import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

// company_effective_filter_sql_v1 returns a complete SQL predicate whenever the
// filter set can be expressed in SQL, and callers then skip the per-row function.
// filter_companies_v4 and client_company_workspace_v2 both did this;
// company_scope_ids_v2 never adopted it, so a scope always paid the per-row cost
// with the whole filter payload as jsonb on every row -- invisible on small
// pastes, quadratic on large ones (10,000 domains: 94,614 ms against 860 ms for
// the same filter on the Companies tab).
test("the company scope prefers the complete SQL predicate", async () => {
  const statements = statementsOnly(await read("../supabase/migrations/20260901000080_scope_uses_complete_filter_sql.sql"));

  assert.match(statements, /create or replace function public\.company_scope_ids_v2/i);
  assert.match(statements, /v_complete := public\.company_effective_filter_sql_v1\(v_search, v_filters\)/);
  // The per-row function must remain as the fallback, not be deleted: some filter
  // shapes (company keyword scopes) cannot be expressed in SQL.
  assert.match(statements, /coalesce\(v_complete,/);
  assert.match(statements, /company_matches_filters_v1\(c, %L, %L::jsonb\)/);
  // The unfiltered short-circuit from 20260901000010 has to stay ahead of both.
  assert.match(statements, /if btrim\(v_search\) = '' and v_filters = '\[\]'::jsonb then/);
});

test("the pasted-value ceiling is raised and justified by measurement", async () => {
  const filters = await read("../lib/prospect-filters.ts");
  assert.match(filters, /const maxFilterValues = 5000;/);
  // The number is a measured trade-off, not a guess: keep the evidence next to it.
  assert.match(filters, /10,000\s+860 ms\s+10\.0 s/);
});

// The stored counts are read by company_summaries, the client company listing and
// the Companies tab total. A trigger that stops firing does not make those slow,
// it makes them quietly wrong, so the drift has to be observable somewhere.
test("company count drift is reported alongside index drift", async () => {
  const [migration, types, panel] = await Promise.all([
    read("../supabase/migrations/20260901000090_report_company_count_drift.sql"),
    read("../lib/types.ts"),
    read("../app/components/DataQualityPanel.tsx"),
  ]);
  const statements = statementsOnly(migration);

  assert.match(statements, /create or replace function public\.prospect_index_drift/i);
  assert.match(statements, /'companyCountsDrifted'/);
  // Sampled deliberately: a full check costs 55s cold, which is far too slow for a
  // page load. The sample size must be reported so the number is readable.
  assert.match(statements, /'companyCountsSampled', 2000/);
  assert.match(statements, /order by random\(\)\s*\n\s*limit 2000/);
  // "Drifted" must mean what recompute_company_counts_bulk would write.
  assert.match(statements, /count\(distinct pi\.id\)::integer as prospect_count/);
  assert.match(statements, /count\(distinct cid\)::integer as client_count/);

  // Both new keys are optional, so a database one migration behind still renders.
  assert.match(types, /companyCountsSampled\?: number; companyCountsDrifted\?: number/);
  // Drift must actually degrade the health verdict, not just be displayed.
  assert.match(panel, /!drift\.staleInIndex && !countsDrifted/);
  assert.match(panel, /in a sample of \{formatNumber\(Number\(drift\.companyCountsSampled \?\? 0\)\)\} companies/);
});
