// Direct Postgres only: one least-privilege connection, never the interactive
// HTTP pool. Claim + one batch + checkpoint/release execute atomically inside
// run_queue_unit_v1. No client-side job handle outlives its owning statement.
// Ordinary sets resume from their cursor. Company description preparation is
// still atomic, not preemptible; the 120s session deadline bounds it.
import pg from "pg";
import { createServer } from "node:http";
import { pgInterval } from "./pg-interval.mjs";
import { createFairScheduler, integerSetting } from "./fair-scheduler.mjs";
import { runMaintenanceUnit } from './maintenance-unit.mjs';
import { createWorkerPhaseMetrics } from './phase-metrics.mjs';

const workerId = `${process.env.HOSTNAME ?? "operations-worker"}:${process.pid}`;
const setting = (name, fallback, min, max) => integerSetting(process.env[name], fallback, min, max, name);
const batchSize = setting('OPERATIONS_BATCH_SIZE', 25000, 1000, 100000);
const applyBatchSize = setting('OPERATIONS_APPLY_BATCH', 500, 50, 5000);
const exportBatchSize = setting('OPERATIONS_EXPORT_BATCH', 5000, 500, 25000);
const idleDelayMs = setting('OPERATIONS_IDLE_MS', 3000, 1000, 30000);
const retentionIntervalMs = setting('OPERATIONS_RETENTION_MS', 5000, 1000, 86400000);
// Dashboard summaries are O(table) and must not be computed on a request. The
// refresh itself is a no-op when no data has changed, so this interval is the
// worst-case lag after a write, not a fixed cost.
const snapshotIntervalMs = setting('OPERATIONS_SNAPSHOT_MS', 300000, 10000, 3600000);
let lastSnapshotAt = 0;
let lastJanitorAt = 0;
// The backlog is usually empty, so this is a cheap poll; it only has real work
// to do just after a company import or a bulk client change.
const reindexDrainIntervalMs = setting('OPERATIONS_REINDEX_MS', 15000, 1000, 600000);
const reindexCatchUpMs = setting('OPERATIONS_REINDEX_CATCHUP_MS', 2000, 500, 600000);
let lastReindexDrainAt = 0;
const statementTimeout = pgInterval(process.env.OPERATIONS_STATEMENT_TIMEOUT, "120s", "OPERATIONS_STATEMENT_TIMEOUT");
const timeoutParts = /^(\d+)(ms|s|min|h)$/.exec(statementTimeout);
const timeoutMs = Number(timeoutParts[1]) * ({ ms: 1, s: 1000, min: 60000, h: 3600000 }[timeoutParts[2]]);
if (timeoutMs < 1000 || timeoutMs > 120000) throw new Error('OPERATIONS_STATEMENT_TIMEOUT must be between 1s and 120s.');

let stopping = false, connected = false;
let lastProgressAt = Date.now(), lastRetentionAt = 0;
let activeWork = '';
const metrics = createWorkerPhaseMetrics({
  worker: 'operations-worker',
  phases: ['queue', 'cleanup', 'snapshot', 'import-janitor', 'reindex'],
});
const maintenanceClasses = ['search', 'filter', 'operation', 'export', 'metrics'];
let nextMaintenance = 0;
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });
const wait = (ms) => new Promise(resolve => setTimeout(resolve, ms));
const markProgress = () => { lastProgressAt = Date.now(); };
const healthServer = createServer((request, response) => {
  if (request.url !== '/health') { response.writeHead(404).end(); return; }
  const ageMs = Date.now() - lastProgressAt;
  const healthy = connected && !stopping && ageMs < 180000;
  response.writeHead(healthy ? 200 : 503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify({ status: healthy ? 'ok' : 'stale', activeWork: activeWork || null, ageMs,
    scheduler: 'atomic-round-v1' }));
});
const client = new pg.Client({ application_name: "prospect-operations-worker", connectionTimeoutMillis: 10000 });
// Connection loss is not evidence of job failure. PostgreSQL rolls back that
// statement; exit and let restart resume the last committed checkpoint.
client.on('error', () => { connected = false; stopping = true; });

async function runUnit(kind) {
  activeWork = kind;
  const started = performance.now();
  const batch = kind === 'operation' ? applyBatchSize : kind === 'export' ? exportBatchSize : batchSize;
  try {
    const { rows } = kind === 'blocklist'
      ? await client.query('select * from public.run_blocklist_share_submission_unit_v1($1,$2)', [workerId, Math.min(batch, 5000)])
      : await client.query('select * from prospect_operations.run_queue_unit_v1($1,$2,$3)', [kind, workerId, batch]);
    markProgress();
    const result = rows[0];
    metrics.record('queue', result?.job_id ? 'ok' : 'empty', performance.now() - started,
      result?.job_id ? Number(result.done ?? 0) : 0);
    if (result?.job_id) console.log(JSON.stringify({ event: 'background_unit', kind, jobId: result.job_id,
      outcome: result.outcome, total: Number(result.total), done: result.done, durationMs: Math.round(performance.now() - started) }));
    return Boolean(result?.job_id);
  } catch (error) {
    metrics.record('queue', 'error', performance.now() - started);
    throw error;
  } finally { activeWork = ''; }
}

async function runRetention() {
  if (Date.now() - lastRetentionAt < retentionIntervalMs) return;
  lastRetentionAt = Date.now();
  const kind = maintenanceClasses[nextMaintenance];
  nextMaintenance = (nextMaintenance + 1) % maintenanceClasses.length;
  activeWork = `cleanup:${kind}`;
  const started = performance.now();
  try {
    const result = await runMaintenanceUnit(client, kind);
    metrics.record('cleanup', 'ok', performance.now() - started,
      Number(result.items_removed ?? 0) + Number(result.parents_removed ?? 0));
    if (result.items_removed || result.parents_removed) console.log(JSON.stringify({event: 'background_cleanup', kind, ...result}));
    markProgress();
  } catch (error) {
    metrics.record('cleanup', 'error', performance.now() - started);
    console.error('Retention pass failed', { code: error.code ?? 'unknown' });
  }
  finally { activeWork = ''; }
}

async function runImportJanitor() {
  if (Date.now() - lastJanitorAt < snapshotIntervalMs) return;
  lastJanitorAt = Date.now();
  // Separate transaction from the snapshots on purpose: a failure to close an
  // abandoned import must not roll back a refreshed dashboard, and neither
  // should wait on the other.
  const started = performance.now();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout = '30s'");
    await client.query("SET LOCAL lock_timeout = '5s'");
    const result = await client.query('select public.expire_abandoned_company_imports_v1(24, 50) as expired');
    await client.query('COMMIT');
    const expired = Number(result.rows[0]?.expired ?? 0);
    metrics.record('import-janitor', 'ok', performance.now() - started, expired);
    // Only worth a line when it did something; the normal case is zero.
    if (expired) console.log(JSON.stringify({ event: 'company_imports_expired', expired }));
  } catch (error) {
    metrics.record('import-janitor', 'error', performance.now() - started);
    try { await client.query('ROLLBACK'); } catch { /* The main loop handles a dead connection. */ }
    console.error('Abandoned import sweep failed', { code: error.code ?? 'unknown' });
  }
}

// Drain the re-index backlog.
//
// Before this existed the ONLY caller of drain_reindex_backlog anywhere was the
// Re-index button in Data Quality, so anything queued sat there until a human
// noticed. Company import completion now queues instead of rebuilding inline
// (20260914090000), which only works if something empties the queue. This is
// that something.
//
// One bounded unit per pass, deliberately: looping to empty here would starve
// run_queue_unit_v1 behind a 131,769-row backlog.
async function runReindexDrain() {
  if (Date.now() - lastReindexDrainAt < reindexDrainIntervalMs) return;
  lastReindexDrainAt = Date.now();
  const started = performance.now();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout = '60s'");
    await client.query("SET LOCAL lock_timeout = '5s'");
    const result = await client.query('select * from public.drain_reindex_backlog(2000)');
    await client.query('COMMIT');
    const processed = Number(result.rows[0]?.processed ?? 0);
    const remaining = Number(result.rows[0]?.remaining ?? 0);
    metrics.record('reindex', 'ok', performance.now() - started, processed);
    // Only worth a line when it did something; the normal case is an empty queue.
    if (processed) console.log(JSON.stringify({ event: 'reindex_drain', processed, remaining }));
    if (processed) markProgress();
    // Bulk actions now defer everything past their first 200 prospects to this
    // backlog (20260926170000), so a backlog is the normal aftermath of a large
    // action rather than a rare repair. While one exists, come back after a
    // short breath instead of the full interval: still one unit at a time on
    // this single connection, and the fair scheduler runs between passes.
    if (processed && remaining > 0) {
      lastReindexDrainAt = Date.now() - reindexDrainIntervalMs + reindexCatchUpMs;
    }
  } catch (error) {
    metrics.record('reindex', 'error', performance.now() - started);
    // A lagging index is not worth failing the worker over - the rows stay
    // queued, drain_reindex_backlog records why on each one, and the next pass
    // retries them.
    try { await client.query('ROLLBACK'); } catch { /* The main loop handles a dead connection. */ }
    console.error('Reindex backlog drain failed', { code: error.code ?? 'unknown' });
  }
}

async function runSnapshots() {
  if (Date.now() - lastSnapshotAt < snapshotIntervalMs) return;
  lastSnapshotAt = Date.now();
  activeWork = 'snapshot';
  const started = performance.now();
  try {
    // Keep this on the worker's single database connection and await it. A
    // second long-running connection would compete with interactive queries on
    // the 2-vCPU database precisely when they are already slow. The phase
    // metric tells us whether this atomic function should be decomposed later;
    // until then, serial background work is the safer failure boundary.
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout = '300s'");
    await client.query("SET LOCAL lock_timeout = '5s'");
    const result = await client.query('select prospect_operations.refresh_dashboard_snapshots_v1() as refreshed');
    await client.query('COMMIT');
    const refreshed = Number(result.rows[0]?.refreshed ?? 0);
    metrics.record('snapshot', 'ok', performance.now() - started, refreshed);
    if (refreshed) console.log(JSON.stringify({ event: 'dashboard_snapshot', refreshed, durationMs: Math.round(performance.now() - started) }));
    markProgress();
  } catch (error) {
    metrics.record('snapshot', 'error', performance.now() - started);
    // A stale summary is not worth failing the worker over; the tab keeps
    // serving the previous one and says when it was computed.
    try { await client.query('ROLLBACK'); } catch { /* The main loop handles a dead connection. */ }
    console.error('Dashboard snapshot refresh failed', { code: error.code ?? 'unknown' });
  } finally { activeWork = ''; }
}

async function main() {
  await client.connect();
  await client.query(`set statement_timeout = '${statementTimeout}'`);
  await client.query("set lock_timeout = '5s'");
  // Fail readiness before serving health if the compatible schema is absent.
  await client.query("select 'prospect_operations.run_queue_unit_v1(text,text,integer)'::regprocedure");
  await client.query("select 'prospect_operations.reclaim_unit_v1(text,integer)'::regprocedure");
  // Soft on purpose. Draining the re-index backlog is secondary work, and a
  // worker deployed a few minutes ahead of 20260914090000 - or without the
  // prospect_operator grant - should still run queues rather than refuse to
  // start. The line in the log is how that gets noticed.
  try {
    await client.query("select 'public.drain_reindex_backlog(integer)'::regprocedure");
  } catch (error) {
    console.error('Reindex backlog drain unavailable; the search index will lag until this is resolved', { code: error.code ?? 'unknown' });
  }
  connected = true;
  console.log(JSON.stringify({ event: 'worker_started', scheduler: 'atomic-round-v1', statementTimeout, batchSize, applyBatchSize, exportBatchSize }));
  const round = createFairScheduler({ classes: ['search', 'operation', 'export', 'blocklist'], runUnit,
    stopping: () => stopping,
    onError: async (kind, error) => {
      console.error(JSON.stringify({ event: 'background_unit_transport_error', kind, code: error.code ?? 'unknown' }));
      // Never publish a separate failure using a potentially stale job ID.
      // Execution failures are recorded inside the owning SQL transaction.
    },
  });
  while (!stopping) {
    const progressed = await round();
    if (!stopping) await runRetention();
    if (!stopping) await runSnapshots();
    if (!stopping) await runImportJanitor();
    if (!stopping) await runReindexDrain();
    if (!progressed && !stopping) await wait(idleDelayMs);
  }
}

await new Promise((resolve, reject) => { healthServer.once('error', reject); healthServer.listen(9091, '0.0.0.0', resolve); });
try { await main(); }
finally {
  connected = false;
  metrics.flush();
  await client.end().catch(() => {});
  await new Promise(resolve => healthServer.close(resolve));
}
