import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';

if (process.env.VERIFICATION_MIGRATION_TEST_ALLOW !== '1') {
  throw new Error('Concurrency checks are restricted to the disposable verification database.');
}
const url = new URL(process.env.DATABASE_URL ?? '');
if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  || decodeURIComponent(url.pathname.slice(1)) !== 'cursor_migration_test'
  || decodeURIComponent(url.username) !== 'postgres'
  || decodeURIComponent(url.password) !== 'disposable-ci-only') {
  throw new Error('Concurrency checks require postgres@loopback/cursor_migration_test with the disposable password.');
}
const require = createRequire(new URL('../worker/package.json', import.meta.url));
const pg = require('pg');
const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 6,
  options: '-c statement_timeout=8000 -c lock_timeout=3000',
});

async function query(text, values = []) {
  return pool.query(text, values);
}
async function makeRun({ priority = 10, status = 'running', force = false } = {}) {
  const id = randomUUID();
  await query(`insert into prospect_verification.runs
    (id,request_id,payload_hash,scope,status,priority,snapshot_complete,force_reverify,started_at)
    values($1,$2,$3,'all',$4,$5,true,$6,now())`, [id, randomUUID(), randomUUID(), status, priority, force]);
  return id;
}
async function makeProspect(id, email) {
  await query(`insert into public.prospects(id,full_name,work_email) values($1,$1,$2)
    on conflict(id) do update set work_email=excluded.work_email`, [id, email]);
}
async function addTarget(run, prospect, email, floor = 0) {
  await query(`insert into prospect_verification.run_targets
    (run_id,prospect_id,normalized_email,email_revision,deletion_epoch,generation_floor)
    select $1,p.id,prospect_verification.normalize_email(p.work_email),p.work_email_revision,
      coalesce(d.deletion_epoch,0),$4 from public.prospects p
    left join prospect_verification.prospect_deletions d on d.prospect_id=p.id
    where p.id=$2 and prospect_verification.normalize_email(p.work_email)=$3`, [run, prospect, email, floor]);
  await query(`update prospect_verification.runs set total_count=total_count+1 where id=$1`, [run]);
}
async function completedCheck(email, generation = 1) {
  const id = randomUUID();
  await query(`insert into prospect_verification.email_checks
    (id,normalized_email,generation,execution_state,result_status,result_reason,provider,checked_at)
    values($1,$2,$3,'completed','valid','Accepted','mailtester_ninja',now())`, [id, email, generation]);
  return id;
}

try {
  // Reversed prospect order across overlapping runs must still acquire all
  // per-email advisory locks in one numeric order.
  await makeProspect('concurrency-a', 'concurrency-x@example.test');
  await makeProspect('concurrency-z', 'concurrency-y@example.test');
  await makeProspect('concurrency-b', 'concurrency-y@example.test');
  await makeProspect('concurrency-y', 'concurrency-x@example.test');
  const runA = await makeRun();
  const runB = await makeRun();
  await addTarget(runA, 'concurrency-a', 'concurrency-x@example.test');
  await addTarget(runA, 'concurrency-z', 'concurrency-y@example.test');
  await addTarget(runB, 'concurrency-b', 'concurrency-y@example.test');
  await addTarget(runB, 'concurrency-y', 'concurrency-x@example.test');
  await Promise.all([
    query('select public.allocate_email_verification_targets_v1($1,500)', [runA]),
    query('select public.allocate_email_verification_targets_v1($1,500)', [runB]),
  ]);
  const shared = await query(`select count(distinct check_id)::int checks,count(*)::int targets
    from prospect_verification.run_targets where run_id=any($1::uuid[])`, [[runA, runB]]);
  if (shared.rows[0].checks !== 2 || shared.rows[0].targets !== 4) throw new Error('overlapping allocation did not share exactly two email checks');

  // Reconciliation in reversed run target order locks canonical prospects by
  // ascending id, so two sessions cannot create a projection deadlock.
  const checks = await query(`select normalized_email,id from prospect_verification.email_checks
    where normalized_email in ('concurrency-x@example.test','concurrency-y@example.test') and execution_state='queued'`);
  for (const row of checks.rows) {
    await query(`update prospect_verification.email_checks set execution_state='completed',result_status='valid',
      result_reason='Accepted',provider='mailtester_ninja',checked_at=now() where id=$1`, [row.id]);
  }
  await Promise.all([
    query('select public.reconcile_email_verification_run_v1($1,500)', [runA]),
    query('select public.reconcile_email_verification_run_v1($1,500)', [runB]),
  ]);
  const done = await query(`select count(*)::int n from prospect_verification.runs
    where id=any($1::uuid[]) and status='completed' and processed_count=2`, [[runA, runB]]);
  if (done.rows[0].n !== 2) throw new Error('concurrent reversed reconciliation did not finish both runs exactly');

  // Provider settlement and allocation may meet on the same active check.
  // Their protocol (allocator RUN->CHECK; completion PROVIDER->CHECK only)
  // must converge without touching targets from the completion transaction.
  await makeProspect('concurrency-settle', 'settle@example.test');
  const settleRun = await makeRun();
  await addTarget(settleRun, 'concurrency-settle', 'settle@example.test');
  const settleCheck = randomUUID();
  const settleToken = randomUUID();
  await query(`insert into prospect_verification.email_checks
    (id,normalized_email,generation,execution_state,attempts,lease_token,lease_expires_at)
    values($1,'settle@example.test',1,'running',1,$2,now()+interval '2 minutes')`, [settleCheck, settleToken]);
  await Promise.all([
    query('select public.allocate_email_verification_targets_v1($1,500)', [settleRun]),
    query(`select public.complete_email_verification_check_v1($1,$2,'valid','Accepted','mailtester_ninja',now())`, [settleCheck, settleToken]),
  ]);
  await query('select public.reconcile_email_verification_run_v1($1,500)', [settleRun]);
  const settled = await query(`select r.status,p.verification_status from prospect_verification.runs r
    cross join public.prospects p where r.id=$1 and p.id='concurrency-settle'`, [settleRun]);
  if (settled.rows[0].status !== 'completed' || settled.rows[0].verification_status !== 'valid') {
    throw new Error('completion during allocation did not converge through reconciliation');
  }

  // A deleted and recreated public id has a newer deletion epoch. Its old
  // snapshot is skipped and can never project onto the replacement person.
  await makeProspect('concurrency-recreate', 'old-recreate@example.test');
  const recreateRun = await makeRun();
  await addTarget(recreateRun, 'concurrency-recreate', 'old-recreate@example.test');
  const recreateCheck = await completedCheck('old-recreate@example.test');
  await query(`update prospect_verification.run_targets set check_id=$2 where run_id=$1`, [recreateRun, recreateCheck]);
  const prospectLocker = await pool.connect();
  try {
    await prospectLocker.query('begin');
    await prospectLocker.query(`select 1 from public.prospects where id='concurrency-recreate' for update`);
    const deleting = query(`delete from public.prospects where id='concurrency-recreate'`);
    await new Promise(resolve => setTimeout(resolve, 75));
    const reconciling = query('select public.reconcile_email_verification_run_v1($1,500)', [recreateRun]);
    await new Promise(resolve => setTimeout(resolve, 75));
    await prospectLocker.query('commit');
    await Promise.all([reconciling, deleting]);
  } finally { prospectLocker.release(); }
  await makeProspect('concurrency-recreate', 'old-recreate@example.test');
  await query('select public.reconcile_email_verification_run_v1($1,500)', [recreateRun]);
  const recreated = await query(`select r.skipped_count,p.verification_status from prospect_verification.runs r
    cross join public.prospects p where r.id=$1 and p.id='concurrency-recreate'`, [recreateRun]);
  if (recreated.rows[0].skipped_count !== 1 || recreated.rows[0].verification_status !== null) {
    throw new Error('delete/recreate epoch fence allowed a stale label');
  }

  // Pause/Cancel update only the run row. If control is queued behind an
  // existing run lock, claim uses SKIP LOCKED and cannot slip through later.
  await makeProspect('concurrency-control', 'control@example.test');
  const controlRun = await makeRun({ priority: 40 });
  await addTarget(controlRun, 'concurrency-control', 'control@example.test');
  await query('select public.allocate_email_verification_targets_v1($1,500)', [controlRun]);
  await query(`update prospect_verification.runs set status='paused'
    where id<>$1 and status in ('running','preparing','queued')`, [controlRun]);
  await query(`update prospect_verification.provider_control set enabled=true,manually_paused=false,
    cooldown_until=null,next_dispatch_at=now()-interval '1 second',daily_limit=150000 where singleton`);
  const controlLocker = await pool.connect();
  try {
    await controlLocker.query('begin');
    await controlLocker.query('select 1 from prospect_verification.runs where id=$1 for update', [controlRun]);
    const pausing = query(`select public.control_email_verification_run_v1($1,'pause')`, [controlRun]);
    await new Promise(resolve => setTimeout(resolve, 75));
    const claimWhilePausing = await query(`select public.claim_email_verification_check_v1('pause-race',120,4) unit`);
    if (claimWhilePausing.rows[0].unit !== null) throw new Error('claim crossed a pending Pause fence');
    await controlLocker.query('commit');
    await pausing;
  } finally { controlLocker.release(); }
  const pausedStatus = await query('select status from prospect_verification.runs where id=$1', [controlRun]);
  if (pausedStatus.rows[0].status !== 'paused') throw new Error('Pause race did not preserve paused state');
  await query(`select public.control_email_verification_run_v1($1,'continue')`, [controlRun]);
  const cancelLocker = await pool.connect();
  try {
    await cancelLocker.query('begin');
    await cancelLocker.query('select 1 from prospect_verification.runs where id=$1 for update', [controlRun]);
    const cancelling = query(`select public.control_email_verification_run_v1($1,'cancel')`, [controlRun]);
    await new Promise(resolve => setTimeout(resolve, 75));
    await query(`update prospect_verification.provider_control set next_dispatch_at=now()-interval '1 second' where singleton`);
    const claimWhileCancelling = await query(`select public.claim_email_verification_check_v1('cancel-race',120,4) unit`);
    if (claimWhileCancelling.rows[0].unit !== null) throw new Error('claim crossed a pending Cancel fence');
    await cancelLocker.query('commit');
    await cancelling;
  } finally { cancelLocker.release(); }
  await query('select public.reconcile_email_verification_run_v1($1,500)', [controlRun]);
  const cancelledStatus = await query('select status,cancelled_count,processed_count from prospect_verification.runs where id=$1', [controlRun]);
  if (cancelledStatus.rows[0].status !== 'cancelled' || cancelledStatus.rows[0].cancelled_count !== 1 || cancelledStatus.rows[0].processed_count !== 1) {
    throw new Error('Cancel race did not retain the same run and exact counters');
  }

  // Two recovery workers may see the same exhausted lease; SKIP LOCKED makes
  // exactly one terminal transition and reconciliation counts it once.
  await makeProspect('concurrency-expired', 'expired@example.test');
  const expiredRun = await makeRun();
  await addTarget(expiredRun, 'concurrency-expired', 'expired@example.test');
  const expiredCheck = randomUUID();
  await query(`insert into prospect_verification.email_checks
    (id,normalized_email,generation,execution_state,attempts,lease_token,lease_expires_at)
    values($1,'expired@example.test',1,'running',4,$2,now()-interval '1 second')`, [expiredCheck, randomUUID()]);
  await query(`update prospect_verification.run_targets set check_id=$2 where run_id=$1`, [expiredRun, expiredCheck]);
  const expired = await Promise.all([
    query('select public.expire_email_verification_leases_v1(4,500) n'),
    query('select public.expire_email_verification_leases_v1(4,500) n'),
  ]);
  if (expired.reduce((sum, result) => sum + result.rows[0].n, 0) !== 1) throw new Error('expired lease was not settled exactly once');
  await query('select public.reconcile_email_verification_run_v1($1,500)', [expiredRun]);
  const expiredState = await query('select status,processed_count,error_count from prospect_verification.runs where id=$1', [expiredRun]);
  if (expiredState.rows[0].status !== 'completed_with_errors' || expiredState.rows[0].processed_count !== 1 || expiredState.rows[0].error_count !== 1) {
    throw new Error('exhausted lease reconciliation counters drifted');
  }

  // A locked preferred run must not starve another runnable run. Candidate
  // probing skips the busy run and claims serviceable demand.
  await query(`update prospect_verification.provider_control set enabled=true,manually_paused=false,
    cooldown_until=null,next_dispatch_at=now()-interval '1 second',daily_limit=150000 where singleton`);
  const busyRun = await makeRun({ priority: 30 });
  const liveRun = await makeRun({ priority: 20 });
  await makeProspect('concurrency-busy', 'busy@example.test');
  await makeProspect('concurrency-live', 'live@example.test');
  await addTarget(busyRun, 'concurrency-busy', 'busy@example.test');
  await addTarget(liveRun, 'concurrency-live', 'live@example.test');
  await query('select public.allocate_email_verification_targets_v1($1,500)', [busyRun]);
  await query('select public.allocate_email_verification_targets_v1($1,500)', [liveRun]);
  const locker = await pool.connect();
  try {
    await locker.query('begin');
    await locker.query('select 1 from prospect_verification.runs where id=$1 for update', [busyRun]);
    const claimed = await query(`select public.claim_email_verification_check_v1('concurrency',120,4) unit`);
    if (claimed.rows[0].unit?.email !== 'live@example.test') throw new Error('busy preferred run starved serviceable live demand');
    await locker.query('rollback');
  } finally { locker.release(); }

  process.stdout.write('Multi-session verification allocation, reconciliation, deletion fence, and busy-run serviceability passed.\n');
} finally {
  await pool.end();
}
