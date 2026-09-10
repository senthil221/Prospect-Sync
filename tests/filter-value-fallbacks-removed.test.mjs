import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260910160000_drop_the_filter_value_fallbacks_that_cannot_fire.sql";

test("the filter-values route calls one function, not a chain of three", async () => {
  const route = await read("../app/api/prospects/filter-values/route.ts");

  assert.match(route, /rpc\("prospect_filter_values_v3"/);
  // The v2 and v1 rungs only fired when the rung above was MISSING from the
  // database, which cannot happen: migrations run before the app container
  // starts and a rollback does not undo them.
  assert.doesNotMatch(route, /rpc\("prospect_filter_values_v2"/);
  assert.doesNotMatch(route, /rpc\("prospect_filter_values",/);
  // The classifier fields keep their own function - it is a live handler, not
  // a fallback, so removing it would break those three fields.
  assert.match(route, /rpc\("title_class_filter_values_v1"/);
});

test("dropping the fallbacks proves the primary works first", async () => {
  const migration = await read(migrationPath);

  // Dropping a fallback on the assumption the primary is fine is how an outage
  // starts. The migration checks v3 exists AND returns rows before it drops.
  assert.match(migration, /raise exception 'prospect_filter_values_v3 is missing/);
  assert.match(migration, /refusing to drop its fallbacks/);
  const guard = migration.indexOf("refusing to drop its fallbacks");
  const firstDrop = migration.indexOf("drop function if exists");
  assert.ok(guard >= 0 && firstDrop > guard, "the guard must run before the drops");

  assert.match(migration, /drop function if exists public\.prospect_filter_values\(text, text, text, integer\);/);
  assert.match(migration, /drop function if exists public\.prospect_filter_values_v2\(text, text, text, integer\);/);
});

test("the drop migration checks it removed only what it meant to", async () => {
  const migration = await read(migrationPath);

  assert.match(migration, /prospect_filter_values survived the drop/);
  assert.match(migration, /prospect_filter_values_v2 survived the drop/);
  // The two that must still be there afterwards.
  assert.match(migration, /prospect_filter_values_v3 was dropped by mistake/);
  assert.match(migration, /title_class_filter_values_v1 was dropped by mistake/);
  // And it is never dropped: it aggregates every row under either plan, so the
  // rewrite that helped linked_prospect_total_v1 would buy nothing.
  assert.doesNotMatch(migration, /drop function if exists public\.title_class_filter_values_v1/);
});
