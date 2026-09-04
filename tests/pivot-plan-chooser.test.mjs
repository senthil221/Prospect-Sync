import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");
const migration = () => read("../supabase/migrations/20260902000220_pivot_uses_the_same_plan_chooser.sql");

// Reported: "See People" returned the statement-timeout message on a filter the
// Companies tab had just answered in about six seconds. 20260902000190 taught
// filter_companies_v4 to choose between the OR chain and the index probe, and
// taught it nowhere else, so the pivot's scope resolver still used the chain:
// 41,057 ids in 24,833ms against a 20s statement_timeout inside
// search_prospect_workspace_v12. Measured after: 5,837ms, same ids.
test("the scope resolver chooses a plan instead of always using the chain", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.company_scope_ids_v2/i);
  const resolver = statements.slice(statements.indexOf("FUNCTION public.company_scope_ids_v2"));
  assert.match(resolver, /v_complete := public\.company_full_scan_filter_sql_v1\(v_search, v_filters\);/);
  // The per-row fallback for untranslatable filters must survive.
  assert.match(resolver, /company_matches_filters_v1\(c, %L, %L::jsonb\)/);
});

// The first cut of 20260902000190 took the same decision in two places and they
// disagreed, which cost __company_location its prefilter for nothing. One
// chooser, asked by everything that scans a whole company match set.
test("there is exactly one full-scan plan chooser, and both callers ask it", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.company_full_scan_filter_sql_v1/i);
  const asks = statements.match(/public\.company_full_scan_filter_sql_v1\(/g) ?? [];
  // One definition plus two call sites.
  assert.ok(asks.length >= 3, `expected a definition and two callers, found ${asks.length}`);

  // The listing must no longer carry its own copy of the sampling block.
  const listing = statements.slice(statements.indexOf("FUNCTION public.filter_companies_v4"));
  assert.doesNotMatch(listing, /tablesample system/,
    "a second copy of the sampling block is a second decision waiting to drift");
  assert.match(listing, /v_counting_clause := coalesce\(\s*\n?\s*public\.company_full_scan_filter_sql_v1/);
});

// Collecting every id has no early exit, which is the exact-count case, not the
// capped one. The two thresholds exist precisely because they answer different
// questions.
test("the chooser uses the full-scan threshold, not the capped one", async () => {
  const statements = statementsOnly(await migration());

  const chooser = statements.slice(
    statements.indexOf("function public.company_full_scan_filter_sql_v1"),
    statements.indexOf("FUNCTION public.company_scope_ids_v2"));
  assert.match(chooser, /v_broad_fraction constant numeric := 0\.72;/);
  assert.doesNotMatch(chooser, /0\.40/, "0.40 is the capped-count boundary and does not apply here");
  // Sampled, because EXPLAIN raises 0A000 in a non-volatile function.
  assert.match(chooser, /tablesample system \(0\.05\) repeatable \(1\)/);
  assert.doesNotMatch(chooser, /explain/i);
  // A shape is an optimisation; failing to pick one must not fail the query.
  assert.match(chooser, /exception when others then[\s\S]{0,160}return v_complete;/);
});

// An untranslatable filter still has to work, just slowly, as it did before.
test("a filter the translator cannot express still falls back", async () => {
  const statements = statementsOnly(await migration());

  const chooser = statements.slice(statements.indexOf("function public.company_full_scan_filter_sql_v1"));
  assert.match(chooser, /if v_complete is null then return null; end if;/);
  // And with no probeable filter, the chain is returned unchanged rather than
  // the sample being taken for nothing.
  assert.match(chooser, /if v_probe is null then return v_complete; end if;/);
});

test("the new chooser and both rewritten functions are locked to service_role", async () => {
  const statements = statementsOnly(await migration());

  for (const signature of [
    "public.company_full_scan_filter_sql_v1(text, jsonb)",
    "public.company_scope_ids_v2(text, jsonb)",
    "public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer, jsonb)",
  ]) {
    const escaped = signature.replace(/[.()[\]]/g, (character) => `\\${character}`);
    assert.match(statements, new RegExp(`revoke execute on function ${escaped} from public, anon, authenticated;`));
    assert.match(statements, new RegExp(`grant execute on function ${escaped} to service_role;`));
  }
});
