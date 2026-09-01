import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = () =>
  readFile(new URL("../supabase/migrations/20260902000010_company_listing_stops_early.sql", import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

// 20260831200000 added a 50,001-row cap so the count would stop early. It never
// took effect: agg was referenced by both `capped` and `page`, so PostgreSQL
// materialised it, and materialising it means building the entire match set
// before either LIMIT can apply. A cap cannot short-circuit a set already built.
test("the count and the page are independent scans, each with its own limit", async () => {
  const statements = statementsOnly(await migration());

  assert.match(statements, /create or replace function public\.filter_companies_v4/i);
  // Both read the base table directly rather than a shared match-set CTE.
  const readsCompanies = statements.match(/from public\.companies c%4\$s/g) ?? [];
  assert.equal(readsCompanies.length, 2, "page and capped must each scan companies directly");
  // The old shape must be gone: no intermediate CTE holding the match set.
  assert.doesNotMatch(statements, /\bbase as \(/, "a shared match-set CTE forces materialisation");
  assert.doesNotMatch(statements, /\bagg as \(/);
  assert.match(statements, /offset %6\$s limit %7\$s/);
  assert.match(statements, /limit %8\$s/);
});

test("only aggregates and scope ids are shared, never the match set", async () => {
  const statements = statementsOnly(await migration());

  // client_counts is an aggregate: computing it once and joining from both scans
  // is the point of a shared CTE.
  assert.match(statements, /client_counts as \(/);
  // The people scope resolves to ids only, materialised so the scope function
  // runs once rather than once per scan.
  assert.match(statements, /scope_ids as materialized \(/);
  assert.match(statements, /c\.id in \(select company_id from scope_ids\)/);
});

test("the unfiltered listing keeps an exact, uncapped total", async () => {
  const statements = statementsOnly(await migration());
  // The headline "how many companies do I have" number must not become 50,000+.
  assert.match(statements, /v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all' else '50001' end;/);
  assert.match(statements, /case when %8\$L = 'all' then count\(\*\) else least\(count\(\*\), 50000\) end/);
});

test("the SECURITY DEFINER listing revokes EXECUTE in the same file", async () => {
  const sql = await migration();
  assert.match(sql, /security definer/i);
  assert.match(
    sql,
    /revoke execute on function public\.filter_companies_v4\(text, jsonb, text, jsonb, integer, integer\) from public, anon, authenticated;/,
  );
});
