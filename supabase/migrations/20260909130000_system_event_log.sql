-- A durable home for the failures that today only ever reach console.warn/
-- console.error: refused requests (over_cap/overloaded/timed_out/server_error),
-- readiness check failures and background job errors. Those all vanish on
-- redeploy today because lib/observability.ts is deliberately per-process and
-- in-memory - fine as a live signal, useless as a history to diagnose "why did
-- this fail" after the fact. This table is that history. Only ever written and
-- read by the service-role client (see lib/server-log.ts and
-- app/api/admin/logs/route.ts); never touched with the anon/publishable key.
create table public.system_event_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  level text not null check (level in ('info','warn','error')),
  source text not null,
  route text,
  status_code integer,
  duration_ms integer,
  request_id text,
  message text not null,
  detail jsonb not null default '{}'::jsonb
);
create index idx_system_event_log_created_at on public.system_event_log(created_at desc);
create index idx_system_event_log_level on public.system_event_log(level, created_at desc);
create index idx_system_event_log_source on public.system_event_log(source, created_at desc);

alter table public.system_event_log enable row level security;
revoke all on public.system_event_log from public, anon, authenticated;
grant select, insert, delete on public.system_event_log to service_role;
grant usage, select on sequence public.system_event_log_id_seq to service_role;

-- Called opportunistically from lib/server-log.ts rather than on a pg_cron
-- schedule (nothing in this project runs pg_cron yet) - cheap enough to run on
-- a small fraction of inserts and keeps the table from growing unbounded.
create function public.purge_system_event_log_v1()
returns void language sql security definer set search_path = '' as $$
  delete from public.system_event_log where created_at < now() - interval '30 days';
$$;
revoke execute on function public.purge_system_event_log_v1() from public, anon, authenticated;
grant execute on function public.purge_system_event_log_v1() to service_role;
