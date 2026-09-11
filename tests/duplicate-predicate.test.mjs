import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260911140000_stop_evaluating_the_same_filter_twice_per_row.sql";

test("a prefilter identical to the exact filter is not ANDed with itself", async () => {
  const migration = await read(migrationPath);

  // X and X is X. For a plain search and for any single-field filter the
  // prefilter and the exact filter are the same expression, so the second copy
  // narrows nothing and costs a full evaluation per row.
  assert.ok(migration.includes("v_prefilter <> 'true' and v_prefilter is distinct from v_complete"));
  // Combining is kept for the case it was built for - a prefilter that really
  // is narrower still earns its place.
  assert.ok(migration.includes("return '(' || v_prefilter || ') and (' || v_complete || ')';"));
});

test("the large function is patched by marker, never rewritten", async () => {
  const migration = await read(migrationPath);

  // search_prospect_workspace_v12 is long and carries a lot of hard-won
  // behaviour. Reading the live definition and replacing one line means nothing
  // else in it can drift.
  assert.ok(migration.includes("pg_get_functiondef("));
  assert.ok(migration.includes("refusing to patch blindly"));
  // CREATE OR REPLACE drops proconfig, and 20260902000040 put a ceiling there.
  assert.ok(migration.includes("lost its 10s statement timeout in the replace"));
});

test("the answers are compared against this database, not against reasoning", async () => {
  const migration = await read(migrationPath);

  // Captured before the patch exists, compared after.
  assert.ok(migration.includes("create temp table search_baseline on commit drop"));
  for (const check of [
    "a plain search returns a different count than before",
    "a single-filter search returns a different count than before",
    "combining a search with a filter no longer returns the same count",
    "the first page of a filtered search changed",
    "the company pivot scope resolves a different set of companies",
  ]) {
    assert.ok(migration.includes(check), "missing assertion: " + check);
  }
});

test("search-and-filter is covered, because that is the path still combining", async () => {
  const migration = await read(migrationPath);

  // The risk in this change is not the case it optimises, it is the case it
  // must leave alone: a search plus a filter, where prefilter and exact filter
  // genuinely differ and the AND still has to happen.
  const baseline = migration.slice(migration.indexOf("create temp table"), migration.indexOf("-- Companies:"));
  assert.ok(baseline.includes("search_and_filter"));
  assert.ok(baseline.includes("page_fingerprint"));
  // Not only counts: the page itself, row for row.
  assert.ok(baseline.includes("md5(result_rows::text)"));
});
