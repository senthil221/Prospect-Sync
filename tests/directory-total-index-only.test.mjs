import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260910150000_the_directory_total_stops_scanning_the_whole_table.sql";

test("the unfiltered directory total is planned without the search parameter", async () => {
  const migration = await read(migrationPath);

  // The whole point: a branch, not an OR. `$1 = '' OR name ilike $1` cannot be
  // folded by a generic plan, so it was planned as a seq scan over 1,332MB on
  // every ordinary page load - measured at 155,322 physical reads.
  assert.match(migration, /language plpgsql/);
  assert.match(migration, /if v_search = '' then/);

  // The empty branch must not mention the parameter at all, or it is back to
  // being planned as though it might filter.
  const emptyBranch = migration.slice(
    migration.indexOf("if v_search = '' then"),
    migration.indexOf("end if;"));
  assert.doesNotMatch(emptyBranch, /ilike/);
  assert.match(emptyBranch, /where pi\.company_id is not null/);
});

test("replacing the function does not drop the timeout an earlier migration added", async () => {
  const migration = await read(migrationPath);

  // 20260902000040 added this with ALTER FUNCTION. CREATE OR REPLACE drops
  // proconfig, so it has to be restated here or that migration is silently
  // undone and only verify-migrations.sql would ever notice.
  assert.match(migration, /set statement_timeout to '20s'/);
  assert.match(migration, /set search_path to 'public'/);
  assert.match(migration, /security definer/);
  // And the migration checks it rather than trusting it.
  assert.match(migration, /statement_timeout=20s/);

  // Privileges are restated too: service_role only, never anon/authenticated.
  assert.match(migration, /revoke execute on function public\.linked_prospect_total_v1\(text\) from public, anon, authenticated;/);
  assert.match(migration, /grant execute on function public\.linked_prospect_total_v1\(text\) to service_role;/);
});

test("the index-only scan is kept fast by an autovacuum that actually runs", async () => {
  const migration = await read(migrationPath);

  // An index-only scan is only index-only while the visibility map is current.
  // The map had drifted to 92.3%, costing 63,085 heap fetches per call.
  assert.match(migration, /alter table public\.prospect_index set \(/);
  assert.match(migration, /autovacuum_vacuum_scale_factor = 0\.02/);
  // Inserts leave no dead tuples to trigger a vacuum but do leave pages
  // not-all-visible, and this table is insert-heavy - so this one carries the
  // map, not the plain vacuum threshold.
  assert.match(migration, /autovacuum_vacuum_insert_scale_factor = 0\.02/);
});

test("the migration proves the count did not change before it commits", async () => {
  const migration = await read(migrationPath);

  // A rewrite that returns a different number is worse than a slow one, so the
  // migration compares both branches against the predicate it replaced and
  // rolls itself back on any difference.
  assert.match(migration, /raise exception 'unfiltered total changed/);
  assert.match(migration, /raise exception 'search total changed/);
  // btrim/coalesce semantics have to survive: blank and null both mean "all".
  assert.match(migration, /a whitespace search no longer means unfiltered/);
  assert.match(migration, /a null search no longer means unfiltered/);
});
