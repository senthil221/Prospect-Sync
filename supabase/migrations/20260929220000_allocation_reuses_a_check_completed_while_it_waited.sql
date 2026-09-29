-- Allocation reuses an email check that completed while it waited.
--
-- CI's "completion during allocation" contract (scripts/check-email-verification-
-- concurrency.mjs) failed on 2026-09-29, iteration 2 of 3, and passed on
-- iteration 1: a real race, not test noise.
--
-- allocate_email_verification_targets_v1 looks for a completed check, then an
-- in-flight one. complete_email_verification_check_v1 settles a check holding
-- only the check row (it never takes the allocator's advisory email lock). When
-- the completion is mid-commit:
--   1. the completed lookup's snapshot still sees 'running' - no row;
--   2. the in-flight lookup matches 'running', FOR UPDATE waits on the
--      completion's row lock;
--   3. the completion commits; READ COMMITTED re-checks the row, now
--      'completed', against "queued or running" - skipped;
--   4. nothing found, so a NEW generation is queued: a second paid MailTester
--      call for an address verified milliseconds earlier, and the run cannot
--      finish on this reconciliation.
-- The fix: after an in-flight lookup comes back empty, look for a completed
-- check once more. That statement takes a fresh snapshot, after the wait, so
-- it sees the committed answer. Nothing else changes.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.allocate_email_verification_targets_v1(
  p_run_id uuid,p_limit integer default 500
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run prospect_verification.runs;
declare v_target record;
declare v_check prospect_verification.email_checks;
declare v_count integer:=0;
declare v_generation integer;
begin
  select * into v_run from prospect_verification.runs where id=p_run_id for update;
  if v_run.id is null then raise exception 'Verification run not found' using errcode='P0002'; end if;
  if not v_run.snapshot_complete or v_run.status<>'running' then
    return jsonb_build_object('allocated',0,'remaining',exists(select 1 from prospect_verification.run_targets where run_id=p_run_id and state='waiting' and check_id is null));
  end if;
  drop table if exists pg_temp.verification_allocate_batch;
  create temporary table verification_allocate_batch(
    prospect_id text primary key,normalized_email text not null,generation_floor integer not null
  ) on commit drop;
  insert into verification_allocate_batch
  select prospect_id,normalized_email,generation_floor
  from prospect_verification.run_targets
  where run_id=p_run_id and state='waiting' and check_id is null
  order by prospect_id limit greatest(1,least(coalesce(p_limit,500),500));
  -- Every overlapping run acquires the bounded batch's email locks in the same
  -- numeric order before touching checks, including hash-collision ties.
  perform pg_advisory_xact_lock(lock_key) from (
    select distinct hashtextextended(normalized_email,7194) lock_key
    from verification_allocate_batch order by lock_key
  ) ordered_locks;
  for v_target in
    select prospect_id,normalized_email,generation_floor from verification_allocate_batch order by prospect_id
  loop
    v_check:=null;
    if v_run.force_reverify then
      select * into v_check from prospect_verification.email_checks
      where normalized_email=v_target.normalized_email and execution_state='completed'
        and generation>v_target.generation_floor
      order by generation desc limit 1 for update;
    else
      select * into v_check from prospect_verification.email_checks
      where normalized_email=v_target.normalized_email and execution_state='completed'
      order by generation desc limit 1 for update;
    end if;
    if v_check.id is null then
      select * into v_check from prospect_verification.email_checks
      where normalized_email=v_target.normalized_email and execution_state in ('queued','running')
        and (not v_run.force_reverify or generation>v_target.generation_floor)
      order by generation desc limit 1 for update;
    end if;
    -- The in-flight lookup above can wait on a provider completion that holds
    -- the check row. When that commits, the row is re-checked, no longer
    -- queued or running, and skipped - so without this second look a fresh
    -- snapshot never sees the answer that just landed, and a duplicate check
    -- is queued for an email verified a moment ago.
    if v_check.id is null then
      if v_run.force_reverify then
        select * into v_check from prospect_verification.email_checks
        where normalized_email=v_target.normalized_email and execution_state='completed'
          and generation>v_target.generation_floor
        order by generation desc limit 1 for update;
      else
        select * into v_check from prospect_verification.email_checks
        where normalized_email=v_target.normalized_email and execution_state='completed'
        order by generation desc limit 1 for update;
      end if;
    end if;
    if v_check.id is null then
      select greatest(coalesce(max(generation),0),v_target.generation_floor)+1 into v_generation
      from prospect_verification.email_checks where normalized_email=v_target.normalized_email;
      insert into prospect_verification.email_checks(normalized_email,generation,priority)
      values(v_target.normalized_email,v_generation,v_run.priority) returning * into v_check;
    end if;
    update prospect_verification.email_checks set priority=greatest(priority,v_run.priority),updated_at=now()
      where id=v_check.id and execution_state in ('queued','running');
    update prospect_verification.run_targets set check_id=v_check.id,
      reuse_result=(v_check.execution_state='completed')
    where run_id=p_run_id and prospect_id=v_target.prospect_id and state='waiting' and check_id is null;
    if found then v_count:=v_count+1; end if;
  end loop;
  return jsonb_build_object('allocated',v_count,'remaining',exists(
    select 1 from prospect_verification.run_targets where run_id=p_run_id and state='waiting' and check_id is null));
end $$;

revoke execute on function public.allocate_email_verification_targets_v1(uuid,integer) from public,anon,authenticated;
grant execute on function public.allocate_email_verification_targets_v1(uuid,integer) to service_role;
do $$
begin
  if exists(select 1 from pg_roles where rolname='prospect_verifier') then
    execute 'grant execute on function public.allocate_email_verification_targets_v1(uuid,integer) to prospect_verifier';
  end if;
end $$;
