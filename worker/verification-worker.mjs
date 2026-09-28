import pg from 'pg';
import { createServer } from 'node:http';
import { MtnRequestError, normalizeMtnKey, verifyWithMtn } from './mtn-client.mjs';
import { fillDispatchSlots, PROVIDER_START_SPACING_MS } from './verification-scheduler.mjs';

const workerId = `${process.env.HOSTNAME ?? 'verification-worker'}:${process.pid}`;
const apiKey = normalizeMtnKey(process.env.MTN_API_KEY);
const concurrency = Math.max(1, Math.min(Number(process.env.MTN_CONCURRENCY ?? 8), 16));
const timeoutMs = Math.max(5_000, Math.min(Number(process.env.MTN_TIMEOUT_MS ?? 45_000), 90_000));
const maxAttempts = Math.max(1, Math.min(Number(process.env.MTN_MAX_ATTEMPTS ?? 4), 8));
const idleMs = Math.max(250, Math.min(Number(process.env.VERIFICATION_IDLE_MS ?? 1500), 30_000));
let stopping = false, connected = false, lastProgress = Date.now();
let workerFault = null;
let snapshotPromise = null;
const inFlight = new Set();
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });

function markFatal(fault) {
  workerFault = fault;
  stopping = true;
  process.exitCode = 1;
}

const db = new pg.Pool({ max: 2, application_name: 'prospect-verification-worker', connectionTimeoutMillis: 10_000 });
db.on('error', () => { connected = false; markFatal('database_connection_failed'); });

const health = createServer((request, response) => {
  if (request.url !== '/health') { response.writeHead(404).end(); return; }
  const healthy = connected && !stopping && !workerFault;
  response.writeHead(healthy ? 200 : 503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify({ status: healthy ? 'ok' : 'unavailable', configured: Boolean(apiKey), inFlight: inFlight.size,
    snapshotInProgress: Boolean(snapshotPromise), idle: inFlight.size === 0, lastProgressAgeMs: Date.now() - lastProgress,
    fault: workerFault }));
});

function retryDelay(attempt) {
  const base = Math.min(60_000, 1_000 * 2 ** Math.max(0, attempt - 1));
  return base + Math.floor(Math.random() * Math.max(250, base * 0.25));
}

const transientDatabaseCodes = new Set([
  '40001', '40P01', '55P03', '57P01', '57P02', '57P03',
  '08000', '08001', '08003', '08004', '08006', '08007', '08P01', '53300',
  'ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ECONNREFUSED',
]);

function transientDatabaseError(error) {
  return Boolean(error && typeof error === 'object' && transientDatabaseCodes.has(error.code));
}

async function queryWithRetry(text, values = [], attempts = 8) {
  let delay = 100;
  for (let attempt = 1; ; attempt += 1) {
    try { return await db.query(text, values); }
    catch (error) {
      connected = false;
      if (!transientDatabaseError(error) || attempt >= attempts || stopping) throw error;
      await wait(delay);
      delay = Math.min(5_000, delay * 2);
      connected = true;
    }
  }
}

async function saveRetry(unit, error) {
  const terminal = error.code === 'malformed_address'
    || (unit.attempt >= maxAttempts && !['rate_limited', 'auth', 'account'].includes(error.code));
  const delayMs = error.retryAfterMs || retryDelay(unit.attempt);
  const pauseMs = error.providerPauseMs || (error.code === 'rate_limited' ? delayMs : 0);
  await queryWithRetry('select public.retry_email_verification_check_v1($1,$2,$3,$4,$5,$6,$7)', [
    unit.id, unit.leaseToken, error.code, Math.ceil(delayMs / 1000), terminal,
    pauseMs ? Math.ceil(pauseMs / 1000) : null,
    error.code === 'auth' || error.code === 'account' ? 'Provider authorization requires attention'
      : error.code === 'rate_limited' ? 'Provider rate limit cooldown' : error.code === 'provider_outage' ? 'Provider outage cooldown' : null,
  ], 60);
  workerFault = null;
}

async function processUnit(unit) {
  let result;
  try {
    result = await verifyWithMtn(unit.email, { apiKey, timeoutMs });
  } catch (error) {
    await saveRetry(unit, error instanceof MtnRequestError ? error : new MtnRequestError('network'));
    return;
  }
  try {
    if (result.kind === 'transient') {
      await saveRetry(unit, new MtnRequestError('transient_result'));
      return;
    }
    // A database write failure is not a provider failure. Retry only the fenced
    // result save; never call the paid HTTP endpoint again from this task.
    await queryWithRetry('select public.complete_email_verification_check_v1($1,$2,$3,$4,$5,$6)', [
      unit.id, unit.leaseToken, result.status, result.reason, 'mailtester_ninja', new Date().toISOString(),
    ], 60);
    workerFault = null;
  } finally {
    lastProgress = Date.now();
  }
}

async function claimOne() {
  const { rows } = await queryWithRetry('select public.claim_email_verification_check_v1($1,$2,$3) as unit', [workerId, Math.ceil(timeoutMs / 1000) + 30, maxAttempts]);
  return rows[0]?.unit ?? null;
}

async function prepareSnapshot(reservation) {
  let delay = 250;
  for (let attempt = 1; attempt <= 6; attempt += 1) {
    const client = await db.connect();
    try {
      await client.query('begin');
      await client.query("set local statement_timeout='12min'");
      await client.query("set local lock_timeout='3s'");
      await client.query('select public.prepare_email_verification_run_v1($1,$2,$3)', [reservation.id, reservation.preparationToken, 2_000_000]);
      await client.query('commit');
      lastProgress = Date.now();
      workerFault = null;
      return;
    } catch (error) {
      await client.query('rollback').catch(() => {});
      if (!transientDatabaseError(error) || attempt === 6 || stopping) throw error;
    } finally { client.release(); }
    await wait(delay);
    delay = Math.min(5_000, delay * 2);
  }
}

async function maintain() {
  await queryWithRetry('select public.expire_email_verification_leases_v1($1,$2)', [maxAttempts, 500]);
  const allocating = await queryWithRetry('select public.next_email_verification_allocation_run_v1() as id');
  if (allocating.rows[0]?.id) await queryWithRetry('select public.allocate_email_verification_targets_v1($1,$2)', [allocating.rows[0].id, 500]);
  const reconciling = await queryWithRetry('select public.next_email_verification_reconciliation_run_v1() as id');
  if (reconciling.rows[0]?.id) await queryWithRetry('select public.reconcile_email_verification_run_v1($1,$2)', [reconciling.rows[0].id, 500]);
  if (!snapshotPromise) {
    const reserved = await queryWithRetry('select public.prepare_next_email_verification_run_v1($1) as reservation', [900]);
    const reservation = reserved.rows[0]?.reservation;
    if (reservation) {
      snapshotPromise = prepareSnapshot(reservation)
        .catch(() => { markFatal('snapshot_persistence_failed'); })
        .finally(() => { snapshotPromise = null; });
    }
  }
}

async function main() {
  const client = await db.connect();
  try {
    await client.query("set statement_timeout='30s'");
    await client.query("set lock_timeout='3s'");
    await client.query("select 'public.prepare_next_email_verification_run_v1(integer)'::regprocedure");
    await client.query("select 'public.prepare_email_verification_run_v1(uuid,uuid,integer)'::regprocedure");
    await client.query("select 'public.allocate_email_verification_targets_v1(uuid,integer)'::regprocedure");
    await client.query("select 'public.reconcile_email_verification_run_v1(uuid,integer)'::regprocedure");
    await client.query("select 'public.claim_email_verification_check_v1(text,integer,integer)'::regprocedure");
    await client.query('select public.report_email_verification_worker_v1($1)', [Boolean(apiKey)]);
  } finally { client.release(); }
  connected = true;
  console.log(JSON.stringify({ event: 'verification_worker_started', configured: Boolean(apiKey), concurrency, requestSpacingMs: PROVIDER_START_SPACING_MS }));
  let lastHeartbeat = Date.now();
  let lastClaimAt = 0;
  while (!stopping) {
    if (Date.now() - lastHeartbeat > 30_000) {
      await db.query('select public.report_email_verification_worker_v1($1)', [Boolean(apiKey)]);
      lastHeartbeat = Date.now();
    }
    await maintain();
    let started = 0;
    if (apiKey && !stopping) {
      const filled = await fillDispatchSlots({
        maxStarts: concurrency,
        concurrency,
        inFlightSize: () => inFlight.size,
        claim: claimOne,
        start: unit => {
          const task = processUnit(unit)
            .catch(() => { markFatal('result_persistence_failed'); })
            .finally(() => inFlight.delete(task));
          inFlight.add(task);
        },
        wait,
        lastClaimAt,
        canStart: () => !stopping,
      });
      started = filled.started;
      lastClaimAt = filled.lastClaimAt;
    }
    await wait(started ? 100 : idleMs);
  }
  if (snapshotPromise) await snapshotPromise;
  await Promise.allSettled([...inFlight]);
}

await new Promise((resolve, reject) => { health.once('error', reject); health.listen(9093, '0.0.0.0', resolve); });
try { await main(); }
catch { console.error('Verification worker stopped; leased checks remain fenced for retry.'); process.exitCode = 1; }
finally { connected = false; await db.end().catch(() => {}); await new Promise(resolve => health.close(resolve)); }
