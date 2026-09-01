import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = () =>
  readFile(new URL("../supabase/migrations/20260902000000_prospect_filter_sql.sql", import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

// Every prospect predicate existed twice: an indexable prefilter and the
// authoritative per-row prospect_index_matches_v1. Whenever the whole match set
// was needed -- a scope, a count, an export -- every candidate row paid a
// non-inlinable function call. Companies have had company_filter_sql_v2 for this
// since long before; the prospect side never had an equivalent, which is why
// See Companies timed out and surfaced as "Failed to fetch".
test("prospect filters have a complete-SQL translation", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.prospect_filter_sql_v1/i);
  assert.match(statements, /create or replace function public\.prospect_effective_filter_sql_v1/i);
  // Same contract as the company pair: prefilter for the index path, complete
  // predicate for exactness, null when it cannot express the set.
  assert.match(statements, /v_complete text := public\.prospect_filter_sql_v1/);
  assert.match(statements, /if v_complete is null then return null; end if;/);
});

test("null is the fallback, so a gap costs speed and never correctness", async () => {
  const statements = statementsOnly(await migration());

  // Boolean carries a compiled tsquery, so the whole set is handed back.
  assert.match(statements, /if operator_key = 'boolean' then return null; end if;/);
  // The caller must keep the row function as the fallback rather than assuming
  // the translation always succeeds.
  assert.match(statements, /coalesce\(v_complete,\s*\n?\s*format\('public\.prospect_index_matches_v1\(pi, %L, %L::jsonb\)'/);
});

test("the translation mirrors the row function rather than improving on it", async () => {
  const statements = statementsOnly(await migration());

  // Field shapes that are not plain columns are the easiest to get subtly wrong.
  assert.match(statements, /concat_ws\('' '', pi\.work_email, pi\.personal_email\)/);
  assert.match(statements, /array_to_string\(pi\.keywords, '' \| ''\)/);
  assert.match(statements, /jsonb_each_text\(pi\.all_data\)/);
  // __lists and __clients match a whole array element as well as the joined
  // string; dropping that would silently change equals results.
  assert.match(statements, /pi\.list_names' else 'pi\.client_names'/);
  assert.match(statements, /&& %L::text\[\]/);
  // Null columns behave as empty, exactly as the row function coalesces them.
  assert.match(statements, /candidate_expr := format\('coalesce\(%s, %L\)', candidate_expr, ''\)/);
  // A value-less operator rejects every row in the row function; a no-op here
  // would silently widen results.
  assert.match(statements, /conjuncts := array_append\(conjuncts, 'false'\)/);
});

// v_conditions/conjuncts are text[]. Appending a bare string literal makes the
// parser read `array || unknown` as anyarray || anyarray and fail at runtime --
// the same defect that broke the __last_contacted filter in 20260901000070.
test("conjuncts are appended in a form that does not depend on literal typing", async () => {
  const statements = statementsOnly(await migration());
  for (const line of statements.split("\n").filter((l) => /conjuncts := conjuncts \|\|/.test(l))) {
    assert.match(line, /\|\| (format\(|\()/, `bare literal appended to a text[]: ${line.trim()}`);
  }
});
