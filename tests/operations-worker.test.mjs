import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Release 2, item 3: a dedicated least-privilege operations worker (section
// 9.1), reusing the import worker's queue primitives and fixing the pool gap
// that one still has.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("the worker never touches the interactive pool", async () => {
  const worker = await read("../worker/operations-worker.mjs");

  // The import worker still reaches its queue through PostgREST with the
  // service-role key, so its claim and heartbeat draw on the pool that serves
  // the browser. That gap was recorded when 20260902000090 split its login
  // role; this worker closes it by having no HTTP client to the API at all.
  assert.doesNotMatch(worker, /SUPABASE_REST_URL|SERVICE_ROLE_KEY|\/rpc\//);
  assert.match(worker, /import pg from "pg"/);
  assert.match(worker, /application_name: "prospect-operations-worker"/);
});

test("it reuses the import worker's queue primitives rather than inventing new ones", async () => {
  const [worker, migration, unit] = await Promise.all([
    read("../worker/operations-worker.mjs"),
    read("../supabase/migrations/20260902000120_durable_result_sets.sql"),
    read("../supabase/migrations/20260905220328_fair_atomic_background_units.sql"),
  ]);

  // Claim, lease, expired-lease recovery - the shape section 9.1 asks for.
  assert.match(migration, /for update skip locked/);
  assert.match(migration, /lease_expires_at/);
  assert.match(worker, /run_queue_unit_v1/);
  assert.match(unit, /claim_next_v1/);
  assert.match(unit, /build_batch_v1/);
  assert.match(unit, /fail_set_v1/);

  // Bounded transactions: a build is many short batches against a keyset
  // cursor, not one long transaction holding a snapshot open.
  assert.match(worker, /OPERATIONS_BATCH_SIZE/);
  assert.match(migration, /cursor_created_at/);
  assert.match(migration, /cursor_id/);

  // A permanent failure is recorded rather than left to be reclaimed forever.
  assert.match(unit, /EXCEPTION WHEN OTHERS OR query_canceled/);
  // Stopping mid-build hands the work back through the lease instead of
  // marking a half-built set finished.
  assert.match(unit, /ELSE 'pending'/);
  assert.doesNotMatch(worker, /await failSet/);

  // Retention actually runs; a TTL nothing enforces is not a TTL.
  assert.match(worker, /expire_sets_v1/);
  assert.match(worker, /runRetention/);
  // And a failing retention pass must not stop the worker doing its real job.
  assert.match(worker, /Retention pass failed/);
});

test("it holds five function grants and no table privileges at all", async () => {
  const migration = await read("../supabase/migrations/20260902000130_operations_worker_privileges.sql");

  for (const granted of [
    "prospect_results.claim_next_v1\\(text, integer\\)",
    "prospect_results.build_batch_v1\\(uuid, integer\\)",
    "prospect_results.fail_set_v1\\(uuid, text\\)",
    "prospect_results.expire_sets_v1\\(\\)",
    "prospect_filters.expire_sets_v1\\(\\)",
  ]) {
    assert.match(migration, new RegExp(`grant execute on function ${granted} to prospect_operator;`));
  }

  // The application's entry points stay the application's: a background worker
  // has no business answering for a signed-in user.
  assert.doesNotMatch(migration, /grant execute on function prospect_results\.page_v1[^;]*to prospect_operator/);
  assert.doesNotMatch(migration, /grant execute on function prospect_results\.request_set_v1[^;]*to prospect_operator/);
  assert.doesNotMatch(migration, /grant execute on function prospect_results\.status_v1[^;]*to prospect_operator/);

  // No table grants anywhere - SECURITY DEFINER is what makes that possible.
  assert.doesNotMatch(migration, /grant (select|insert|update|delete)[^;]*to prospect_operator/);

  // The negative cases are asserted in the migration itself, in the same
  // transaction that grants, and were verified against production.
  assert.match(migration, /can read prospect_index directly/);
  assert.match(migration, /can read stored result ids directly/);
  assert.match(migration, /can page a result set/);
  assert.match(migration, /defeats the separation/);
});

test("the role exists before the worker that needs it starts", async () => {
  const [bootstrap, compose, update, migration] = await Promise.all([
    read("../deploy/postgres/init/00-prospect-bootstrap.sh"),
    read("../deploy/docker-compose.yml"),
    read("../deploy/scripts/update.sh"),
    read("../supabase/migrations/20260902000130_operations_worker_privileges.sql"),
  ]);

  // Created where the password and superuser are, like prospect_import_worker.
  assert.match(bootstrap, /create role prospect_operator nologin noinherit;/);
  assert.match(bootstrap, /create role prospect_ops_worker login;/);
  assert.match(bootstrap, /grant prospect_operator to prospect_ops_worker;/);
  assert.match(bootstrap, /revoke service_role from prospect_ops_worker;/);
  assert.match(bootstrap, /alter role prospect_ops_worker connection limit 2;/);
  assert.match(bootstrap, /alter role prospect_ops_worker set statement_timeout/);

  // Its own login, not authenticator and not the import worker's.
  assert.match(compose, /PGUSER: prospect_ops_worker/);
  assert.match(compose, /container_name: prospect-operations-worker/);

  // Ordering: bootstrap, then migrations, then the worker - or it starts
  // against a role and functions that do not exist yet.
  const bootstrapAt = update.indexOf("00-prospect-bootstrap.sh");
  const migrateAt = update.indexOf("./scripts/migrate.sh");
  const workerAt = update.indexOf("--pull always operations-worker");
  assert.ok(bootstrapAt > 0 && migrateAt > bootstrapAt && workerAt > migrateAt,
    "the deploy must bootstrap, migrate, then start the operations worker");
  // A worker that never becomes healthy must fail the release, not be ignored.
  assert.match(update, /wait_for_container prospect-operations-worker/);
  assert.match(update, /Operations worker did not become healthy/);

  // And the migration refuses if the bootstrap was skipped.
  assert.match(migration, /prospect_ops_worker role is missing/);
  assert.match(migration, /00-prospect-bootstrap\.sh/);
});
