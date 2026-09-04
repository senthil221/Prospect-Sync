import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

const probes = () => read("../supabase/migrations/20260902000190_probe_the_index_once_per_value.sql");

// The reported failure: "Company keywords" with the description scope and 50
// pasted keywords returned 504. The predicate was a row filter -- 50 values
// across two substring scopes is 100 ILIKEs re-tested against all 419,214
// companies -- so nothing could use the trigram indexes and the cost grew with
// the paste.
test("a second, index-driven shape exists for many-valued substring filters", async () => {
  const statements = statementsOnly(await probes());

  assert.match(statements, /create or replace function public\.company_substring_probe_sql_v1/i);
  // The value list drives the scan and the index is what gets read, so the work
  // is values x matches rather than values x rows.
  assert.match(statements, /select p\.id from unnest\(%L::text\[\]\) needle join public\.companies p on p\.%I ilike/);
  assert.match(statements, /cardinality\(coalesce\(p_values, array\[\]::text\[\]\)\) >= 8/);
});

// Neither shape wins outright: broad needles each match a quarter of the table,
// so probing reads more than scanning; selective needles match nothing early, so
// scanning pays all 100 ILIKEs per row. Replacing one with the other would have
// traded the reported timeout for a different one.
test("the probe is an addition, not a replacement", async () => {
  const statements = statementsOnly(await probes());

  // Every existing caller keeps the OR chain byte for byte.
  assert.match(statements, /create or replace function public\.company_filter_sql_v2[\s\S]*?select public\.company_filter_sql_v3\(p_search, p_filters, false\);/i);
  // The probe shape is reachable only through its own entry point.
  assert.match(statements, /create or replace function public\.company_probe_filter_sql_v1/i);
  assert.match(statements, /return public\.company_filter_sql_v3\(p_search, p_filters, true\);/);
  // And it returns null when nothing in the set can be probed, so the caller
  // knows there is no alternative to choose.
  assert.match(statements, /if not probeable then return null; end if;/);
});

// page walks idx_companies_prospect_ranking and stops at fifty, which is fast at
// any selectivity (0.07s broad, 0.25s selective); the probe shape is 10x-180x
// worse at it. Only the capped count -- the scan that must look at everything
// when little matches -- may switch.
test("only the capped count may change shape; the page never does", async () => {
  const statements = statementsOnly(await probes());

  assert.match(statements, /v_capped_clause := v_probe;/);
  // Two distinct WHERE clauses, and the page's is built from the match clause.
  assert.match(statements, /v_where := format\('\(%s\)', v_match_clause\) \|\| v_scope_suffix;/);
  assert.match(statements, /v_where_capped := format\('\(%s\)', v_capped_clause\) \|\| v_scope_suffix;/);
  // The scope and client conditions must reach both, or the two scans would
  // disagree about which rows are in play.
  assert.doesNotMatch(statements, /v_where := v_where \|\| /,
    "appending to v_where alone would leave the capped scan unscoped");
});

// EXPLAIN raises 0A000 "not allowed in a non-volatile function" and
// filter_companies_v4 is STABLE, so an earlier version failed on every single
// request inside its own exception handler -- the probe shape was never once
// chosen, and nothing said so short of an end-to-end timing run.
test("the shape is chosen from a sample, never from EXPLAIN", async () => {
  const statements = statementsOnly(await probes());

  assert.doesNotMatch(statements, /explain \(format json\)/i,
    "EXPLAIN cannot run inside this STABLE function and fails silently if attempted");
  assert.match(statements, /tablesample system \(0\.05\) repeatable \(1\)/);
  assert.match(statements, /v_broad_fraction constant numeric := 0\.40;/);
  assert.match(statements, /if v_fraction < v_broad_fraction then/);
  // An empty sample must read as "keep today's shape", not as "probe".
  assert.match(statements, /coalesce\(avg\(case when %s then 1\.0 else 0\.0 end\), 1\.0\)/);
  // Per-row sample cost grows with the value list, so the product is bounded.
  assert.match(statements, /v_sample_rows := greatest\(120, least\(400, 60000 \/ greatest\(v_value_count, 1\)\)\);/);
  // Choosing a shape is an optimisation and must never decide correctness.
  assert.match(statements, /exception when others then[\s\S]{0,220}v_capped_clause := v_match_clause;/);
});

// A probe is only a win when the column it reads has an index of its own.
test("only trigram-indexed columns are routed through a probe", async () => {
  const statements = statementsOnly(await probes());

  const start = statements.indexOf("create or replace function public.company_probe_columns_v1");
  const probeMap = statements.slice(start, statements.indexOf("$function$;", start));
  for (const column of ["name", "domain", "industry", "city", "state", "country", "short_description", "total_funding"]) {
    assert.ok(probeMap.includes(`array['${column}']`), `${column} carries a trigram index and must probe`);
  }
  // idx_companies_location covers c.location, not the coalesce over
  // city/state/country that __company_location tests; __keywords and
  // __technologies test array_to_string(...), which nothing covers.
  for (const field of ["__company_location", "__keywords", "__technologies"]) {
    assert.ok(!probeMap.includes(`'${field}'`), `${field} is unindexed as tested and must keep the OR chain`);
  }
});

// The row form tests coalesce(col, '') so a NULL column behaves as ''. The probe
// form lets NULL fail the join. Those agree for every value except one made
// entirely of '%', which matches the empty string.
test("a value that is only wildcards keeps the OR chain", async () => {
  const statements = statementsOnly(await probes());

  assert.match(statements, /where v ~ '\^%\+\$'/);
  assert.match(statements, /if probe_sql is not null then/);
});

// equals is already an indexed array-membership test and the remaining
// operators are per-row by nature; only contains/not_contains grew with rows.
test("only the operators that grew with rows can change shape", async () => {
  const statements = statementsOnly(await probes());

  assert.match(statements, /select p_operator in \('contains', 'not_contains'\)/);
  // c.id is the primary key, so it is never null and the negation is an
  // anti-join rather than NOT IN's three-valued trap.
  assert.match(statements, /conjuncts := conjuncts \|\| format\('\(not \(%s\)\)', probe_sql\);/);
});

// An earlier cut had the prefilter stand down for many-valued filters, which
// cost __company_location its prefilter for nothing: 73ms to 1790ms.
test("company_prefilter_sql is left exactly as it is", async () => {
  const statements = statementsOnly(await probes());

  assert.doesNotMatch(statements, /create or replace function public\.company_prefilter_sql/i,
    "the prefilter is not part of this change; the probe predicate simply omits it");
});

test("every new builder is locked to service_role like its callers", async () => {
  const statements = statementsOnly(await probes());

  for (const signature of [
    "public.company_probe_columns_v1(text, jsonb)",
    "public.company_filter_is_probed_v1(text, jsonb, text, text[])",
    "public.company_substring_probe_sql_v1(text[], text[], text[])",
    "public.company_filter_sql_v3(text, jsonb, boolean)",
    "public.company_probe_filter_sql_v1(text, jsonb)",
    "public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer)",
  ]) {
    const escaped = signature.replace(/[.()[\]]/g, (character) => `\\${character}`);
    assert.match(statements, new RegExp(`revoke execute on function ${escaped} from public, anon, authenticated;`));
    assert.match(statements, new RegExp(`grant execute on function ${escaped} to service_role;`));
  }
});
