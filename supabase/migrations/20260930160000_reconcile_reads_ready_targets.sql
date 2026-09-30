-- Reconciliation reads the targets that are ready, not every waiting target.
--
-- MEASURED on production 2026-09-30, with 667,806 targets waiting in the
-- all-prospects run and 13 of them ready: reconcile_email_verification_run_v1
-- found those 13 by walking all 667,817 waiting targets in prospect order and
-- probing each one's check - 2.77s and 2.9M buffer hits per call (mean 1.84s
-- over 8,995 calls) - and next_email_verification_reconciliation_run_v1 ran
-- the same kind of scan for 0.6s. The verification worker pays both on every
-- loop, between provider dispatches.
--
-- THE CHANGE. run_targets.reconcile_ready marks a waiting target whose check
-- has finished (completed or error), and a partial index holds only those:
--   * a check finishing flags its waiting targets (trigger on email_checks -
--     covers complete_, retry_ -> error and expire_ -> error alike);
--   * a target attached to an already-finished check is flagged as it is
--     attached (BEFORE trigger on run_targets - the allocator's reuse path).
-- The reconcile pick and the next-run probe read the flag; everything else in
-- both functions is byte-identical, including the check-state join, so a flag
-- can only narrow the old predicate, never widen it.
--
-- LOCK ORDER. The completion flags targets while holding its check row: CHECK
-- -> TARGET, the allocator's order. Reconciliation locks RUN -> TARGET ->
-- PROSPECT and never a check, so no cycle is possible.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

alter table prospect_verification.run_targets
  add column if not exists reconcile_ready boolean not null default false;

create index if not exists idx_verification_targets_ready
  on prospect_verification.run_targets (run_id, prospect_id)
  where state = 'waiting' and reconcile_ready;

create or replace function prospect_verification.flag_ready_targets_v1()
returns trigger language plpgsql set search_path = '' as $$
begin
  update prospect_verification.run_targets
     set reconcile_ready = true
   where check_id = new.id and state = 'waiting' and not reconcile_ready;
  return null;
end $$;

create or replace trigger flag_ready_targets
  after update of execution_state on prospect_verification.email_checks
  for each row
  when (new.execution_state in ('completed', 'error') and old.execution_state is distinct from new.execution_state)
  execute function prospect_verification.flag_ready_targets_v1();

create or replace function prospect_verification.flag_target_on_finished_check_v1()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.check_id is not null and new.state = 'waiting' then
    new.reconcile_ready := exists (
      select 1 from prospect_verification.email_checks c
       where c.id = new.check_id and c.execution_state in ('completed', 'error'));
  end if;
  return new;
end $$;

create or replace trigger flag_target_on_finished_check
  before insert or update of check_id on prospect_verification.run_targets
  for each row
  execute function prospect_verification.flag_target_on_finished_check_v1();

-- Targets already waiting on a finished check.
update prospect_verification.run_targets t
   set reconcile_ready = true
  from prospect_verification.email_checks c
 where c.id = t.check_id and t.state = 'waiting' and not t.reconcile_ready
   and c.execution_state in ('completed', 'error');

create or replace function public.next_email_verification_reconciliation_run_v1()
returns uuid language sql stable security definer set search_path = '' as $$
  select r.id from prospect_verification.runs r
  where r.snapshot_complete and r.status in ('running','paused','cancelled')
    -- Two probes, not one with an OR, so the live run uses the ready index.
    and ((r.status='cancelled' and exists(
           select 1 from prospect_verification.run_targets t where t.run_id=r.id and t.state='waiting'))
      or (r.status<>'cancelled' and exists(
           select 1 from prospect_verification.run_targets t where t.run_id=r.id and t.state='waiting' and t.reconcile_ready)))
  order by r.priority desc,r.created_at limit 1;
$$;

create or replace function public.reconcile_email_verification_run_v1(
  p_run_id uuid,p_limit integer default 500
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run prospect_verification.runs;
declare v_processed integer:=0;
declare v_reused integer:=0;
declare v_skipped integer:=0;
declare v_errors integer:=0;
declare v_cancelled integer:=0;
begin
  select * into v_run from prospect_verification.runs where id=p_run_id for update;
  if v_run.id is null then raise exception 'Verification run not found' using errcode='P0002'; end if;
  if not v_run.snapshot_complete then return jsonb_build_object('processed',0,'remaining',false); end if;

  drop table if exists pg_temp.verification_reconcile_batch;
  create temporary table verification_reconcile_batch(prospect_id text primary key) on commit drop;
  if v_run.status='cancelled' then
    insert into verification_reconcile_batch
    select prospect_id from prospect_verification.run_targets
    where run_id=p_run_id and state='waiting'
    order by prospect_id for update skip locked
    limit greatest(1,least(coalesce(p_limit,500),500));
  else
    insert into verification_reconcile_batch
    select t.prospect_id from prospect_verification.run_targets t
    join prospect_verification.email_checks c on c.id=t.check_id
    where t.run_id=p_run_id and t.state='waiting' and t.reconcile_ready and c.execution_state in ('completed','error')
    order by t.prospect_id for update of t skip locked
    limit greatest(1,least(coalesce(p_limit,500),500));
  end if;
  if not exists(select 1 from verification_reconcile_batch) then
    return jsonb_build_object('processed',0,'remaining',exists(
      select 1 from prospect_verification.run_targets where run_id=p_run_id and state='waiting'));
  end if;

  if v_run.status='cancelled' then
    with changed as (
      update prospect_verification.run_targets t set state='cancelled',completed_at=now()
      from verification_reconcile_batch b where t.run_id=p_run_id and t.prospect_id=b.prospect_id
        and t.state='waiting' returning 1
    ) select count(*)::int into v_cancelled from changed;
  else
    -- Lock every still-existing prospect in a stable order before applying any
    -- projection. Deletes touch only prospect -> deletion_epoch and never wait
    -- for a run/target/check lock.
    perform 1 from public.prospects p join verification_reconcile_batch b on b.prospect_id=p.id
      order by p.id for update of p;

    update public.prospects p set
      verification_checked_email=c.normalized_email,verification_status=c.result_status,
      verification_reason=c.result_reason,verification_provider=c.provider,
      verification_checked_at=c.checked_at,verification_generation=c.generation,
      verification_result_id=c.id
    from verification_reconcile_batch b
    join prospect_verification.run_targets t on t.run_id=p_run_id and t.prospect_id=b.prospect_id
    join prospect_verification.email_checks c on c.id=t.check_id
    left join prospect_verification.prospect_deletions pd on pd.prospect_id=t.prospect_id
    where p.id=t.prospect_id and t.state='waiting' and c.execution_state='completed'
      and p.work_email_revision=t.email_revision
      and prospect_verification.normalize_email(p.work_email)=t.normalized_email
      and coalesce(pd.deletion_epoch,0)=t.deletion_epoch
      and (not v_run.force_reverify or c.generation>t.generation_floor)
      and coalesce(p.verification_generation,0)<=c.generation;

    with changed as (
      update prospect_verification.run_targets t set
        state=case
          when p.id is null or p.work_email_revision<>t.email_revision
            or prospect_verification.normalize_email(p.work_email)<>t.normalized_email
            or coalesce(pd.deletion_epoch,0)<>t.deletion_epoch then 'skipped'
          when c.execution_state='error' then 'error'
          when c.execution_state='completed' and (not v_run.force_reverify or c.generation>t.generation_floor)
            then case when t.reuse_result then 'reused' else 'completed' end
          else 'error' end,
        completed_at=now()
      from verification_reconcile_batch b
      join prospect_verification.email_checks c on c.id=(select x.check_id from prospect_verification.run_targets x where x.run_id=p_run_id and x.prospect_id=b.prospect_id)
      left join public.prospects p on p.id=b.prospect_id
      left join prospect_verification.prospect_deletions pd on pd.prospect_id=b.prospect_id
      where t.run_id=p_run_id and t.prospect_id=b.prospect_id and t.state='waiting'
      returning t.state
    )
    select count(*)::int,
      count(*) filter(where state='reused')::int,
      count(*) filter(where state='skipped')::int,
      count(*) filter(where state='error')::int
    into v_processed,v_reused,v_skipped,v_errors from changed;
  end if;

  v_processed:=v_processed+v_cancelled;
  update prospect_verification.runs set
    processed_count=processed_count+v_processed,
    reused_count=reused_count+v_reused,
    skipped_count=skipped_count+v_skipped,
    error_count=error_count+v_errors,
    cancelled_count=cancelled_count+v_cancelled,
    status=case when status in ('paused','cancelled') then status
      when processed_count+v_processed>=total_count then case when error_count+v_errors>0 then 'completed_with_errors' else 'completed' end
      else status end,
    completed_at=case when status='cancelled' then coalesce(completed_at,now())
      when status<>'paused' and processed_count+v_processed>=total_count then now() else completed_at end,
    updated_at=now()
  where id=p_run_id returning * into v_run;
  return jsonb_build_object('processed',v_processed,'reused',v_reused,'skipped',v_skipped,
    'errors',v_errors,'cancelled',v_cancelled,'run',to_jsonb(v_run),
    'remaining',exists(select 1 from prospect_verification.run_targets where run_id=p_run_id and state='waiting'));
end $$;

revoke execute on function public.reconcile_email_verification_run_v1(uuid,integer) from public,anon,authenticated;
revoke execute on function public.next_email_verification_reconciliation_run_v1() from public,anon,authenticated;
do $$
begin
  if exists(select 1 from pg_roles where rolname='prospect_verifier') then
    execute 'grant execute on function public.reconcile_email_verification_run_v1(uuid,integer) to prospect_verifier';
    execute 'grant execute on function public.next_email_verification_reconciliation_run_v1() to prospect_verifier';
  end if;
end $$;
