import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260911100000_find_duplicates_without_scanning_everything_twice.sql";

test("duplicates are found by grouping, not by joining everything to everything", async () => {
  const migration = await read(migrationPath);

  // A name occurring once inside its company cannot be a duplicate, so 681,743
  // rows collapse to 45 groups before any pairing happens. The old shape joined
  // everything and discarded 681,808 rows to keep 25.
  assert.ok(migration.includes("group by k, company_id having count(*) > 1"));
  assert.ok(migration.includes("join members r on r.k = l.k and r.company_id = l.company_id and l.id < r.id"));

  // prospect_index is the denormalized table that exists for this. The old
  // version grouped a live aggregating view instead - 6,262ms of GroupAggregate
  // over every row before the join even started.
  assert.ok(migration.includes("from public.prospect_index pi"));

  // Two CTEs read `candidates`, and an inlined CTE is scanned once per reader.
  // Measured: 6,252ms inlined against 2,064ms materialised.
  assert.ok(migration.includes("with candidates as materialized"));
});

test("the summaries view is read with an array, never joined to", async () => {
  const migration = await read(migrationPath);

  // Measured on the same 200 rows: 4.5ms via an array parameter, 29ms via a
  // literal list, 4,228ms via a join or subquery. The view pushes down one and
  // not the other, so the pairs are collected first and read back by id.
  assert.ok(migration.includes("where s.id = any(v_left || v_right)"));
  assert.ok(!/join public\.prospect_summaries/.test(migration));
  // Both sides must hydrate, which is what the old inner join enforced.
  assert.ok(migration.includes("where v_summaries ? v_left[i] and v_summaries ? v_right[i]"));
});

test("the migration proves the answer did not change, on live data", async () => {
  const migration = await read(migrationPath);

  // Not "I measured this once on my copy" - the old answer is captured from
  // this database before the replacement exists, and compared after.
  assert.ok(migration.includes("create temp table duplicate_baseline on commit drop"));
  assert.ok(migration.includes("raise exception 'duplicate candidates changed"));
  assert.ok(migration.includes("duplicate candidate contents changed"));

  // Captured with ONE call to the old function; it takes ~27s and this ran it
  // twice in the first draft.
  const baselineCalls = migration.slice(migration.indexOf("create temp table"), migration.indexOf("create or replace function"));
  assert.equal(baselineCalls.split("find_duplicate_candidates(100)").length - 1, 1);

  // CREATE OR REPLACE drops proconfig, which would silently undo the ceiling
  // 20260911090000 added the day before.
  assert.ok(migration.includes("statement_timeout=120s"));
  assert.ok(migration.includes("did not survive the replace"));
});

test("no index is added to the busiest write path in the system", async () => {
  const migration = await read(migrationPath);

  // An expression index would take the remaining 2s down further, but
  // prospect_index already carries 45 indexes and is written continuously by
  // the import and classification workers. That trade is the wrong way round.
  assert.ok(!/create index/i.test(migration));
  assert.ok(migration.includes("DELIBERATELY NO INDEX"));
});
