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
const iteration = new URL(import.meta.url).searchParams.get('iteration') ?? '0';
const fixtureTag = `${iteration}-${randomUUID().replaceAll('-', '').slice(0, 10)}`;
const fixtureId = label => `concurrency-${fixtureTag}-${label}`;
const fixtureEmail = label => `${label}-${fixtureTag}@example.test`;
let stage = `iteration ${iteration}: setup`;

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

async function backendPid(client) {
  return Number((await client.query('select pg_backend_pid() pid')).rows[0].pid);
}

async function waitForBlock(waitingPid, label, blockerPid = null) {
  const deadline = Date.now() + 4_000;
  while (Date.now() < deadline) {
    const state = await query(`select state,wait_event_type,pg_blocking_pids(pid) blockers
      from pg_stat_activity where pid=$1`, [waitingPid]);
    const row = state.rows[0];
    const blockers = (row?.blockers ?? []).map(Number);
    if (row?.state === 'active' && row.wait_event_type === 'Lock'
      && blockers.length && (blockerPid === null || blockers.includes(blockerPid))) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error(`${label} did not reach its required PostgreSQL lock barrier`);
}

try {
  stage = `iteration ${iteration}: concurrent bounded snapshot preparation`;
  const boundedEmailA = fixtureEmail('bounded-a');
  const boundedEmailB = fixtureEmail('bounded-b');
  const boundedEmailC = fixtureEmail('bounded-c');
  const boundedProspects = [fixtureId('bounded-a1'), fixtureId('bounded-a2'), fixtureId('bounded-b'), fixtureId('bounded-c')];
  await makeProspect(boundedProspects[0], boundedEmailA);
  await makeProspect(boundedProspects[1], boundedEmailA);
  await makeProspect(boundedProspects[2], boundedEmailB);
  await makeProspect(boundedProspects[3], boundedEmailC);
  await query('select public.reindex_prospects($1::text[])', [boundedProspects]);
  const boundedRun = randomUUID();
  const preparationToken = randomUUID();
  const boundedFilters = JSON.stringify([{ field: '__work_email', operator: 'contains', values: [fixtureTag] }]);
  await query(`insert into prospect_verification.runs
    (id,request_id,payload_hash,scope,filters,status,priority,snapshot_complete,force_reverify,
      max_emails,preparation_token,preparation_lease_expires_at,started_at)
    values($1,$2,$3,'filtered',$4::jsonb,'preparing',10,false,false,2,$5,now()+interval '15 minutes',now())`,
  [boundedRun, randomUUID(), randomUUID(), boundedFilters, preparationToken]);
  await Promise.all([
    query('select public.prepare_email_verification_run_v1($1,$2,100)', [boundedRun, preparationToken]),
    query('select public.prepare_email_verification_run_v1($1,$2,100)', [boundedRun, preparationToken]),
  ]);
  const boundedState = await query(`select r.status,r.total_count,r.eligible_email_count,r.selected_email_count,
      count(distinct t.normalized_email)::int selected_addresses,count(*)::int selected_people
    from prospect_verification.runs r
    left join prospect_verification.run_targets t on t.run_id=r.id
    where r.id=$1
    group by r.id`, [boundedRun]);
  const bounded = boundedState.rows[0];
  if (bounded.status !== 'running' || bounded.eligible_email_count !== 3 || bounded.selected_email_count !== 2
    || bounded.total_count !== 3 || bounded.selected_addresses !== 2 || bounded.selected_people !== 3) {
    throw new Error(`concurrent capped preparation drifted: ${JSON.stringify(bounded)}`);
  }
  await query(`select public.control_email_verification_run_v1($1,'cancel')`, [boundedRun]);

  stage = `iteration ${iteration}: crossed allocation and reconciliation`;
  // Reversed prospect order across overlapping runs must still acquire all
  // per-email advisory locks in one numeric order.
  const prospectA = fixtureId('a');
  const prospectZ = fixtureId('z');
  const prospectB = fixtureId('b');
  const prospectY = fixtureId('y');
  const emailX = fixtureEmail('x');
  const emailY = fixtureEmail('y');
  await makeProspect(prospectA, emailX);
  await makeProspect(prospectZ, emailY);
  await makeProspect(prospectB, emailY);
  await makeProspect(prospectY, emailX);
  const runA = await makeRun();
  const runB = await makeRun();
  await addTarget(runA, prospectA, emailX);
  await addTarget(runA, prospectZ, emailY);
  await addTarget(runB, prospectB, emailY);
  await addTarget(runB, prospectY, emailX);
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
    where normalized_email=any($1::text[]) and execution_state='queued'`, [[emailX, emailY]]);
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
  stage = `iteration ${iteration}: completion during allocation`;
  const settleProspect = fixtureId('settle');
  const settleEmail = fixtureEmail('settle');
  await makeProspect(settleProspect, settleEmail);
  const settleRun = await makeRun();
  await addTarget(settleRun, settleProspect, settleEmail);
  const settleCheck = randomUUID();
  const settleToken = randomUUID();
  await query(`insert into prospect_verification.email_checks
    (id,normalized_email,generation,execution_state,attempts,lease_token,lease_expires_at)
    values($1,$2,1,'running',1,$3,now()+interval '2 minutes')`, [settleCheck, settleEmail, settleToken]);
  await Promise.all([
    query('select public.allocate_email_verification_targets_v1($1,500)', [settleRun]),
    query(`select public.complete_email_verification_check_v1($1,$2,'valid','Accepted','mailtester_ninja',now())`, [settleCheck, settleToken]),
  ]);
  await query('select public.reconcile_email_verification_run_v1($1,500)', [settleRun]);
  const settled = await query(`select r.status,p.verification_status from prospect_verification.runs r
    cross join public.prospects p where r.id=$1 and p.id=$2`, [settleRun, settleProspect]);
  if (settled.rows[0].status !== 'completed' || settled.rows[0].verification_status !== 'valid') {
    throw new Error('completion during allocation did not converge through reconciliation');
  }

  // The same meeting, forced into its worst order instead of left to timing:
  // the completion holds the check row uncommitted, allocation's in-flight
  // lookup blocks on it, and only then does the completion commit. Allocation
  // must attach the target to that now-completed check - never queue a second
  // paid check for the address (20260929220000).
  stage = `iteration ${iteration}: allocation waits on a committing completion`;
  const waitProspect = fixtureId('wait-settle');
  const waitEmail = fixtureEmail('wait-settle');
  await makeProspect(waitProspect, waitEmail);
  const waitRun = await makeRun();
  await addTarget(waitRun, waitProspect, waitEmail);
  const waitCheck = randomUUID();
  const waitToken = randomUUID();
  await query(`insert into prospect_verification.email_checks
    (id,normalized_email,generation,execution_state,attempts,lease_token,lease_expires_at)
    values($1,$2,1,'running',1,$3,now()+interval '2 minutes')`, [waitCheck, waitEmail, waitToken]);
  const completer = await pool.connect();
  const allocator = await pool.connect();
  try {
    await completer.query('begin');
    await completer.query(`select public.complete_email_verification_check_v1($1,$2,'valid','Accepted','mailtester_ninja',now())`, [waitCheck, waitToken]);
    // Settled into a value at once, so an allocation error surfaces here with
    // its stage instead of crashing the process as an unhandled rejection.
    const allocatorPid = await backendPid(allocator);
    const completerPid = await backendPid(completer);
    const allocating = allocator.query('select public.allocate_email_verification_targets_v1($1,500)', [waitRun])
      .then(() => null, error => error);
    await waitForBlock(allocatorPid, 'allocation behind a committing completion', completerPid);
    await completer.query('commit');
    const allocationError = await allocating;
    if (allocationError) throw allocationError;
  } catch (error) {
    await completer.query('rollback').catch(() => {});
    throw error;
  } finally {
    completer.release();
    allocator.release();
  }
  const attached = await query(`select t.check_id,t.reuse_result,
      (select count(*)::int from prospect_verification.email_checks c where c.normalized_email=$2) checks
    from prospect_verification.run_targets t where t.run_id=$1`, [waitRun, waitEmail]);
  if (attached.rows[0]?.check_id !== waitCheck || attached.rows[0].reuse_result !== true || attached.rows[0].checks !== 1) {
    throw new Error(`allocation behind a committing completion queued a duplicate check: ${JSON.stringify(attached.rows[0])}`);
  }
  await query('select public.reconcile_email_verification_run_v1($1,500)', [waitRun]);
  const waited = await query(`select r.status,p.verification_status from prospect_verification.runs r
    cross join public.prospects p where r.id=$1 and p.id=$2`, [waitRun, waitProspect]);
  if (waited.rows[0].status !== 'completed' || waited.rows[0].verification_status !== 'valid') {
    throw new Error('allocation behind a committing completion did not converge through reconciliation');
  }

  // A deleted and recreated public id has a newer deletion epoch. Its old
  // snapshot is skipped and can never project onto the replacement person.
  stage = `iteration ${iteration}: delete versus reconciliation epoch fence`;
  const recreateProspect = fixtureId('recreate');
  const recreateEmail = fixtureEmail('old-recreate');
  await makeProspect(recreateProspect, recreateEmail);
  const recreateRun = await makeRun();
  await addTarget(recreateRun, recreateProspect, recreateEmail);
  const recreateCheck = await completedCheck(recreateEmail);
  await query(`update prospect_verification.run_targets set check_id=$2 where run_id=$1`, [recreateRun, recreateCheck]);
  const prospectLocker = await pool.connect();
  const deleteClient = await pool.connect();
  const reconcileClient = await pool.connect();
  try {
    await prospectLocker.query('begin');
    const lockerPid = await backendPid(prospectLocker);
    await prospectLocker.query('select 1 from public.prospects where id=$1 for update', [recreateProspect]);
    const deletePid = await backendPid(deleteClient);
    const deleting = deleteClient.query('delete from public.prospects where id=$1', [recreateProspect]);
    await waitForBlock(deletePid, 'delete', lockerPid);
    const reconcilePid = await backendPid(reconcileClient);
    const reconciling = reconcileClient.query('select public.reconcile_email_verification_run_v1($1,500)', [recreateRun]);
    await waitForBlock(reconcilePid, 'reconciliation');
    await prospectLocker.query('commit');
    await Promise.all([reconciling, deleting]);
  } finally {
    await prospectLocker.query('rollback').catch(() => undefined);
    prospectLocker.release(); deleteClient.release(); reconcileClient.release();
  }
  await makeProspect(recreateProspect, recreateEmail);
  await query('select public.reconcile_email_verification_run_v1($1,500)', [recreateRun]);
  const recreated = await query(`select r.skipped_count,p.verification_status from prospect_verification.runs r
    cross join public.prospects p where r.id=$1 and p.id=$2`, [recreateRun, recreateProspect]);
  if (recreated.rows[0].skipped_count !== 1 || recreated.rows[0].verification_status !== null) {
    throw new Error('delete/recreate epoch fence allowed a stale label');
  }

  // Pause/Cancel update only the run row. If control is queued behind an
  // existing run lock, claim uses SKIP LOCKED and cannot slip through later.
  stage = `iteration ${iteration}: claim versus Pause and Cancel fences`;
  const controlProspect = fixtureId('control');
  const controlEmail = fixtureEmail('control');
  await makeProspect(controlProspect, controlEmail);
  const controlRun = await makeRun({ priority: 40 });
  await addTarget(controlRun, controlProspect, controlEmail);
  await query('select public.allocate_email_verification_targets_v1($1,500)', [controlRun]);
  await query(`update prospect_verification.runs set status='paused'
    where id<>$1 and status in ('running','preparing','queued')`, [controlRun]);
  await query(`update prospect_verification.provider_control set enabled=true,manually_paused=false,
    cooldown_until=null,next_dispatch_at=now()-interval '1 second',daily_limit=150000 where singleton`);
  const controlLocker = await pool.connect();
  const pauseClient = await pool.connect();
  try {
    await controlLocker.query('begin');
    const lockerPid = await backendPid(controlLocker);
    await controlLocker.query('select 1 from prospect_verification.runs where id=$1 for update', [controlRun]);
    const pausePid = await backendPid(pauseClient);
    const pausing = pauseClient.query(`select public.control_email_verification_run_v1($1,'pause')`, [controlRun]);
    await waitForBlock(pausePid, 'Pause control', lockerPid);
    const claimWhilePausing = await query(`select public.claim_email_verification_check_v1($1,120,4) unit`, [`pause-race-${fixtureTag}`]);
    if (claimWhilePausing.rows[0].unit !== null) throw new Error('claim crossed a pending Pause fence');
    await controlLocker.query('commit');
    await pausing;
  } finally {
    await controlLocker.query('rollback').catch(() => undefined);
    controlLocker.release(); pauseClient.release();
  }
  const pausedStatus = await query('select status from prospect_verification.runs where id=$1', [controlRun]);
  if (pausedStatus.rows[0].status !== 'paused') throw new Error('Pause race did not preserve paused state');
  await query(`select public.control_email_verification_run_v1($1,'continue')`, [controlRun]);
  const cancelLocker = await pool.connect();
  const cancelClient = await pool.connect();
  try {
    await cancelLocker.query('begin');
    const lockerPid = await backendPid(cancelLocker);
    await cancelLocker.query('select 1 from prospect_verification.runs where id=$1 for update', [controlRun]);
    const cancelPid = await backendPid(cancelClient);
    const cancelling = cancelClient.query(`select public.control_email_verification_run_v1($1,'cancel')`, [controlRun]);
    await waitForBlock(cancelPid, 'Cancel control', lockerPid);
    await query(`update prospect_verification.provider_control set next_dispatch_at=now()-interval '1 second' where singleton`);
    const claimWhileCancelling = await query(`select public.claim_email_verification_check_v1($1,120,4) unit`, [`cancel-race-${fixtureTag}`]);
    if (claimWhileCancelling.rows[0].unit !== null) throw new Error('claim crossed a pending Cancel fence');
    await cancelLocker.query('commit');
    await cancelling;
  } finally {
    await cancelLocker.query('rollback').catch(() => undefined);
    cancelLocker.release(); cancelClient.release();
  }
  await query('select public.reconcile_email_verification_run_v1($1,500)', [controlRun]);
  const cancelledStatus = await query('select status,cancelled_count,processed_count from prospect_verification.runs where id=$1', [controlRun]);
  if (cancelledStatus.rows[0].status !== 'cancelled' || cancelledStatus.rows[0].cancelled_count !== 1 || cancelledStatus.rows[0].processed_count !== 1) {
    throw new Error('Cancel race did not retain the same run and exact counters');
  }

  // Two recovery workers may see the same exhausted lease; SKIP LOCKED makes
  // exactly one terminal transition and reconciliation counts it once.
  stage = `iteration ${iteration}: concurrent exhausted lease recovery`;
  const expiredProspect = fixtureId('expired');
  const expiredEmail = fixtureEmail('expired');
  await makeProspect(expiredProspect, expiredEmail);
  const expiredRun = await makeRun();
  await addTarget(expiredRun, expiredProspect, expiredEmail);
  const expiredCheck = randomUUID();
  await query(`insert into prospect_verification.email_checks
    (id,normalized_email,generation,execution_state,attempts,lease_token,lease_expires_at)
    values($1,$2,1,'running',4,$3,now()-interval '1 second')`, [expiredCheck, expiredEmail, randomUUID()]);
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
  stage = `iteration ${iteration}: busy preferred run serviceability`;
  await query(`update prospect_verification.provider_control set enabled=true,manually_paused=false,
    cooldown_until=null,next_dispatch_at=now()-interval '1 second',daily_limit=150000 where singleton`);
  const busyRun = await makeRun({ priority: 30 });
  const liveRun = await makeRun({ priority: 20 });
  const busyProspect = fixtureId('busy');
  const liveProspect = fixtureId('live');
  const busyEmail = fixtureEmail('busy');
  const liveEmail = fixtureEmail('live');
  await makeProspect(busyProspect, busyEmail);
  await makeProspect(liveProspect, liveEmail);
  await addTarget(busyRun, busyProspect, busyEmail);
  await addTarget(liveRun, liveProspect, liveEmail);
  await query('select public.allocate_email_verification_targets_v1($1,500)', [busyRun]);
  await query('select public.allocate_email_verification_targets_v1($1,500)', [liveRun]);
  const locker = await pool.connect();
  try {
    await locker.query('begin');
    await locker.query('select 1 from prospect_verification.runs where id=$1 for update', [busyRun]);
    const claimed = await query(`select public.claim_email_verification_check_v1($1,120,4) unit`, [`serviceability-${fixtureTag}`]);
    if (claimed.rows[0].unit?.email !== liveEmail) throw new Error('busy preferred run starved serviceable live demand');
    await locker.query('rollback');
  } finally { locker.release(); }

  process.stdout.write(`Multi-session verification iteration ${iteration} passed.\n`);
} catch (error) {
  if (error instanceof Error) error.message = `${stage}: ${error.message}`;
  throw error;
} finally {
  await pool.end();
}
