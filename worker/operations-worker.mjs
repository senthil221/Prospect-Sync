// Builds durable result sets and background export files, runs frozen bulk
// operations, and runs retention.
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
// LEAST PRIVILEGE IS REAL HERE, NOT ASPIRATIONAL. The functions it calls are
// SECURITY DEFINER, so this process needs no privilege on prospect_index,
// companies, client_prospects or result_set_items - it cannot read a prospect
// even by accident, and it applies mutations it has no rights to perform.
// 20260902000130 and 20260902000160 assert that, including the negative cases.
//
// IT NEVER DECIDES WHAT TO MUTATE. A job arrives already frozen: its ids were
// written once, by the signed-in request that created it, and apply_batch_v1
// reads them rather than re-running the search. The worker cannot enqueue or
// freeze - 20260902000140 asserts it - so it can only carry out a decision a
// user already made.
//
// BOUNDED TRANSACTIONS. Each batch is its own statement with its own timeout.
// A build of a million ids is many short transactions against a keyset cursor
// rather than one long one, so nothing holds a snapshot open while it runs and
// a restart resumes instead of starting again.
// Prepared company pivots are the bounded exception: their expensive text
// predicate runs once, atomically, within the same 120-second session limit.
// An interrupted preparation rolls back and restarts; ordinary sets still resume.
//
// THE TIMEOUT COMES FROM HERE, NOT FROM THE FUNCTIONS. build_batch_v1 and
// apply_batch_v1 both declare `SET statement_timeout = '120s'`, and neither
// declaration is in force on this connection. Measured on production
// 2026-09-02: a function's declared timeout binds when it is called through
// PostgREST and does nothing on a direct connection - a probe declaring 10s
// slept its full 20s through psql and was cancelled at 10.004s over HTTP. So
// the real bound was prospect_ops_worker's role setting of 5 minutes, not the
// 120s the migrations appear to promise. Setting it explicitly below makes the
// declared intent true for this path as well.
import pg from "pg";
import { createServer } from "node:http";
import { pgInterval } from "./pg-interval.mjs";

const workerId = `${process.env.HOSTNAME ?? "operations-worker"}:${process.pid}`;
const leaseSeconds = Math.max(60, Number(process.env.OPERATIONS_LEASE_SECONDS ?? 300));
const batchSize = Math.max(1000, Math.min(100_000, Number(process.env.OPERATIONS_BATCH_SIZE ?? 25_000)));
// Mutations are far heavier per id than an insert into result_set_items, and
// next_batch_v1 refuses more than 5,000 anyway. 500 keeps each transaction
// short enough that a restart loses very little.
const applyBatchSize = Math.max(50, Math.min(5000, Number(process.env.OPERATIONS_APPLY_BATCH ?? 500)));
// An export part is a jsonb array held whole in memory while it is written, so
// it is sized by bytes rather than by rows: 5,000 wide prospect rows is a few
// megabytes, which is what a 320 MB container and a 2 vCPU box can absorb
// without noticing. Nothing streams here - the rows go straight from
// prospect_index into job_parts inside the database - so this bounds the
// server's working set, not the worker's.
const exportBatchSize = Math.max(500, Math.min(25_000, Number(process.env.OPERATIONS_EXPORT_BATCH ?? 5000)));
const idleDelayMs = Math.max(1000, Number(process.env.OPERATIONS_IDLE_MS ?? 3000));
// Matches what build_batch_v1 and apply_batch_v1 declare, which is the bound
// they were designed for; see the header for why declaring it is not enough on
// a direct connection. Every other statement this worker runs - claim,
// retention - is short, so one session-level value covers them all.
const statementTimeout = pgInterval(process.env.OPERATIONS_STATEMENT_TIMEOUT, "120s", "OPERATIONS_STATEMENT_TIMEOUT");
// Retention is cheap and must actually run: a TTL nothing enforces is not a TTL.
const retentionIntervalMs = Math.max(60_000, Number(process.env.OPERATIONS_RETENTION_MS ?? 900_000));

let stopping = false;
let lastProgressAt = Date.now();
let activeWork = "";
let lastRetentionAt = 0;

process.on("SIGTERM", () => { stopping = true; });
process.on("SIGINT", () => { stopping = true; });

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const markProgress = (work = activeWork) => { lastProgressAt = Date.now(); activeWork = work; };

// Same health contract as the import worker, so compose treats them alike: a
// worker that has stopped making progress is unhealthy even while its process
// is alive.
const healthServer = createServer((request, response) => {
  if (request.url !== "/health") { response.writeHead(404).end(); return; }
  const ageMs = Date.now() - lastProgressAt;
  const healthy = !stopping && ageMs < 180_000;
  response.writeHead(healthy ? 200 : 503, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify({ status: healthy ? "ok" : "stale", activeWork: activeWork || null, ageMs }));
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
  const started = performance.now();
  const { rows } = await client.query(
    "select inserted, total, done from prospect_results.build_batch_v1($1, $2)",
    [setId, batchSize],
  );
  console.log(JSON.stringify({ event: 'result_batch_completed', setId,
    durationMs: Math.round(performance.now() - started), total: Number(rows[0]?.total ?? 0), done: rows[0]?.done ?? false }));
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

// --- Frozen bulk operations ------------------------------------------------

async function claimNextOperation() {
  const { rows } = await client.query(
    "select job_id, action, entity_type, client_scope, total_items, applied_items from prospect_operations.claim_next_v1($1, $2)",
    [workerId, leaseSeconds],
  );
  return rows[0] ?? null;
}

// Mutate, mark applied and accumulate the answer - one statement, one
// transaction. Splitting those would let progress and reality disagree, which
// is why the worker is not granted next_batch_v1 or mark_applied_v1 separately.
async function applyBatch(jobId) {
  const { rows } = await client.query(
    "select applied, total_items, applied_items, done from prospect_operations.apply_batch_v1($1, $2, $3)",
    [jobId, applyBatchSize, leaseSeconds],
  );
  return rows[0] ?? { applied: 0, total_items: 0, applied_items: 0, done: true };
}

async function failOperation(jobId, error) {
  await client.query("select prospect_operations.fail_v1($1, $2)", [jobId, String(error?.message ?? error)])
    .catch((failure) => console.error("Could not record the operation failure", failure));
}

async function runOperation(job) {
  const jobId = job.job_id;
  let batches = 0;
  for (;;) {
    if (stopping) {
      // Safe to walk away mid-job: applied_at records exactly which ids are
      // already done, so whoever picks it up next continues rather than
      // repeating - and never re-applies a batch that landed.
      console.log(`Stopping mid-operation ${jobId}; ${job.action} will resume from where it stopped.`);
      return;
    }
    const { applied, total_items: total, applied_items: done_count, done } = await applyBatch(jobId);
    batches += 1;
    markProgress(`operation:${jobId}`);
    if (Number(applied) > 0) {
      console.log(`Operation ${jobId} (${job.action}): batch ${batches} applied ${applied}, ${done_count}/${total} done.`);
    }
    if (done) {
      console.log(`Operation ${jobId} (${job.action}) finished: ${done_count}/${total} after ${batches} batch(es).`);
      return;
    }
  }
}

// --- Background export files -----------------------------------------------

// Only jobs whose result set is already built are returned, so a file never
// waits on a list this same worker has not finished making. That is why the
// export queue is drained after the sets rather than before them.
async function claimNextExport() {
  const { rows } = await client.query(
    "select job_id, entity_type, result_set_id, row_count, next_ordinal, set_rows from prospect_exports.claim_next_v1($1, $2)",
    [workerId, leaseSeconds],
  );
  return rows[0] ?? null;
}

async function buildExportBatch(jobId) {
  const { rows } = await client.query(
    "select appended, total_rows, total_parts, done from prospect_exports.build_batch_v1($1, $2, $3)",
    [jobId, exportBatchSize, leaseSeconds],
  );
  return rows[0] ?? { appended: 0, total_rows: 0, total_parts: 0, done: true };
}

async function failExport(jobId, error) {
  await client.query("select prospect_exports.fail_v1($1, $2)", [jobId, String(error?.message ?? error)])
    .catch((failure) => console.error("Could not record the export failure", failure));
}

async function runExport(job) {
  const jobId = job.job_id;
  let batches = 0;
  for (;;) {
    if (stopping) {
      // next_ordinal says exactly how far the file got, and a part is written
      // once under its own index, so resuming appends rather than repeating.
      console.log(`Stopping mid-export ${jobId}; it will resume from row ${job.next_ordinal}.`);
      return;
    }
    const { appended, total_rows: rows, total_parts: parts, done } = await buildExportBatch(jobId);
    batches += 1;
    markProgress(`export:${jobId}`);
    if (Number(appended) > 0) {
      console.log(`Export ${jobId}: part ${parts} added ${appended}, ${rows}/${job.set_rows} rows written.`);
    }
    if (done) {
      console.log(`Export ${jobId} is ready: ${rows} rows in ${parts} part(s) after ${batches} batch(es).`);
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
    const jobs = await client.query("select prospect_operations.expire_jobs_v1() as removed");
    // Export jobs carry the files themselves, so this is the one retention pass
    // that reclaims real space rather than rows.
    const exports = await client.query("select prospect_exports.expire_jobs_v1() as removed");
    const removed = Number(results.rows[0]?.removed ?? 0) + Number(filters.rows[0]?.removed ?? 0)
      + Number(jobs.rows[0]?.removed ?? 0) + Number(exports.rows[0]?.removed ?? 0);
    if (removed > 0) console.log(`Retention removed ${removed} expired set(s) or job(s).`);
  } catch (error) {
    // Retention failing must never stop the worker doing its actual job.
    console.error("Retention pass failed", error);
  }
}

async function main() {
  await client.connect();
  await client.query(`set statement_timeout = '${statementTimeout}'`);
  const { rows } = await client.query("select current_user, session_user, current_setting('statement_timeout') as timeout");
  console.log(`Prospect operations worker ${workerId} started as ${rows[0].current_user}; result batches of ${batchSize}, operation batches of ${applyBatchSize}, export batches of ${exportBatchSize}, statement timeout ${rows[0].timeout}.`);

  while (!stopping) {
    markProgress("");
    await runRetention();

    // Operations first. Someone is watching a progress bar for one of these,
    // whereas a result set is usually feeding a count. Each queue is drained to
    // empty before the next is checked, so a pass that finds work loops
    // straight back and looks for more of the same kind.
    //
    // Exports come second and result sets third, which looks backwards - an
    // export is built FROM a set - and is deliberate. claim_next_v1 only offers
    // an export whose set is already 'ready', so an export waiting on its list
    // is simply not claimable and this pass falls through to build that list.
    // Putting exports after the sets instead would let a steady stream of sets
    // starve the files indefinitely.
    let operation = null;
    try {
      operation = await claimNextOperation();
      if (operation) {
        console.log(`Running operation ${operation.job_id} (${operation.action}) from item ${operation.applied_items}/${operation.total_items}.`);
        await runOperation(operation);
        continue;
      }
    } catch (error) {
      console.error(`Operation ${operation?.job_id ?? "claim"} failed`, error);
      // A job that cannot run must say so rather than being reclaimed forever.
      // Whatever it already applied stays applied and is recorded as such.
      if (operation) await failOperation(operation.job_id, error);
      else await wait(5000);
      continue;
    }

    let exportJob = null;
    try {
      exportJob = await claimNextExport();
      if (exportJob) {
        console.log(`Building export ${exportJob.job_id} (${exportJob.entity_type}) from row ${exportJob.next_ordinal} of ${exportJob.set_rows}.`);
        await runExport(exportJob);
        continue;
      }
    } catch (error) {
      console.error(`Export ${exportJob?.job_id ?? "claim"} failed`, error);
      // Same contract as the other two queues: a file that cannot be built says
      // so, rather than being reclaimed forever while the user waits.
      if (exportJob) await failExport(exportJob.job_id, error);
      else await wait(5000);
      continue;
    }

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
