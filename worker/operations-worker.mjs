// Builds durable result sets, and runs retention.
//
// Section 9.1 asks for a dedicated operations worker: its own process, pool and
// login role, reusing the import worker's queue primitives - FOR UPDATE SKIP
// LOCKED claim, lease and heartbeat, expired-lease recovery, progress, bounded
// transactions, retention cleanup.
//
// DIRECT POSTGRES ONLY. The import worker still reaches its queue through
// PostgREST with the service-role key, so its claim, heartbeat and retry calls
// draw on the same pool that serves the browser - noted as an open gap when
// 20260902000090 separated its login role. This worker has no PostgREST client
// at all. Everything it does goes down its own connection as
// prospect_ops_worker, which carries CONNECTION LIMIT 2, so a runaway build
// cannot take a slot the interactive pool needed.
//
// LEAST PRIVILEGE IS REAL HERE, NOT ASPIRATIONAL. The five functions it calls
// are SECURITY DEFINER, so this process needs no privilege on prospect_index,
// companies or result_set_items - it cannot read a prospect even by accident.
// 20260902000130 asserts that, including the negative cases.
//
// BOUNDED TRANSACTIONS. Each batch is its own statement with its own timeout.
// A build of a million ids is many short transactions against a keyset cursor
// rather than one long one, so nothing holds a snapshot open while it runs and
// a restart resumes instead of starting again.
import pg from "pg";
import { createServer } from "node:http";

const workerId = `${process.env.HOSTNAME ?? "operations-worker"}:${process.pid}`;
const leaseSeconds = Math.max(60, Number(process.env.OPERATIONS_LEASE_SECONDS ?? 300));
const batchSize = Math.max(1000, Math.min(100_000, Number(process.env.OPERATIONS_BATCH_SIZE ?? 25_000)));
const idleDelayMs = Math.max(1000, Number(process.env.OPERATIONS_IDLE_MS ?? 3000));
// Retention is cheap and must actually run: a TTL nothing enforces is not a TTL.
const retentionIntervalMs = Math.max(60_000, Number(process.env.OPERATIONS_RETENTION_MS ?? 900_000));

let stopping = false;
let lastProgressAt = Date.now();
let activeSetId = "";
let lastRetentionAt = 0;

process.on("SIGTERM", () => { stopping = true; });
process.on("SIGINT", () => { stopping = true; });

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const markProgress = (setId = activeSetId) => { lastProgressAt = Date.now(); activeSetId = setId; };

// Same health contract as the import worker, so compose treats them alike: a
// worker that has stopped making progress is unhealthy even while its process
// is alive.
const healthServer = createServer((request, response) => {
  if (request.url !== "/health") { response.writeHead(404).end(); return; }
  const ageMs = Date.now() - lastProgressAt;
  const healthy = !stopping && ageMs < 180_000;
  response.writeHead(healthy ? 200 : 503, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify({ status: healthy ? "ok" : "stale", activeSetId: activeSetId || null, ageMs }));
});

const client = new pg.Client({ application_name: "prospect-operations-worker", connectionTimeoutMillis: 10_000 });

async function claimNext() {
  const { rows } = await client.query(
    "select set_id, entity_type, client_scope, search, filters, row_count from prospect_results.claim_next_v1($1, $2)",
    [workerId, leaseSeconds],
  );
  return rows[0] ?? null;
}

// One batch, one statement. Returns whether the set is finished.
async function buildBatch(setId) {
  const { rows } = await client.query(
    "select inserted, total, done from prospect_results.build_batch_v1($1, $2)",
    [setId, batchSize],
  );
  return rows[0] ?? { inserted: 0, total: 0, done: true };
}

async function failSet(setId, error) {
  await client.query("select prospect_results.fail_set_v1($1, $2)", [setId, String(error?.message ?? error)])
    .catch((failure) => console.error("Could not record the failure", failure));
}

// A build keeps its own lease alive by making progress: claim_next_v1 extends
// the lease on every batch, so a set is only reclaimed when a worker genuinely
// stopped. This is the expired-lease recovery section 9.1 asks for, and it
// needs no separate heartbeat call.
async function buildSet(job) {
  const setId = job.set_id;
  let batches = 0;
  for (;;) {
    if (stopping) {
      console.log(`Stopping mid-build of ${setId}; its lease will expire and another worker will resume.`);
      return;
    }
    const { inserted, total, done } = await buildBatch(setId);
    batches += 1;
    markProgress(setId);
    if (Number(inserted) > 0) {
      console.log(`Result set ${setId}: batch ${batches} added ${inserted}, ${total} so far.`);
    }
    if (done) {
      console.log(`Result set ${setId} is ready with ${total} rows after ${batches} batch(es).`);
      return;
    }
  }
}

async function runRetention() {
  if (Date.now() - lastRetentionAt < retentionIntervalMs) return;
  lastRetentionAt = Date.now();
  try {
    const results = await client.query("select prospect_results.expire_sets_v1() as removed");
    const filters = await client.query("select prospect_filters.expire_sets_v1() as removed");
    const removed = Number(results.rows[0]?.removed ?? 0) + Number(filters.rows[0]?.removed ?? 0);
    if (removed > 0) console.log(`Retention removed ${removed} expired set(s).`);
  } catch (error) {
    // Retention failing must never stop the worker doing its actual job.
    console.error("Retention pass failed", error);
  }
}

async function main() {
  await client.connect();
  const { rows } = await client.query("select current_user, session_user");
  console.log(`Prospect operations worker ${workerId} started as ${rows[0].current_user}; batch size ${batchSize}.`);

  while (!stopping) {
    markProgress("");
    await runRetention();
    let job = null;
    try {
      job = await claimNext();
      if (!job) { await wait(idleDelayMs); continue; }
      console.log(`Building result set ${job.set_id} (${job.entity_type}) from row ${job.row_count}.`);
      await buildSet(job);
    } catch (error) {
      console.error(`Result set ${job?.set_id ?? "claim"} failed`, error);
      // A set that cannot be built must say so rather than being reclaimed
      // forever: a permanent error is recorded, and the request sees 'failed'.
      if (job) await failSet(job.set_id, error);
      else await wait(5000);
    }
  }

  console.log("Prospect operations worker stopped.");
  await client.end().catch(() => undefined);
}

await new Promise((resolve, reject) => {
  healthServer.once("error", reject);
  healthServer.listen(9091, "0.0.0.0", resolve);
});
await main();
await new Promise((resolve) => healthServer.close(resolve));
