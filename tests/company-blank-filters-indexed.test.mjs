import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(new URL(
  "../supabase/migrations/20260926190000_company_blank_filters_read_an_index.sql", import.meta.url), "utf8");

test("keywords and technologies compile through IMMUTABLE wrappers", () => {
  // array_to_string is STABLE, so nothing built on it can be indexed.
  assert.match(migration, /create or replace function public\.tag_array_text_v1\(p_tags text\[\]\)[\s\S]*?immutable/);
  assert.ok(migration.includes("when ''__keywords'' then ''public.tag_array_text_v1(c.keywords)''"));
  assert.ok(migration.includes("when ''__technologies'' then ''public.company_technologies_text_v1(c.technologies)''"));
});

test("the blank-value indexes carry exactly the predicates the compiler emits", () => {
  // The planner can only use a partial index whose predicate it can prove from
  // the query, so these must stay textually identical to the compiled form.
  assert.match(migration, /create index if not exists idx_companies_keywords_blank\s+on public\.companies \(id\)\s+where btrim\(coalesce\(public\.tag_array_text_v1\(keywords\), ''\)\) = '';/);
  assert.match(migration, /create index if not exists idx_companies_description_blank\s+on public\.companies \(id\)\s+where btrim\(coalesce\(short_description, ''\)\) = '';/);
  assert.ok(migration.includes("if v_sql <> '(btrim(coalesce(public.tag_array_text_v1(c.keywords), '''')) = '''')' then"));
});

test("the migration proves the same companies match as before", () => {
  assert.match(migration, /keywords empty now matches % companies, previously %/);
  assert.match(migration, /technologies contains now matches % companies, previously %/);
  assert.match(migration, /keywords contains now matches % companies, previously %/);
  assert.match(migration, /set local lock_timeout = '5s';/);
});
