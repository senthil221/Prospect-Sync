import pg from 'pg';
import { createServer } from 'node:http';
import {
  buildBatch, buildSystemPrompt, callOpenRouter, failurePlan, IcpOutputError, OpenRouterError, parseModelOutput,
} from './icp-validator-core.mjs';

// The ICP validator's worker. It leases 20 companies at a time from
// icp_validation_items, asks the run's model on OpenRouter for FIT/NON_FIT,
// and saves the answers. It logs in as prospect_icp_worker, which can execute
// four functions and read nothing else.
//
// An empty OPENROUTER_API_KEY is a healthy, idle configuration: runs wait in
// the queue and the page says the key is missing.

const workerId = `${process.env.HOSTNAME ?? 'icp-worker'}:${process.pid}`;
const apiKey = String(process.env.OPENROUTER_API_KEY ?? '').trim();
const concurrency = Math.max(1, Math.min(Number(process.env.ICP_CONCURRENCY ?? 4) || 4, 12));
const timeoutMs = Math.max(20_000, Math.min(Number(process.env.ICP_TIMEOUT_MS ?? 150_000) || 150_000, 300_000));
const referer = String(process.env.ICP_APP_URL ?? '').trim();
// Long enough for a slow reasoning call plus two rate-limit waits; a lease
// that outlives its worker simply expires and the rows go back in line.
const leaseSeconds = Math.ceil(timeoutMs / 1000) + 120;
const idleMs = 1_500;

let stopping = false, connected = false, lastProgress = Date.now(), cooldownUntil = 0, fault = null;
const inFlight = new Set();
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
process.on('SIGTERM', () => { stopping = true; });
process.on('SIGINT', () => { stopping = true; });

const db = new pg.Pool({ max: 2, application_name: 'prospect-icp-worker', connectionTimeoutMillis: 10_000 });
db.on('error', () => { connected = false; fault = 'database_connection_failed'; stopping = true; process.exitCode = 1; });

const health = createServer((request, response) => {
  if (request.url !== '/health') { response.writeHead(404).end(); return; }
  const healthy = connected && !stopping && !fault;
  response.writeHead(healthy ? 200 : 503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify({ status: healthy ? 'ok' : 'unavailable', configured: Boolean(apiKey), inFlight: inFlight.size,
    lastProgressAgeMs: Date.now() - lastProgress, fault }));
});

const transientDatabaseCodes = new Set([
  '40001', '40P01', '55P03', '57P01', '57P02', '57P03', '57014',
  '08000', '08001', '08003', '08004', '08006', '08007', '08P01', '53300',
  'ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ECONNREFUSED',
]);

async function query(text, values = [], attempts = 8) {
  let delay = 200;
  for (let attempt = 1; ; attempt += 1) {
    try {
      const result = await db.query(text, values);
      connected = true;
      return result;
    } catch (error) {
      if (!transientDatabaseCodes.has(error?.code) || attempt >= attempts) throw error;
      await wait(delay);
      delay = Math.min(5_000, delay * 2);
    }
  }
}

const log = (event) => console.log(JSON.stringify(event));

async function callWithRateLimitRetry(args) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await callOpenRouter(args);
    } catch (error) {
      if (!(error instanceof OpenRouterError) || error.kind !== 'rate_limited' || attempt >= 3 || stopping) throw error;
      const pause = error.retryAfterMs || 15_000 * attempt;
      cooldownUntil = Math.max(cooldownUntil, Date.now() + pause);
      await wait(pause);
    }
  }
}

async function processBatch(unit) {
  const batch = buildBatch(unit.rows);
  let answer;
  try {
    answer = await callWithRateLimitRetry({
      apiKey, model: unit.model, effort: unit.reasoning_effort, referer, timeoutMs,
      system: buildSystemPrompt(unit.icp_text), user: batch.user,
    });
    const { results, missing } = parseModelOutput(answer.content, batch);
    const saved = await query('select public.complete_icp_validation_batch_v1($1, $2, $3, $4) as saved',
      [unit.run_id, unit.token, JSON.stringify(results), JSON.stringify(answer.usage)]);
    log({ event: 'icp_batch', run: unit.run_id, model: unit.model, rows: batch.rows.length, saved: saved.rows[0]?.saved?.saved ?? 0,
      missing: missing.length, ms: answer.usage.ms, cost: answer.usage.cost, provider: answer.provider });
  } catch (error) {
    const plan = failurePlan(error);
    const usage = error?.usage ?? answer?.usage ?? {};
    const message = error instanceof IcpOutputError || error instanceof OpenRouterError ? error.message : 'Unexpected worker error';
    await query('select public.fail_icp_validation_batch_v1($1, $2, $3, $4, $5, $6, $7)',
      [unit.run_id, unit.token, message, plan.retry, plan.pauseScope, plan.message, JSON.stringify(usage)], 60);
    log({ event: 'icp_batch_failed', run: unit.run_id, model: unit.model, rows: batch.rows.length, kind: error?.kind ?? 'unknown',
      retry: plan.retry, pause: plan.pauseScope, message: message.slice(0, 300) });
  } finally {
    lastProgress = Date.now();
  }
}

async function claim() {
  const { rows } = await query('select public.claim_icp_validation_batch_v1($1, $2) as unit', [workerId, leaseSeconds]);
  const unit = rows[0]?.unit ?? null;
  return unit && Array.isArray(unit.rows) && unit.rows.length ? unit : null;
}

async function main() {
  await query("select 'public.claim_icp_validation_batch_v1(text,integer)'::regprocedure");
  await query("select 'public.complete_icp_validation_batch_v1(uuid,uuid,jsonb,jsonb)'::regprocedure");
  await query("select 'public.fail_icp_validation_batch_v1(uuid,uuid,text,boolean,text,text,jsonb)'::regprocedure");
  await query('select public.report_icp_worker_v1($1, $2)', [Boolean(apiKey), workerId]);
  connected = true;
  log({ event: 'icp_worker_started', configured: Boolean(apiKey), concurrency, timeoutMs });

  let lastHeartbeat = Date.now();
  while (!stopping) {
    if (Date.now() - lastHeartbeat > 30_000) {
      await query('select public.report_icp_worker_v1($1, $2)', [Boolean(apiKey), workerId]);
      lastHeartbeat = Date.now();
    }
    let started = 0;
    while (apiKey && !stopping && inFlight.size < concurrency && Date.now() >= cooldownUntil) {
      const unit = await claim();
      if (!unit) break;
      const task = processBatch(unit)
        .catch(() => { fault = 'result_persistence_failed'; stopping = true; process.exitCode = 1; })
        .finally(() => inFlight.delete(task));
      inFlight.add(task);
      started += 1;
      // Spread call starts so a fresh run does not fire every slot at once.
      await wait(250);
    }
    await wait(started ? 250 : idleMs);
  }
  // In-flight calls get the stop grace period to land; anything still leased
  // after that expires and is retried, never lost.
  await Promise.race([Promise.allSettled([...inFlight]), wait(50_000)]);
}

await new Promise((resolve, reject) => { health.once('error', reject); health.listen(9094, '0.0.0.0', resolve); });
try { await main(); }
catch (error) { console.error(JSON.stringify({ event: 'icp_worker_stopped', code: error?.code ?? '', message: String(error?.message ?? error).slice(0, 300) })); process.exitCode = 1; }
finally { connected = false; await db.end().catch(() => {}); await new Promise((resolve) => health.close(resolve)); }
