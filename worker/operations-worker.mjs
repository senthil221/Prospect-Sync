// Direct Postgres only: one least-privilege connection, never the interactive
// HTTP pool. Claim + one batch + checkpoint/release execute atomically inside
// run_queue_unit_v1. No client-side job handle outlives its owning statement.
// Ordinary sets resume from their cursor. Company description preparation is
// still atomic, not preemptible; the 120s session deadline bounds it.
import pg from "pg";
import { createServer } from "node:http";
import { pgInterval } from "./pg-interval.mjs";
import { createFairScheduler, integerSetting } from "./fair-scheduler.mjs";

const workerId = `${process.env.HOSTNAME ?? "operations-worker"}:${process.pid}`;
const setting = (name, fallback, min, max) => integerSetting(process.env[name], fallback, min, max, name);
const batchSize = setting('OPERATIONS_BATCH_SIZE', 25000, 1000, 100000);
const applyBatchSize = setting('OPERATIONS_APPLY_BATCH', 500, 50, 5000);
const exportBatchSize = setting('OPERATIONS_EXPORT_BATCH', 5000, 500, 25000);
const idleDelayMs = setting('OPERATIONS_IDLE_MS', 3000, 1000, 30000);
const retentionIntervalMs = setting('OPERATIONS_RETENTION_MS', 900000, 60000, 86400000);
const statementTimeout = pgInterval(process.env.OPERATIONS_STATEMENT_TIMEOUT, "120s", "OPERATIONS_STATEMENT_TIMEOUT");
const timeoutParts = /^(\d+)(ms|s|min|h)$/.exec(statementTimeout);
const timeoutMs = Number(timeoutParts[1]) * ({ ms: 1, s: 1000, min: 60000, h: 3600000 }[timeoutParts[2]]);
if (timeoutMs < 1000 || timeoutMs > 120000) throw new Error('OPERATIONS_STATEMENT_TIMEOUT must be between 1s and 120s.');

let stopping = false, connected = false;
let lastProgressAt = Date.now(), lastRetentionAt = 0;
let activeWork = '';
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });
const wait = (ms) => new Promise(resolve => setTimeout(resolve, ms));
const markProgress = () => { lastProgressAt = Date.now(); };
const healthServer = createServer((request, response) => {
  if (request.url !== '/health') { response.writeHead(404).end(); return; }
  const ageMs = Date.now() - lastProgressAt;
  const healthy = connected && !stopping && ageMs < 180000;
  response.writeHead(healthy ? 200 : 503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify({ status: healthy ? 'ok' : 'stale', activeWork: activeWork || null, ageMs, scheduler: 'atomic-round-v1' }));
});
const client = new pg.Client({ application_name: "prospect-operations-worker", connectionTimeoutMillis: 10000 });
// Connection loss is not evidence of job failure. PostgreSQL rolls back that
// statement; exit and let restart resume the last committed checkpoint.
client.on('error', () => { connected = false; stopping = true; });

async function runUnit(kind) {
  activeWork = kind;
  const started = performance.now();
  const batch = kind === 'operation' ? applyBatchSize : kind === 'export' ? exportBatchSize : batchSize;
  const { rows } = await client.query('select * from prospect_operations.run_queue_unit_v1($1,$2,$3)', [kind, workerId, batch]);
  markProgress();
  const result = rows[0];
  if (result?.job_id) console.log(JSON.stringify({ event: 'background_unit', kind, jobId: result.job_id,
    outcome: result.outcome, total: Number(result.total), done: result.done, durationMs: Math.round(performance.now() - started) }));
  activeWork = '';
  return Boolean(result?.job_id);
}

async function runRetention() {
  if (Date.now() - lastRetentionAt < retentionIntervalMs) return;
  lastRetentionAt = Date.now();
  try {
    // Existing retention is separately bounded by the session deadline.
    // Incremental reclamation is a separate lifecycle migration.
    await client.query('select prospect_results.expire_sets_v1()');
    await client.query('select prospect_filters.expire_sets_v1()');
    await client.query('select prospect_operations.expire_jobs_v1()');
    await client.query('select prospect_exports.expire_jobs_v1()');
    markProgress();
  } catch (error) { console.error('Retention pass failed', { code: error.code ?? 'unknown' }); }
}

async function main() {
  await client.connect();
  await client.query(`set statement_timeout = '${statementTimeout}'`);
  await client.query("set lock_timeout = '5s'");
  // Fail readiness before serving health if the compatible schema is absent.
  await client.query("select 'prospect_operations.run_queue_unit_v1(text,text,integer)'::regprocedure");
  connected = true;
  console.log(JSON.stringify({ event: 'worker_started', scheduler: 'atomic-round-v1', statementTimeout, batchSize, applyBatchSize, exportBatchSize }));
  const round = createFairScheduler({ classes: ['search', 'operation', 'export'], runUnit,
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
    if (!progressed && !stopping) await wait(idleDelayMs);
  }
}

await new Promise((resolve, reject) => { healthServer.once('error', reject); healthServer.listen(9091, '0.0.0.0', resolve); });
try { await main(); }
finally {
  connected = false;
  await client.end().catch(() => {});
  await new Promise(resolve => healthServer.close(resolve));
}
