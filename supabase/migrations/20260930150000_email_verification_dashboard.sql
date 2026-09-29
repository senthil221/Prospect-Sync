-- Everything the Email verification page shows, in one read.
--
-- Verification ran for days with nowhere to watch it: the runs API returns the
-- runs (and each run's full filter list - 549 email addresses for one run), but
-- not the queue, the result mix or the throughput. This reads them from the
-- verification tables only - never public.prospects (827k rows, 760ms to
-- group) - so the page can poll it:
--
--   provider    dispatch state, quota and worker heartbeat
--   queue       email checks by execution state
--   results     verified addresses by outcome, all time and last 24 hours
--   throughput  checks started per hour for 24 hours, and the last 10 / 60 min
--   runs        the latest runs with their counters, without filter payloads
--
-- Measured on production 2026-09-30: ~220ms in total. Read-only.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.email_verification_dashboard_v1(p_runs integer default 15)
returns jsonb
language sql
stable
security definer
set search_path = ''
set statement_timeout = '15s'
as $$
select jsonb_build_object(
  'provider', (
    select to_jsonb(p) - 'singleton' || jsonb_build_object(
      'worker_alive', p.worker_seen_at > now() - interval '2 minutes',
      'now', now())
      from prospect_verification.provider_control p where p.singleton),
  'queue', (
    select jsonb_object_agg(execution_state, n)
      from (select execution_state, count(*) as n from prospect_verification.email_checks group by 1) q),
  'results', coalesce((
    select jsonb_object_agg(result_status, n)
      from (select result_status, count(*) as n from prospect_verification.email_checks
             where execution_state = 'completed' group by 1) r), '{}'::jsonb),
  'results_24h', coalesce((
    select jsonb_object_agg(result_status, n)
      from (select c.result_status, count(*) as n
              from prospect_verification.dispatch_attempts d
              join prospect_verification.email_checks c on c.id = d.check_id
             where d.attempted_at > now() - interval '24 hours' and c.execution_state = 'completed'
             group by 1) r), '{}'::jsonb),
  'throughput', jsonb_build_object(
    'last_10m', (select count(*) from prospect_verification.dispatch_attempts where attempted_at > now() - interval '10 minutes'),
    'last_60m', (select count(*) from prospect_verification.dispatch_attempts where attempted_at > now() - interval '60 minutes'),
    'hourly', coalesce((
      select jsonb_agg(jsonb_build_object('hour', h.hour, 'checks', coalesce(a.n, 0)) order by h.hour)
        from generate_series(date_trunc('hour', now()) - interval '23 hours', date_trunc('hour', now()), interval '1 hour') as h(hour)
        left join (select date_trunc('hour', attempted_at) as hour, count(*) as n
                     from prospect_verification.dispatch_attempts
                    where attempted_at > date_trunc('hour', now()) - interval '23 hours'
                    group by 1) a on a.hour = h.hour), '[]'::jsonb)),
  'runs', coalesce((
    select jsonb_agg(r order by r.created_at desc)
      from (select id, source, scope, status, priority, force_reverify, max_emails, total_count, processed_count,
                   reused_count, skipped_count, error_count, cancelled_count, eligible_email_count, selected_email_count,
                   snapshot_complete, last_error, created_at, started_at, completed_at, updated_at,
                   case when jsonb_typeof(filters) = 'array' then jsonb_array_length(filters) else 0 end as filter_count
              from prospect_verification.runs
             order by created_at desc
             limit greatest(1, least(coalesce(p_runs, 15), 50))) r), '[]'::jsonb)
);
$$;

revoke execute on function public.email_verification_dashboard_v1(integer) from public, anon, authenticated;
grant execute on function public.email_verification_dashboard_v1(integer) to service_role;
