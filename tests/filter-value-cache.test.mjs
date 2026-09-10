import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260910170000_cache_the_filter_dropdown_values.sql";

test("only the unfiltered dropdown is cached; typing still goes to v3", async () => {
  const route = await read("../app/api/prospects/filter-values/route.ts");

  // Typing is already 20-250ms on the trigram indexes. Caching per search term
  // would be a cache with one entry per keystroke.
  assert.match(route, /const result = search\s*\n\s*\? await supabase\.rpc\("prospect_filter_values_v3"/);
  assert.match(route, /: await supabase\.rpc\("prospect_filter_values_cached_v1"/);
  // The cached call takes no search argument at all - passing one would silently
  // cache the wrong answer under the unfiltered key.
  const cachedCall = route.slice(route.indexOf('prospect_filter_values_cached_v1'));
  const cachedArgs = cachedCall.slice(0, cachedCall.indexOf('})'));
  assert.doesNotMatch(cachedArgs, /p_search/);
});

test("the cache is keyed on the data version, so it is exact rather than fresh", async () => {
  const migration = await read(migrationPath);

  // data_version_prospect is bumped by every write path, so a row stamped with
  // the current version cannot be stale: the moment anything changes the key
  // stops matching and the next caller recomputes.
  assert.match(migration, /data_versions_v1\(array\['prospect'\]\)/);
  assert.match(migration, /where c\.field = p_field and c\.client_id = v_client and c\.data_version = v_version/);
  // Version is a column, not part of the key, so an upsert replaces the previous
  // generation instead of accumulating one row per version forever.
  assert.match(migration, /primary key \(field, client_id\)/);
  assert.match(migration, /on conflict \(field, client_id\) do update/);
});

test("the cache is not reachable by anon or authenticated", async () => {
  const migration = await read(migrationPath);

  assert.match(migration, /alter table public\.prospect_filter_value_cache enable row level security;/);
  assert.match(migration, /revoke all on public\.prospect_filter_value_cache from public, anon, authenticated;/);
  assert.match(migration, /revoke execute on function public\.prospect_filter_values_cached_v1\(text, text, integer\) from public, anon, authenticated;/);
  assert.match(migration, /grant execute on function public\.prospect_filter_values_cached_v1\(text, text, integer\) to service_role;/);
});

test("the migration proves the cache returns what it caches", async () => {
  const migration = await read(migrationPath);

  // A cache that returns something other than what it caches is worse than none.
  assert.match(migration, /raise exception 'cached values differ from prospect_filter_values_v3'/);
  assert.match(migration, /raise exception 'the cached answer changed between two identical calls'/);
  assert.match(migration, /expected exactly one cache row stamped with the current version/);
  // One stored row serves every limit the route allows, by slicing on read.
  assert.match(migration, /limit was not applied to the cached answer/);
  assert.match(migration, /with ordinality/);
});
