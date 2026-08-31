import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// "See People" sends {"search":"","filters":[],"limit":250000} even when nothing
// is filtered. Deciding whether to join on `scope <> '{}'` treats that as a real
// restriction, which cost 97,967 ms on the People list and silently dropped every
// prospect outside the 250,000-company cap -- 151,465 of 674,804 rows, 22.4%.
//
// A scope restricts only when it carries a company search or company filters.

const migration = () =>
  readFile(new URL("../supabase/migrations/20260901000010_scope_only_when_it_restricts.sql", import.meta.url), "utf8");

test("both prospect entry points join the company scope only when it restricts", async () => {
  const sql = await migration();

  // The predicate must test the contents of the scope, not merely that it is a
  // non-empty object. Asserted twice: the workspace and the export each declare it.
  const restrictingTest = /v_has_scope boolean := v_scope <> '\{\}'::jsonb\s*\n\s*and \(btrim\(coalesce\(v_scope->>'search', ''\)\) <> ''\s*\n\s*or coalesce\(v_scope->'filters', '\[\]'::jsonb\) <> '\[\]'::jsonb\)/g;
  assert.equal((sql.match(restrictingTest) ?? []).length, 2,
    "both search_prospect_workspace_v12 and search_prospect_export_v4 must gate on a restricting scope");

  // The export previously had no branch at all -- it always emitted the CTE and
  // the join inline. Both must now come from the conditional variables.
  assert.doesNotMatch(sql, /with eligible_companies as materialized/);
  assert.match(sql, /create or replace function public\.search_prospect_export_v4/i);
  assert.match(sql, /create or replace function public\.search_prospect_workspace_v12/i);

  // When unscoped the CTE and join are empty strings, so the query shape must be
  // built from them rather than hardcoding the join.
  assert.match(sql, /v_scope_cte := '';/);
  assert.match(sql, /v_scope_join := '';/);
});

test("an unfiltered scope never reaches the per-row company predicate", async () => {
  const sql = await migration();

  assert.match(sql, /create or replace function public\.company_scope_ids_v2/i);
  // The guard must come before the branch that builds a company_matches_filters_v1
  // call, otherwise it does not save anything.
  const guard = sql.indexOf("if btrim(v_search) = '' and v_filters = '[]'::jsonb then");
  const rowFunctionCall = sql.indexOf("public.company_matches_filters_v1(c, %L, %L::jsonb)");
  assert.ok(guard > 0, "company_scope_ids_v2 needs the unfiltered guard");
  assert.ok(rowFunctionCall > guard,
    "the guard must short-circuit before the per-row predicate is assembled");
});
