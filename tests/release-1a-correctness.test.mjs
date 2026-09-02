import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  FilterLimitError,
  filterErrorResponse,
  maxBooleanValueLength,
  maxFilterValues,
  maxFilters,
  maxValueLength,
  parseFilters,
} from "../lib/prospect-filters.ts";

// Release 1A of the scalability plan: one export path, no silent truncation, no
// untimed hot function. These are the correctness fixes that ship ahead of the
// staging work, so each one is pinned here rather than left to a soak test.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("every prospect export runs the same predicate as the grid above it", async () => {
  const [route, exportV4, exportV1, columns, compiler] = await Promise.all([
    read("../app/api/prospects/export/route.ts"),
    read("../supabase/migrations/20260902000020_people_workspace_uses_complete_sql.sql"),
    read("../supabase/migrations/20260811000000_prospect_search_index.sql"),
    read("../lib/prospect-export.ts"),
    read("../supabase/migrations/20260902000050_restore_combined_title_and_esp_filters.sql"),
  ]);

  // One function, chosen unconditionally. The scope is always passed, empty or
  // not, so there is no second code path to keep in step.
  assert.match(route, /supabase\.rpc\("search_prospect_export_v4"/);
  assert.doesNotMatch(route, /search_prospect_export_v1/);
  assert.match(route, /p_company_scope: companyScope \?\? \{\}/);

  // v4 compiles the predicate through prospect_filter_sql_v1 -- the same
  // compiler search_prospect_workspace_v12 uses, in the same migration.
  const v4Body = exportV4.slice(exportV4.indexOf("search_prospect_export_v4"));
  assert.match(v4Body, /prospect_filter_sql_v1/);
  assert.match(exportV4, /search_prospect_workspace_v12[\s\S]*prospect_filter_sql_v1/);

  // The measured drift this removes: v1's inlined CASE never learned
  // __company_domain, so that filter fell through to its `else ''` arm and the
  // export ignored it, while the grid's compiler matched on it. Verified against
  // production at 20260902000030 by comparing the field sets of
  // search_prospect_export_v1, prospect_filter_sql_v1 and prospect_index_matches_v1.
  assert.doesNotMatch(exportV1.slice(exportV1.indexOf("search_prospect_export_v1")), /__company_domain/);
  assert.match(compiler, /when '__company_domain' then 'pi\.company_domain'/);

  // Parity coverage named in section 4.2: classifier fields and stored location
  // are exportable columns, so an export can be compared with the grid on them.
  for (const columnId of ["__title_seniority_tier", "__title_department", "__title_sub_department", "__person_location"]) {
    assert.ok(columns.includes(`id: "${columnId}"`), `${columnId} must be an export column`);
  }
  // Stored location wins; the parts are only the fallback.
  assert.match(columns, /String\(row\.location \?\? ""\)\.trim\(\) \|\|/);
});

test("an over-cap request is refused, not trimmed to fit", () => {
  const overFilters = Array.from({ length: maxFilters + 1 }, () => ({ field: "__title", operator: "contains", values: ["x"] }));
  assert.throws(() => parseFilters(JSON.stringify(overFilters)), (error) => {
    assert.ok(error instanceof FilterLimitError);
    assert.equal(error.kind, "filters");
    assert.equal(error.received, maxFilters + 1);
    assert.equal(error.allowed, maxFilters);
    assert.equal(error.field, null);
    assert.ok(error.alternative.length > 0);
    return true;
  });

  const overValues = Array.from({ length: maxFilterValues + 1 }, (_, index) => `v${index}`);
  assert.throws(() => parseFilters(JSON.stringify([{ field: "__website", operator: "equals", values: overValues }])), (error) => {
    assert.ok(error instanceof FilterLimitError);
    assert.equal(error.kind, "values");
    assert.equal(error.field, "__website");
    assert.equal(error.allowed, maxFilterValues);
    return true;
  });

  // A single value longer than the cap used to be cut mid-string, which silently
  // widened the filter: a company name trimmed to its first word matches far more
  // rows than the user asked for.
  const longValue = "a".repeat(maxValueLength + 1);
  assert.throws(() => parseFilters(JSON.stringify([{ field: "__title", operator: "contains", values: [longValue] }])), (error) => {
    assert.ok(error instanceof FilterLimitError);
    assert.equal(error.kind, "value_length");
    assert.equal(error.allowed, maxValueLength);
    return true;
  });

  // A Boolean value is one compiled expression and gets its own, larger budget.
  const longBoolean = `"${"b".repeat(maxValueLength + 20)}"`;
  assert.equal(parseFilters(JSON.stringify([{ field: "__title", operator: "boolean", values: [longBoolean] }])).length, 1);
  assert.throws(
    () => parseFilters(JSON.stringify([{ field: "__title", operator: "boolean", values: ["c".repeat(maxBooleanValueLength + 1)] }])),
    (error) => error instanceof FilterLimitError && error.allowed === maxBooleanValueLength,
  );

  // Unknown fields and operators are still dropped rather than refused: they
  // select nothing either way, so a stale saved view is not a hard failure.
  assert.deepEqual(parseFilters(JSON.stringify([{ field: "", operator: "contains", values: ["x"] }])), []);
  assert.deepEqual(parseFilters(JSON.stringify([{ field: "__title", operator: "drop table", values: ["x"] }])), []);
});

test("a refused request answers 413 with the numbers needed to fix it", async () => {
  let rejection;
  try {
    parseFilters(JSON.stringify([{
      field: "__website",
      operator: "equals",
      values: Array.from({ length: maxFilterValues + 5 }, (_, index) => `v${index}`),
    }]));
  } catch (error) { rejection = error; }

  const response = filterErrorResponse(rejection, "unused fallback");
  assert.equal(response.status, 413);
  const body = await response.json();
  assert.equal(body.limit, "values");
  assert.equal(body.received, maxFilterValues + 5);
  assert.equal(body.allowed, maxFilterValues);
  assert.equal(body.field, "__website");
  assert.ok(body.alternative.includes(String(maxFilterValues)));
  // The remedy rides along in `error` too, because that is the one string every
  // current UI surface renders (lib/dashboard-api.ts).
  assert.ok(body.error.includes(body.alternative));

  // A malformed Boolean expression is a bad request, not an over-cap one.
  let compileError;
  try { parseFilters(JSON.stringify([{ field: "__title", operator: "boolean", values: ["(unclosed"] }])); }
  catch (error) { compileError = error; }
  assert.ok(compileError && !(compileError instanceof FilterLimitError));
  assert.equal(filterErrorResponse(compileError, "fallback").status, 400);

  // Anything that is not an Error at all still gets the caller's fallback.
  const fallback = await filterErrorResponse("not an error", "Invalid filter.").json();
  assert.equal(fallback.error, "Invalid filter.");
});

test("every filter entry point rejects through the one shared path", async () => {
  const routes = [
    "../app/api/prospects/route.ts",
    "../app/api/prospects/export/route.ts",
    "../app/api/companies/route.ts",
    "../app/api/clients/[id]/companies/route.ts",
    "../app/api/clients/[id]/prospects/route.ts",
    "../app/api/saved-views/route.ts",
  ];
  for (const path of routes) {
    const source = await read(path);
    assert.match(source, /filterErrorResponse/, `${path} must reject through filterErrorResponse`);
    // A bare `catch { ... 400 }` around a filter parse swallows the limit and
    // answers 400 with no numbers, which is what this replaces.
    assert.doesNotMatch(source, /catch \{ return Response\.json/, `${path} still has an untyped filter catch`);
  }
});

test("a saved view above the cap is flagged for review, never rewritten or deleted", async () => {
  const [route, table, types] = await Promise.all([
    read("../app/api/saved-views/route.ts"),
    read("../app/components/ProspectTable.tsx"),
    read("../lib/types.ts"),
  ]);

  // GET annotates; it does not write. The only writes in this file stay in POST
  // (upsert) and DELETE.
  assert.match(route, /function reviewFlag/);
  assert.match(route, /needsReview/);
  const getBlock = route.slice(route.indexOf("export async function GET"), route.indexOf("export async function POST"));
  assert.doesNotMatch(getBlock, /\.upsert\(|\.update\(|\.delete\(/);

  // A new view that could never be executed is refused at save time.
  assert.match(route, /return filterErrorResponse\(error, "This view's filters are not valid\."\)/);

  // The UI names the problem instead of applying a view every request refuses.
  assert.match(table, /view\.needsReview/);
  assert.match(table, /needs review/);
  assert.match(types, /needsReview\?: SavedViewReview/);
});

test("the two combined People filters compile to a real predicate again", async () => {
  const [migration, panel] = await Promise.all([
    read("../supabase/migrations/20260902000050_restore_combined_title_and_esp_filters.sql"),
    read("../app/ApolloFilterPanel.tsx"),
  ]);

  // Both are still offered in the panel, so both have to mean something.
  assert.match(panel, /id: "__title_seniority", label: "Job Title & Seniority"/);
  assert.match(panel, /id: "__esp_type", label: "ESP"/);

  // The compiler emits the concatenation, not the empty string it used to.
  assert.match(migration, /when '__title_seniority' then 'concat_ws\('' '', pi\.title, pi\.seniority\)'/);
  assert.match(migration, /when '__esp_type' then 'concat_ws\('' '', pi\.esp, pi\.email_provider_type\)'/);

  // The row predicate is the fallback whenever the compiler returns null (a
  // Boolean filter does), so it has to agree rather than disagree quietly.
  assert.match(migration, /when '__title_seniority' then concat_ws\(' ', \(p_row\)\.title, \(p_row\)\.seniority\)/);
  assert.match(migration, /when '__esp_type' then concat_ws\(' ', \(p_row\)\.esp, \(p_row\)\.email_provider_type\)/);

  // Written out in full, because a splice is exactly how these arms were lost:
  // 20260825010000 recreated the row function and the 20260814060000 splice went
  // with it, silently.
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.prospect_filter_sql_v1/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.prospect_index_matches_v1/);
  // No runtime splice: both definitions are written out, so nothing here can
  // find no anchor and skip. (The header names pg_get_functiondef as the source
  // the bodies were read from; it must not appear as executable SQL.)
  const executable = migration.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");
  assert.doesNotMatch(executable, /pg_get_functiondef/);
  assert.doesNotMatch(executable, /execute replace\(/);

  // The pre-filter is deliberately untouched: a concat of two columns cannot be
  // index-served, and it already skips fields it cannot map, which widens it.
  assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION public\.prospect_prefilter_sql/);
});

test("the hot functions that had no statement timeout now have one", async () => {
  const [migration, verify] = await Promise.all([
    read("../supabase/migrations/20260902000040_time_out_untimed_hot_functions.sql"),
    read("../scripts/verify-migrations.sql"),
  ]);

  for (const signature of [
    "public.linked_prospect_total_v1(text)",
    "public.prospect_filter_values_v3(text, text, text, integer)",
    "public.search_prospect_export_v1(text, jsonb, text, timestamptz, text, integer, boolean)",
  ]) {
    assert.ok(migration.includes(`alter function ${signature}`), `${signature} must get a timeout`);
  }
  assert.match(migration, /set statement_timeout = '20s'/);
  assert.match(migration, /set statement_timeout = '30s'/);
  assert.match(migration, /set statement_timeout = '60s'/);

  // ALTER FUNCTION carries no body, so nothing here can drift from the deployed
  // definition -- but a later CREATE OR REPLACE would drop the setting, and only
  // the verification script would notice.
  assert.doesNotMatch(migration, /create or replace function/i);
  assert.match(verify, /no SECURITY DEFINER search\/filter function is left untimed/);
});

test("a statement timeout is reported as an actionable 504, not a 500", async () => {
  const [helper, ...routes] = await Promise.all([
    read("../lib/api-errors.ts"),
    read("../app/api/prospects/route.ts"),
    read("../app/api/prospects/export/route.ts"),
    read("../app/api/companies/route.ts"),
    read("../app/api/prospects/filter-values/route.ts"),
    read("../app/api/companies/filter-values/route.ts"),
  ]);

  assert.match(helper, /57014/);
  assert.match(helper, /status: 504/);
  // Not a 503 with a Retry-After header: the identical request would exceed the
  // identical ceiling, so inviting a retry would be a lie. (The prose above the
  // helper says so; this checks the header is not actually emitted.)
  assert.doesNotMatch(helper, /"Retry-After"/);
  assert.doesNotMatch(helper, /status: 503/);

  for (const source of routes) {
    assert.match(source, /isStatementTimeout/);
    assert.match(source, /statementTimeoutResponse\(/);
  }
});
