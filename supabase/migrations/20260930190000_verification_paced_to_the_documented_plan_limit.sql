-- Email verification paced to MailTester Ninja's documented plan limit.
--
-- The account is on the Ultimate plan. MailTester's API documentation
-- (https://mailtester.ninja/api/) states its limit as "23 emails every 10
-- seconds" - "200k per day / 1 per 430ms". That explains both earlier
-- settings, measured on production 2026-09-30:
--   18 per 10s, 500ms (launch)          ~100/min   no HTTP 429     under
--   25 per 10s, 400ms (20260930170000)   ~145/min   429 in minutes  over
-- This sets the pace just under the documented limit:
--   rolling guard   22 per 10s   (limit 23)
--   start spacing   450ms        (limit 430ms)
--   = ~132 a minute = ~190,000 a day, the daily_limit already set
-- MTN_CONCURRENCY goes to 12: at ~4.4s a check, 8 in flight cannot sustain
-- 132 a minute; the plan limits starts, not requests in flight, and the
-- spacing and rolling guard bound the starts. HTTP 429 still triggers the
-- provider cooldown. Only the two claim constants change.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.claim_email_verification_check_v1(
  p_worker_id text,p_lease_seconds integer default 120,p_max_attempts integer default 4
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_control prospect_verification.provider_control;
declare v_check prospect_verification.email_checks;
declare v_run prospect_verification.runs;
declare v_candidate record;
declare v_candidates jsonb;
declare v_token uuid:=gen_random_uuid();
declare v_daily integer;
declare v_rolling integer;
begin
  -- Pick without locks. After the singleton is locked, try-lock the supporting
  -- run and then the check, and revalidate all predicates before dispatch.
  select dispatch_sequence into v_daily from prospect_verification.provider_control where singleton;
  if mod(coalesce(v_daily,0),5)=0 then
    select coalesce(jsonb_agg(jsonb_build_object('runId',run_id,'checkId',check_id) order by created_at),'[]'::jsonb)
    into v_candidates from (
      select pick.run_id,c.id check_id,c.created_at
      from prospect_verification.email_checks c
      cross join lateral (
        select t.run_id from prospect_verification.run_targets t
        join prospect_verification.runs r on r.id=t.run_id
        where t.check_id=c.id and t.state='waiting' and r.status='running' and r.snapshot_complete
        limit 1) pick
      where c.execution_state in ('queued','running')
        and (c.execution_state='queued' or c.lease_expires_at<=now())
        and c.next_attempt_at<=now() and c.attempts<greatest(1,least(coalesce(p_max_attempts,4),20))
      order by c.created_at limit 20
    ) candidates;
  else
    select coalesce(jsonb_agg(jsonb_build_object('runId',run_id,'checkId',check_id) order by priority desc,created_at),'[]'::jsonb)
    into v_candidates from (
      select pick.run_id,c.id check_id,c.priority,c.created_at
      from prospect_verification.email_checks c
      cross join lateral (
        select t.run_id from prospect_verification.run_targets t
        join prospect_verification.runs r on r.id=t.run_id
        where t.check_id=c.id and t.state='waiting' and r.status='running' and r.snapshot_complete
        limit 1) pick
      where c.execution_state in ('queued','running')
        and (c.execution_state='queued' or c.lease_expires_at<=now())
        and c.next_attempt_at<=now() and c.attempts<greatest(1,least(coalesce(p_max_attempts,4),20))
      order by c.priority desc,c.created_at limit 20
    ) candidates;
  end if;
  if v_candidates='[]'::jsonb then return null; end if;
  select * into v_control from prospect_verification.provider_control where singleton for update;
  if not v_control.enabled or v_control.manually_paused or coalesce(v_control.cooldown_until,'-infinity')>now() or v_control.next_dispatch_at>now() then return null; end if;
  delete from prospect_verification.dispatch_attempts where id in (
    select id from prospect_verification.dispatch_attempts where attempted_at<now()-interval '48 hours' order by id limit 1000
  );
  select count(*)::int,count(*) filter(where attempted_at>now()-interval '10 seconds')::int
    into v_daily,v_rolling from prospect_verification.dispatch_attempts where attempted_at>now()-interval '24 hours';
  if v_daily>=v_control.daily_limit then
    update prospect_verification.provider_control set daily_attempts=v_daily,rolling_attempts=v_rolling,
      quota_wait_until=(select min(attempted_at)+interval '24 hours' from prospect_verification.dispatch_attempts where attempted_at>now()-interval '24 hours'),updated_at=now() where singleton;
    return null;
  end if;
  if v_rolling>=22 then
    update prospect_verification.provider_control set daily_attempts=v_daily,rolling_attempts=v_rolling,
      quota_wait_until=(select min(attempted_at)+interval '10 seconds' from prospect_verification.dispatch_attempts where attempted_at>now()-interval '10 seconds'),updated_at=now() where singleton;
    return null;
  end if;
  for v_candidate in select value from jsonb_array_elements(v_candidates)
  loop
    v_run:=null; v_check:=null;
    select * into v_run from prospect_verification.runs
      where id=(v_candidate.value->>'runId')::uuid and status='running' and snapshot_complete for update skip locked;
    if v_run.id is null then continue; end if;
    select * into v_check from prospect_verification.email_checks
      where id=(v_candidate.value->>'checkId')::uuid
        and (execution_state='queued' or (execution_state='running' and lease_expires_at<=now()))
        and next_attempt_at<=now() and attempts<greatest(1,least(coalesce(p_max_attempts,4),20))
      for update skip locked;
    if v_check.id is not null and exists(select 1 from prospect_verification.run_targets
      where run_id=v_run.id and check_id=v_check.id and state='waiting') then exit; end if;
    v_check:=null;
  end loop;
  if v_check.id is null then return null; end if;
  update prospect_verification.email_checks set execution_state='running',attempts=attempts+1,
    lease_token=v_token,lease_expires_at=now()+make_interval(secs=>greatest(30,least(coalesce(p_lease_seconds,120),600))),
    worker_id=left(p_worker_id,120),updated_at=now() where id=v_check.id returning * into v_check;
  insert into prospect_verification.dispatch_attempts(check_id) values(v_check.id);
  update prospect_verification.provider_control set next_dispatch_at=now()+interval '450 milliseconds',
    rolling_window_started_at=now()-interval '10 seconds',daily_window_started_at=now()-interval '24 hours',
    rolling_attempts=v_rolling+1,daily_attempts=v_daily+1,dispatch_sequence=dispatch_sequence+1,
    quota_wait_until=null,updated_at=now() where singleton;
  return jsonb_build_object('id',v_check.id,'email',v_check.normalized_email,'leaseToken',v_token,'attempt',v_check.attempts);
end $$;

revoke execute on function public.claim_email_verification_check_v1(text,integer,integer) from public,anon,authenticated;
do $$
begin
  if exists(select 1 from pg_roles where rolname='prospect_verifier') then
    execute 'grant execute on function public.claim_email_verification_check_v1(text,integer,integer) to prospect_verifier';
  end if;
end $$;
