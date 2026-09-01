import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

const wired = () => read("../supabase/migrations/20260902000020_people_workspace_uses_complete_sql.sql");
const bounded = () => read("../supabase/migrations/20260902000030_translate_boolean_filters.sql");

// 20260902000000 wired the complete-SQL translation into the scope function only,
// so the People tab itself still called prospect_index_matches_v1 per row: a plain
// title filter took 38s where the same predicate as SQL took 0.55s.
test("the People workspace and export use the complete translation", async () => {
  const statements = statementsOnly(await wired());

  for (const fn of ["search_prospect_workspace_v12", "search_prospect_export_v4"]) {
    assert.match(statements, new RegExp(`create or replace function public\\.${fn}`, "i"));
  }
  // Both must prefer the translation and keep the row function only as a fallback.
  const fallbacks = statements.match(/coalesce\(v_complete,/g) ?? [];
  assert.equal(fallbacks.length, 2, "both entry points must fall back rather than assume");
  assert.match(statements, /prospect_index_matches_v1\(pi, %L, %L::jsonb\)/);
});

// A filter set that fell back wholesale because of one Boolean among thirty made
// performance depend on which filter was chosen rather than on the work implied.
test("every operator is translated, so no set falls back wholesale", async () => {
  const statements = statementsOnly(await bounded());

  assert.doesNotMatch(statements, /if operator_key = 'boolean' then return null; end if;/,
    "bailing out on Boolean is the cliff this removes");
  assert.match(statements, /to_tsvector\(''simple'', %s\) @@ to_tsquery\(''simple'', needle\)/);
  assert.match(statements, /to_tsvector\(%L, %s\) @@ to_tsquery\(%L, %L\)/);
});

// contains / not_contains / boolean emitted one expression per value, each
// carrying a full copy of the candidate expression -- and a custom: field's
// candidate is an entire jsonb subquery.
test("generated SQL is bounded by filters, not by filters times values", async () => {
  const statements = statementsOnly(await bounded());

  assert.match(statements, /bulk_or_threshold constant integer := 40;/);
  // Above the threshold: one array literal, one copy of the candidate.
  assert.match(statements, /if cardinality\(raw_values\) > bulk_or_threshold then/);
  assert.match(statements, /not exists \(select 1 from unnest\(%L::text\[\]\) needle where %s ilike ''%%'' \|\| needle \|\| ''%%''\)/);
  // The OR chain survives below the threshold, where the trigram index can serve it.
  assert.match(statements, /array_to_string\(value_parts, ' or '\)/);
});

// A prefilter exists to narrow via an index. The substring branch above 40 values
// built its pattern per row, so no index could serve it -- and the authoritative
// predicate tested the same thing again, making every candidate pay twice.
test("the prefilters emit nothing they cannot serve with an index", async () => {
  const statements = statementsOnly(await bounded());

  for (const fn of ["prospect_prefilter_sql", "company_prefilter_sql"]) {
    assert.match(statements, new RegExp(`create or replace function public\\.${fn}`, "i"));
  }
  // Neither prefilter may emit the correlated lateral any more.
  assert.doesNotMatch(
    statements,
    /conjuncts := conjuncts \|\| format\(\s*\n\s*'exists \(select 1 from unnest\(%L::text\[\]\) needle where %s ilike/,
    "an unindexable prefilter is duplicated work, not narrowing",
  );
  // Dropping a conjunct widens the prefilter, which keeps it a valid superset.
  assert.match(statements, /null;/);
});
