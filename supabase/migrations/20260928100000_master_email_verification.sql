-- Durable, provider-independent work-email verification.
-- The provider queue is private and is reachable only through the capability
-- functions granted at the end of this migration.  Provider calls never occur
-- in a transaction; claims use fenced leases and results are applied only when
-- the prospect still carries the snapshotted email revision.

create schema if not exists prospect_verification;
revoke all on schema prospect_verification from public, anon, authenticated;

alter table public.prospects
  add column if not exists work_email_revision bigint not null default 1,
  add column if not exists verification_checked_email text,
  add column if not exists verification_status text,
  add column if not exists verification_reason text,
  add column if not exists verification_provider text,
  add column if not exists verification_checked_at timestamptz,
  add column if not exists verification_generation integer,
  add column if not exists verification_result_id uuid;

alter table public.prospect_index
  add column if not exists work_email_revision bigint not null default 1,
  add column if not exists verification_checked_email text,
  add column if not exists verification_status text,
  add column if not exists verification_reason text,
  add column if not exists verification_provider text,
  add column if not exists verification_checked_at timestamptz,
  add column if not exists verification_generation integer,
  add column if not exists verification_result_id uuid;

alter table public.imports add column if not exists verify_work_emails boolean not null default false;

do $$ begin
  alter table public.prospects add constraint prospects_verification_status_check
    check (verification_status is null or verification_status in ('valid','invalid','catch_all','unverifiable'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.prospect_index add constraint prospect_index_verification_status_check
    check (verification_status is null or verification_status in ('valid','invalid','catch_all','unverifiable'));
exception when duplicate_object then null; end $$;

create index if not exists idx_prospect_index_verification_status
  on public.prospect_index (verification_status, id);
create index if not exists idx_prospect_index_verification_checked_at
  on public.prospect_index (verification_checked_at, id);

create table if not exists prospect_verification.runs (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  payload_hash text not null,
  actor_id uuid,
  source text not null default 'manual' check (source in ('manual','import')),
  source_import_id text unique,
  scope text not null check (scope in ('all','filtered','import')),
  search text not null default '',
  filters jsonb not null default '[]'::jsonb,
  company_scope jsonb not null default '{}'::jsonb,
  force_reverify boolean not null default false,
  status text not null default 'queued' check (status in ('queued','preparing','running','paused','completed','completed_with_errors','cancelled','failed')),
  priority smallint not null default 10,
  total_count integer not null default 0,
  processed_count integer not null default 0,
  reused_count integer not null default 0,
  skipped_count integer not null default 0,
  error_count integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists prospect_verification.email_checks (
  id uuid primary key default gen_random_uuid(),
  normalized_email text not null,
  generation integer not null,
  execution_state text not null default 'queued' check (execution_state in ('queued','running','completed','error')),
  result_status text check (result_status is null or result_status in ('valid','invalid','catch_all','unverifiable')),
  result_reason text,
  provider text,
  checked_at timestamptz,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_expires_at timestamptz,
  worker_id text,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (normalized_email, generation)
);

create table if not exists prospect_verification.run_targets (
  run_id uuid not null references prospect_verification.runs(id) on delete cascade,
  prospect_id text not null references public.prospects(id) on delete cascade,
  normalized_email text not null,
  email_revision bigint not null,
  check_id uuid references prospect_verification.email_checks(id),
  state text not null default 'waiting' check (state in ('waiting','reused','completed','skipped','error','cancelled')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (run_id, prospect_id)
);

create index if not exists idx_verification_targets_check
  on prospect_verification.run_targets(check_id, state);
create index if not exists idx_verification_targets_prospect
  on prospect_verification.run_targets(prospect_id);
create index if not exists idx_verification_checks_claim
  on prospect_verification.email_checks(execution_state, next_attempt_at, created_at);
create unique index if not exists uq_verification_active_email
  on prospect_verification.email_checks(normalized_email)
  where execution_state in ('queued','running');
create index if not exists idx_verification_runs_queue
  on prospect_verification.runs(status, priority, created_at);

create table if not exists prospect_verification.provider_control (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  manually_paused boolean not null default true,
  pause_reason text,
  cooldown_until timestamptz,
  quota_wait_until timestamptz,
  next_dispatch_at timestamptz not null default now(),
  rolling_window_started_at timestamptz not null default now(),
  rolling_attempts integer not null default 0,
  daily_window_started_at timestamptz not null default (date_trunc('day', now() at time zone 'UTC') at time zone 'UTC'),
  daily_attempts integer not null default 0,
  daily_limit integer not null default 150000 check (daily_limit between 1 and 200000),
  worker_configured boolean not null default false,
  worker_seen_at timestamptz,
  updated_at timestamptz not null default now()
);
insert into prospect_verification.provider_control(singleton) values (true) on conflict do nothing;

create table if not exists prospect_verification.dispatch_attempts (
  id bigint generated always as identity primary key,
  check_id uuid not null references prospect_verification.email_checks(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index if not exists idx_verification_dispatch_attempts_at
  on prospect_verification.dispatch_attempts(attempted_at);

alter table prospect_verification.runs enable row level security;
alter table prospect_verification.email_checks enable row level security;
alter table prospect_verification.run_targets enable row level security;
alter table prospect_verification.provider_control enable row level security;
alter table prospect_verification.dispatch_attempts enable row level security;
revoke all on all tables in schema prospect_verification from public, anon, authenticated;

create or replace function prospect_verification.normalize_email(p_email text)
returns text language sql immutable strict set search_path = '' as $$
  select lower(btrim(p_email));
$$;

create or replace function prospect_verification.invalidate_email_projection()
returns trigger language plpgsql security definer set search_path = '' as $$
declare old_email text := prospect_verification.normalize_email(coalesce(old.work_email, ''));
declare new_email text := prospect_verification.normalize_email(coalesce(new.work_email, ''));
begin
  if old_email is distinct from new_email then
    new.work_email_revision := old.work_email_revision + 1;
    new.verification_checked_email := null;
    new.verification_status := null;
    new.verification_reason := null;
    new.verification_provider := null;
    new.verification_checked_at := null;
    new.verification_generation := null;
    new.verification_result_id := null;
  end if;
  return new;
end $$;

drop trigger if exists prospect_work_email_revision on public.prospects;
create trigger prospect_work_email_revision before update of work_email on public.prospects
for each row execute function prospect_verification.invalidate_email_projection();

create or replace function prospect_verification.sync_index_projection()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.prospect_index set
    work_email_revision = new.work_email_revision,
    verification_checked_email = new.verification_checked_email,
    verification_status = new.verification_status,
    verification_reason = new.verification_reason,
    verification_provider = new.verification_provider,
    verification_checked_at = new.verification_checked_at,
    verification_generation = new.verification_generation,
    verification_result_id = new.verification_result_id
  where id = new.id;
  return null;
end $$;

drop trigger if exists prospect_verification_sync_index on public.prospects;
create trigger prospect_verification_sync_index
after insert or update of work_email, work_email_revision, verification_result_id on public.prospects
for each row execute function prospect_verification.sync_index_projection();

update public.prospect_index pi set
  work_email_revision = p.work_email_revision,
  verification_checked_email = p.verification_checked_email,
  verification_status = p.verification_status,
  verification_reason = p.verification_reason,
  verification_provider = p.verification_provider,
  verification_checked_at = p.verification_checked_at,
  verification_generation = p.verification_generation,
  verification_result_id = p.verification_result_id
from public.prospects p where p.id = pi.id
  and row(pi.work_email_revision,pi.verification_checked_email,pi.verification_status,
    pi.verification_reason,pi.verification_provider,pi.verification_checked_at,
    pi.verification_generation,pi.verification_result_id)
    is distinct from
    row(p.work_email_revision,p.verification_checked_email,p.verification_status,
      p.verification_reason,p.verification_provider,p.verification_checked_at,
      p.verification_generation,p.verification_result_id);

create or replace function prospect_verification.hydrate_index_projection()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  select p.work_email_revision,p.verification_checked_email,p.verification_status,
    p.verification_reason,p.verification_provider,p.verification_checked_at,
    p.verification_generation,p.verification_result_id
  into new.work_email_revision,new.verification_checked_email,new.verification_status,
    new.verification_reason,new.verification_provider,new.verification_checked_at,
    new.verification_generation,new.verification_result_id
  from public.prospects p where p.id=new.id;
  return new;
end $$;

drop trigger if exists prospect_verification_hydrate_index on public.prospect_index;
create trigger prospect_verification_hydrate_index before insert on public.prospect_index
for each row execute function prospect_verification.hydrate_index_projection();

create or replace function prospect_verification.account_deleted_prospect()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  with changed as (
    update prospect_verification.run_targets set state='skipped',completed_at=now()
    where prospect_id=old.id and state='waiting' returning run_id
  ), delta as (select run_id,count(*)::int skipped from changed group by run_id)
  update prospect_verification.runs r set processed_count=r.processed_count+d.skipped,
    skipped_count=r.skipped_count+d.skipped,
    status=case when r.status in ('queued','preparing','paused','cancelled') then r.status
      when r.processed_count+d.skipped>=r.total_count then case when r.error_count>0 then 'completed_with_errors' else 'completed' end else r.status end,
    completed_at=case when r.status='running' and r.processed_count+d.skipped>=r.total_count then now() else r.completed_at end,
    updated_at=now() from delta d where r.id=d.run_id;
  return old;
end $$;
drop trigger if exists prospect_verification_account_delete on public.prospects;
create trigger prospect_verification_account_delete before delete on public.prospects
for each row execute function prospect_verification.account_deleted_prospect();

create or replace function public.request_email_verification_v1(
  p_request_id uuid, p_payload jsonb, p_actor_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_hash text := pg_catalog.md5(coalesce(p_payload, '{}'::jsonb)::text);
declare v_run prospect_verification.runs;
declare v_scope text := coalesce(p_payload->>'scope', '');
begin
  if v_scope not in ('all','filtered') then raise exception 'Invalid verification scope' using errcode='22023'; end if;
  if jsonb_typeof(coalesce(p_payload->'filters', '[]'::jsonb)) <> 'array' then raise exception 'Filters must be an array' using errcode='22023'; end if;
  if length(coalesce(p_payload->>'search','')) > 500 then raise exception 'Search is too long' using errcode='22023'; end if;
  insert into prospect_verification.runs(request_id,payload_hash,actor_id,scope,search,filters,company_scope,force_reverify,priority)
  values(p_request_id,v_hash,p_actor_id,v_scope,
    case when v_scope='filtered' then coalesce(p_payload->>'search','') else '' end,
    case when v_scope='filtered' then coalesce(p_payload->'filters','[]'::jsonb) else '[]'::jsonb end,
    case when v_scope='filtered' then coalesce(p_payload->'companyScope','{}'::jsonb) else '{}'::jsonb end,
    coalesce((p_payload->>'forceReverify')::boolean,false),case when v_scope='filtered' then 30 else 5 end)
  on conflict(request_id) do nothing returning * into v_run;
  if v_run.id is null then
    select * into v_run from prospect_verification.runs where request_id=p_request_id;
    if v_run.payload_hash <> v_hash then raise exception 'Request ID was already used with a different payload' using errcode='23505'; end if;
  end if;
  return to_jsonb(v_run);
end $$;

create or replace function public.email_verification_runs_v1(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'runs', coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb),
    'provider', (select to_jsonb(pc) - 'singleton' from prospect_verification.provider_control pc where singleton)
  ) from (select * from prospect_verification.runs order by created_at desc limit greatest(1,least(coalesce(p_limit,20),100))) r;
$$;

create or replace function public.control_email_verification_run_v1(p_run_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run prospect_verification.runs;
begin
  if p_action='pause' then
    update prospect_verification.runs set status='paused',updated_at=now()
    where id=p_run_id and status in ('queued','preparing','running') returning * into v_run;
  elsif p_action='continue' then
    update prospect_verification.runs set
      status=case when total_count=0 then 'queued' when processed_count>=total_count then case when error_count>0 then 'completed_with_errors' else 'completed' end else 'running' end,
      completed_at=case when total_count>0 and processed_count>=total_count then coalesce(completed_at,now()) else completed_at end,updated_at=now()
    where id=p_run_id and status='paused' returning * into v_run;
  elsif p_action='cancel' then
    update prospect_verification.runs set status='cancelled',completed_at=now(),updated_at=now()
    where id=p_run_id and status in ('queued','preparing','running','paused') returning * into v_run;
    update prospect_verification.run_targets set state='cancelled',completed_at=now()
    where run_id=p_run_id and state='waiting';
  else raise exception 'Unsupported run action' using errcode='22023'; end if;
  if not found then select * into v_run from prospect_verification.runs where id=p_run_id; end if;
  if v_run.id is null then raise exception 'Verification run not found' using errcode='P0002'; end if;
  return to_jsonb(v_run);
end $$;

create or replace function public.control_email_verification_provider_v1(p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_control prospect_verification.provider_control;
begin
  if p_action='start' then
    update prospect_verification.provider_control set enabled=true,manually_paused=false,pause_reason=null,cooldown_until=null,updated_at=now() where singleton returning * into v_control;
  elsif p_action='pause' then
    update prospect_verification.provider_control set manually_paused=true,pause_reason=left(coalesce(p_reason,'Paused by administrator'),300),updated_at=now() where singleton returning * into v_control;
  elsif p_action='continue' then
    update prospect_verification.provider_control set manually_paused=false,pause_reason=null,cooldown_until=null,updated_at=now() where singleton returning * into v_control;
  elsif p_action='stop' then
    update prospect_verification.provider_control set enabled=false,manually_paused=true,pause_reason=left(coalesce(p_reason,'Stopped by administrator'),300),updated_at=now() where singleton returning * into v_control;
  else raise exception 'Unsupported provider action' using errcode='22023'; end if;
  return to_jsonb(v_control)-'singleton';
end $$;

create or replace function public.report_email_verification_worker_v1(p_configured boolean)
returns void language sql security definer set search_path = '' as $$
  update prospect_verification.provider_control set worker_configured=p_configured,worker_seen_at=now(),updated_at=now() where singleton;
$$;

-- Atomically freezes a bounded selection.  Any failure rolls back the status
-- change and every target, so dispatch can never observe a partial snapshot.
create or replace function public.prepare_email_verification_run_v1(p_run_id uuid, p_limit integer default 2000000)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run prospect_verification.runs;
declare v_prefilter text;
declare v_predicate text;
declare v_scope_cte text := '';
declare v_scope_join text := '';
declare v_has_scope boolean;
declare v_has_cap boolean;
declare v_inserted bigint;
begin
  select * into v_run from prospect_verification.runs where id=p_run_id for update;
  if v_run.id is null then raise exception 'Verification run not found' using errcode='P0002'; end if;
  if v_run.status not in ('queued','preparing') then return to_jsonb(v_run); end if;
  update prospect_verification.runs set status='preparing',started_at=coalesce(started_at,now()),updated_at=now() where id=p_run_id;
  begin
    if v_run.scope <> 'import' then
      v_has_cap := exists(select 1 from jsonb_array_elements(v_run.filters) f where f->>'field'='__max_people_per_company');
      if v_run.scope='all' then
        v_predicate:='true'; v_prefilter:='true';
      else
        v_prefilter:=public.prospect_prefilter_sql(v_run.search,v_run.filters);
        v_predicate:=coalesce(public.prospect_filter_sql_v1(v_run.search,v_run.filters),
          format('public.prospect_index_matches_v1(pi,%L,%L::jsonb)',v_run.search,v_run.filters::text));
      end if;
      v_has_scope:=v_run.scope='filtered' and v_run.company_scope<>'{}'::jsonb
        and (btrim(coalesce(v_run.company_scope->>'search',''))<>'' or coalesce(v_run.company_scope->'filters','[]'::jsonb)<>'[]'::jsonb);
      if v_has_cap then
        execute format($q$
          insert into prospect_verification.run_targets(run_id,prospect_id,normalized_email,email_revision)
          select %L::uuid,pi.id,prospect_verification.normalize_email(pi.work_email),pi.work_email_revision
          from public.prospect_capped_candidate_ids_v1(%L,%L::jsonb,null,%L::jsonb) candidate
          join public.prospect_index pi on pi.id=candidate.prospect_id
          where nullif(prospect_verification.normalize_email(pi.work_email),'') is not null
          on conflict do nothing$q$,p_run_id,v_run.search,v_run.filters::text,v_run.company_scope::text);
      else
        if v_has_scope then
          v_scope_cte:=format('with eligible_companies as materialized (select company_id from public.company_scope_ids_v2(null,%L::jsonb)) ',v_run.company_scope::text);
          v_scope_join:=' join eligible_companies eligible on eligible.company_id=pi.company_id ';
        end if;
        execute format($q$
          insert into prospect_verification.run_targets(run_id,prospect_id,normalized_email,email_revision)
          %s select %L::uuid,pi.id,prospect_verification.normalize_email(pi.work_email),pi.work_email_revision
          from public.prospect_index pi %s
          where nullif(prospect_verification.normalize_email(pi.work_email),'') is not null
            and (%s) and (%s) on conflict do nothing$q$,v_scope_cte,p_run_id,v_scope_join,v_prefilter,v_predicate);
      end if;
    end if;
    select count(*) into v_inserted from prospect_verification.run_targets where run_id=p_run_id;
    if v_inserted>greatest(1,coalesce(p_limit,2000000)) then
      raise exception 'Verification selection has % people; configured preparation limit is %',v_inserted,p_limit using errcode='54000';
    end if;
  exception when query_canceled then
    update prospect_verification.runs set status='failed',last_error='Verification preparation timed out.',completed_at=now(),updated_at=now() where id=p_run_id returning * into v_run;
    return to_jsonb(v_run);
  when others then
    update prospect_verification.runs set status='failed',last_error=left(sqlerrm,500),completed_at=now(),updated_at=now() where id=p_run_id returning * into v_run;
    return to_jsonb(v_run);
  end;

  drop table if exists pg_temp.verification_check_map;
  create temporary table verification_check_map(
    normalized_email text primary key,base_generation integer not null default 0,
    check_id uuid,state text not null default 'waiting'
  ) on commit drop;
  insert into verification_check_map(normalized_email,base_generation)
    select t.normalized_email,coalesce(max(c.generation),0)
    from (select distinct normalized_email from prospect_verification.run_targets where run_id=p_run_id)t
    left join prospect_verification.email_checks c on c.normalized_email=t.normalized_email group by t.normalized_email;

  perform 1 from prospect_verification.email_checks c
  where c.normalized_email in(select normalized_email from verification_check_map)
    and c.execution_state in ('queued','running') for update;

  update verification_check_map m set check_id=(select c.id from prospect_verification.email_checks c
    where c.normalized_email=m.normalized_email and c.execution_state in ('queued','running') order by c.generation desc limit 1);
  if not v_run.force_reverify then
    update verification_check_map m set check_id=(select c.id from prospect_verification.email_checks c
      where c.normalized_email=m.normalized_email and c.execution_state='completed' order by c.generation desc limit 1),state='reused'
    where m.check_id is null and exists(select 1 from prospect_verification.email_checks c
      where c.normalized_email=m.normalized_email and c.execution_state='completed');
  end if;

  insert into prospect_verification.email_checks(normalized_email,generation)
  select m.normalized_email,m.base_generation+1
  from verification_check_map m where m.check_id is null
  on conflict do nothing;
  perform 1 from prospect_verification.email_checks c join verification_check_map m on m.normalized_email=c.normalized_email
    where m.check_id is null and c.generation>m.base_generation for update;
  update verification_check_map m set
    check_id=(select c.id from prospect_verification.email_checks c
      where c.normalized_email=m.normalized_email and c.generation>m.base_generation order by c.generation desc limit 1),
    state=case when exists(select 1 from prospect_verification.email_checks c
      where c.normalized_email=m.normalized_email and c.generation>m.base_generation and c.execution_state='completed') then 'reused' else 'waiting' end
  where m.check_id is null;
  if exists(select 1 from verification_check_map where check_id is null) then
    update prospect_verification.runs set status='failed',last_error='Could not allocate every shared verification check.',completed_at=now(),updated_at=now() where id=p_run_id returning * into v_run;
    return to_jsonb(v_run);
  end if;

  update prospect_verification.run_targets t set check_id=m.check_id,state=m.state,
    completed_at=case when m.state='reused' then now() end
  from verification_check_map m where t.run_id=p_run_id and t.normalized_email=m.normalized_email;
  update public.prospects p set
    verification_checked_email=c.normalized_email,verification_status=c.result_status,
    verification_reason=c.result_reason,verification_provider=c.provider,
    verification_checked_at=c.checked_at,verification_generation=c.generation,verification_result_id=c.id
  from prospect_verification.run_targets t join prospect_verification.email_checks c on c.id=t.check_id
  where t.run_id=p_run_id and t.state='reused' and p.id=t.prospect_id
    and p.work_email_revision=t.email_revision and prospect_verification.normalize_email(p.work_email)=t.normalized_email
    and coalesce(p.verification_generation,0)<=c.generation;
  update prospect_verification.runs r set
    total_count=(select count(*) from prospect_verification.run_targets t where t.run_id=r.id),
    reused_count=(select count(*) from prospect_verification.run_targets t where t.run_id=r.id and t.state='reused'),
    processed_count=(select count(*) from prospect_verification.run_targets t where t.run_id=r.id and t.state in ('reused','completed','skipped','error')),
    status=case when not exists(select 1 from prospect_verification.run_targets t where t.run_id=r.id and t.state='waiting') then 'completed' else 'running' end,
    completed_at=case when not exists(select 1 from prospect_verification.run_targets t where t.run_id=r.id and t.state='waiting') then now() end,
    updated_at=now() where id=p_run_id returning * into v_run;
  return to_jsonb(v_run);
end $$;

create or replace function public.prepare_next_email_verification_run_v1()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  select id into v_id from prospect_verification.runs where status='queued'
    or (status='preparing' and updated_at<now()-interval '5 minutes')
  order by priority desc,created_at for update skip locked limit 1;
  if v_id is null then return null; end if;
  return public.prepare_email_verification_run_v1(v_id,2000000);
end $$;

create or replace function public.claim_email_verification_check_v1(
  p_worker_id text,p_lease_seconds integer default 120,p_max_attempts integer default 4
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_control prospect_verification.provider_control;
declare v_check prospect_verification.email_checks;
declare v_token uuid:=gen_random_uuid();
declare v_daily integer;
declare v_rolling integer;
begin
  select * into v_control from prospect_verification.provider_control where singleton for update;
  if not v_control.enabled or v_control.manually_paused or coalesce(v_control.cooldown_until,'-infinity')>now() or v_control.next_dispatch_at>now() then return null; end if;
  -- A provider response normally decides terminality. A worker that repeatedly
  -- dies after claiming never reaches that response path, so expired leases
  -- also consume the bounded attempt budget and eventually settle their runs.
  with exhausted as (
    update prospect_verification.email_checks set execution_state='error',lease_token=null,
      lease_expires_at=null,worker_id=null,last_error_code='lease_exhausted',updated_at=now()
    where execution_state='running' and lease_expires_at<=now()
      and attempts>=greatest(1,least(coalesce(p_max_attempts,4),20))
    returning id
  ), changed as (
    update prospect_verification.run_targets t set state='error',completed_at=now()
    where t.state='waiting' and t.check_id in(select id from exhausted)
    returning t.run_id
  ), delta as (select run_id,count(*)::int errors from changed group by run_id)
  update prospect_verification.runs r set processed_count=r.processed_count+d.errors,
    error_count=r.error_count+d.errors,
    status=case when r.status in ('paused','cancelled') then r.status
      when r.processed_count+d.errors>=r.total_count then 'completed_with_errors' else r.status end,
    completed_at=case when r.status not in ('paused','cancelled')
      and r.processed_count+d.errors>=r.total_count then now() else r.completed_at end,
    updated_at=now() from delta d where r.id=d.run_id;
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
  if v_rolling>=18 then
    update prospect_verification.provider_control set daily_attempts=v_daily,rolling_attempts=v_rolling,
      quota_wait_until=(select min(attempted_at)+interval '10 seconds' from prospect_verification.dispatch_attempts where attempted_at>now()-interval '10 seconds'),updated_at=now() where singleton;
    return null;
  end if;
  select c.* into v_check from prospect_verification.email_checks c
  where (c.execution_state='queued' or (c.execution_state='running' and c.lease_expires_at<=now()))
    and c.next_attempt_at<=now()
    and exists(select 1 from prospect_verification.run_targets t join prospect_verification.runs r on r.id=t.run_id
      where t.check_id=c.id and t.state='waiting' and r.status='running')
  -- Four dispatches favour interactive/import work; every fifth takes the
  -- oldest runnable check so a long Master backfill can never starve.
  order by
    case when mod(v_daily,5)=0 then c.created_at end,
    case when mod(v_daily,5)<>0 then (
      select max(r.priority) from prospect_verification.run_targets t
      join prospect_verification.runs r on r.id=t.run_id
      where t.check_id=c.id and t.state='waiting' and r.status='running'
    ) end desc,
    c.created_at
  for update skip locked limit 1;
  if v_check.id is null then return null; end if;
  update prospect_verification.email_checks set execution_state='running',attempts=attempts+1,
    lease_token=v_token,lease_expires_at=now()+make_interval(secs=>greatest(30,least(coalesce(p_lease_seconds,120),600))),
    worker_id=left(p_worker_id,120),updated_at=now() where id=v_check.id returning * into v_check;
  insert into prospect_verification.dispatch_attempts(check_id) values(v_check.id);
  update prospect_verification.provider_control set next_dispatch_at=now()+interval '500 milliseconds',
    rolling_window_started_at=now()-interval '10 seconds',daily_window_started_at=now()-interval '24 hours',
    rolling_attempts=v_rolling+1,daily_attempts=v_daily+1,quota_wait_until=null,updated_at=now() where singleton;
  return jsonb_build_object('id',v_check.id,'email',v_check.normalized_email,'leaseToken',v_token,'attempt',v_check.attempts);
end $$;

create or replace function public.complete_email_verification_check_v1(
  p_check_id uuid,p_lease_token uuid,p_status text,p_reason text,p_provider text,p_checked_at timestamptz
) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_check prospect_verification.email_checks;
begin
  if p_status not in ('valid','invalid','catch_all','unverifiable') then raise exception 'Invalid result status' using errcode='22023'; end if;
  update prospect_verification.email_checks set execution_state='completed',result_status=p_status,
    result_reason=left(coalesce(p_reason,''),300),provider=left(coalesce(p_provider,''),80),checked_at=coalesce(p_checked_at,now()),
    lease_token=null,lease_expires_at=null,worker_id=null,updated_at=now()
  where id=p_check_id and execution_state='running' and lease_token=p_lease_token and lease_expires_at>now() returning * into v_check;
  if v_check.id is null then return false; end if;
  update public.prospects p set verification_checked_email=v_check.normalized_email,
    verification_status=v_check.result_status,verification_reason=v_check.result_reason,
    verification_provider=v_check.provider,verification_checked_at=v_check.checked_at,
    verification_generation=v_check.generation,verification_result_id=v_check.id
  from prospect_verification.run_targets t where t.check_id=v_check.id and t.prospect_id=p.id
    and t.email_revision=p.work_email_revision and t.normalized_email=prospect_verification.normalize_email(p.work_email)
    and coalesce(p.verification_generation,0)<=v_check.generation;
  with changed as (
    update prospect_verification.run_targets t set state=case when exists(
      select 1 from public.prospects p where p.id=t.prospect_id and p.work_email_revision=t.email_revision
        and prospect_verification.normalize_email(p.work_email)=t.normalized_email) then 'completed' else 'skipped' end,
      completed_at=now() where t.check_id=v_check.id and t.state='waiting' returning t.run_id,t.state
  ), delta as (
    select run_id,count(*)::int processed,count(*) filter(where state='skipped')::int skipped from changed group by run_id
  )
  update prospect_verification.runs r set processed_count=r.processed_count+d.processed,
    skipped_count=r.skipped_count+d.skipped,
    status=case when r.status in ('paused','cancelled') then r.status
      when r.processed_count+d.processed>=r.total_count then case when r.error_count>0 then 'completed_with_errors' else 'completed' end else r.status end,
    completed_at=case when r.status not in ('paused','cancelled') and r.processed_count+d.processed>=r.total_count then now() else r.completed_at end,
    updated_at=now() from delta d where r.id=d.run_id;
  return true;
end $$;

create or replace function public.retry_email_verification_check_v1(
  p_check_id uuid,p_lease_token uuid,p_error_code text,p_delay_seconds integer,p_terminal boolean default false,
  p_provider_pause_seconds integer default null,p_pause_reason text default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_changed integer;
begin
  update prospect_verification.email_checks set execution_state=case when p_terminal then 'error' else 'queued' end,
    next_attempt_at=now()+make_interval(secs=>greatest(1,least(coalesce(p_delay_seconds,1),86400))),
    lease_token=null,lease_expires_at=null,worker_id=null,last_error_code=left(coalesce(p_error_code,'unknown'),80),updated_at=now()
  where id=p_check_id and execution_state='running' and lease_token=p_lease_token;
  get diagnostics v_changed=row_count;
  if v_changed=0 then return false; end if;
  if p_terminal then
    with changed as (
      update prospect_verification.run_targets set state='error',completed_at=now()
      where check_id=p_check_id and state='waiting' returning run_id
    ), delta as (select run_id,count(*)::int errors from changed group by run_id)
    update prospect_verification.runs r set processed_count=r.processed_count+d.errors,error_count=r.error_count+d.errors,
      status=case when r.status in ('paused','cancelled') then r.status
        when r.processed_count+d.errors>=r.total_count then 'completed_with_errors' else r.status end,
      completed_at=case when r.status not in ('paused','cancelled') and r.processed_count+d.errors>=r.total_count then now() else r.completed_at end,
      updated_at=now() from delta d where r.id=d.run_id;
  end if;
  if p_provider_pause_seconds is not null then
    update prospect_verification.provider_control set
      manually_paused=case when p_error_code in ('auth','account') then true else manually_paused end,
      cooldown_until=greatest(coalesce(cooldown_until,'-infinity'),now()+make_interval(secs=>greatest(1,least(p_provider_pause_seconds,86400)))),
      pause_reason=left(coalesce(p_pause_reason,p_error_code),300),updated_at=now() where singleton;
  end if;
  return true;
end $$;

create or replace function public.complete_prospect_import_v2(p_import_id text,p_list_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_import public.imports;
declare v_run_id uuid;
begin
  select * into v_import from public.imports where id=p_import_id and list_id=p_list_id for update;
  if v_import.id is null then raise exception 'Import not found' using errcode='P0002'; end if;
  if v_import.status='completed' then
    select id into v_run_id from prospect_verification.runs where source_import_id=p_import_id;
    return jsonb_build_object('summary',to_jsonb(v_import),'verificationRunId',v_run_id);
  end if;
  if v_import.status<>'processing' then raise exception 'Import is not processing' using errcode='40001'; end if;
  if v_import.total_rows is not null and v_import.processed_rows<>v_import.total_rows then raise exception 'Import has not committed every row' using errcode='40001'; end if;
  update public.imports set status='completed',completed_at=now(),worker_id=null,lease_expires_at=null,last_error=null where id=p_import_id returning * into v_import;
  update public.lists set uploaded_rows=v_import.processed_rows,unique_added=v_import.unique_added,duplicates_linked=v_import.duplicates_linked where id=p_list_id;
  -- Memberships are canonical and include duplicate-linked people; this makes
  -- the originating import durable even when an older batch path rewrote it.
  if v_import.verify_work_emails then
    insert into prospect_verification.runs(request_id,payload_hash,source,source_import_id,scope,priority,status)
    values(gen_random_uuid(),pg_catalog.md5(jsonb_build_object('importId',p_import_id)::text),'import',p_import_id,'import',20,'queued')
    on conflict(source_import_id) do update set source_import_id=excluded.source_import_id returning id into v_run_id;
    insert into prospect_verification.run_targets(run_id,prospect_id,normalized_email,email_revision)
    select v_run_id,p.id,prospect_verification.normalize_email(p.work_email),p.work_email_revision
    from public.list_memberships lm join public.prospects p on p.id=lm.prospect_id
    where lm.list_id=p_list_id and lm.import_id=p_import_id
      and nullif(prospect_verification.normalize_email(p.work_email),'') is not null on conflict do nothing;
    update prospect_verification.runs set
      total_count=(select count(*) from prospect_verification.run_targets where run_id=v_run_id),
      updated_at=now()
    where id=v_run_id;
  end if;
  return jsonb_build_object('summary',jsonb_build_object(
    'processed_rows',v_import.processed_rows,
    'unique_added',v_import.unique_added,
    'duplicates_linked',v_import.duplicates_linked,
    'total_rows',v_import.total_rows,
    'status',v_import.status
  ),'verificationRunId',v_run_id);
end $$;

-- Patch the two authoritative filter implementations together.  Verification
-- status is a text field; checked-at uses explicit UTC range operators encoded
-- as never/before/on/after/between by the UI/API parser.
do $patch_verification_filters$
declare v_def text; v_anchor text; v_new text; v_hits integer;
begin
  v_def:=pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  if v_def not like '%__work_email_status%' then
    v_anchor:='      when ''__email_provider_type'' then ''pi.email_provider_type''';
    v_hits:=(length(v_def)-length(replace(v_def,v_anchor,'')))/length(v_anchor);
    if v_hits<>1 then raise exception 'prospect_filter_sql_v1 verification field anchor appears % times',v_hits; end if;
    v_new:=v_anchor||E'\n      when ''__work_email_status'' then $$case when nullif(btrim(pi.work_email), '''') is null then ''no_work_email'' else coalesce(pi.verification_status, ''not_checked'') end$$\n      when ''__work_email_verified_at'' then ''pi.verification_checked_at::text''';
    v_def:=replace(v_def,v_anchor,v_new);
    v_anchor:='    lowered := array(select lower(value) from unnest(raw_values) value);';
    v_hits:=(length(v_def)-length(replace(v_def,v_anchor,'')))/length(v_anchor);
    if v_hits<>1 then raise exception 'prospect_filter_sql_v1 date branch anchor appears % times',v_hits; end if;
    v_new:=v_anchor||E'\n\n    if field_key = ''__work_email_verified_at'' then\n      if operator_key = ''never'' then conjuncts := array_append(conjuncts,''pi.verification_checked_at is null''); continue; end if;\n      if cardinality(raw_values) < 1 then conjuncts := array_append(conjuncts,''false''); continue; end if;\n      if operator_key = ''before'' then conjuncts := array_append(conjuncts,format(''pi.verification_checked_at < %L::timestamptz'',raw_values[1])); continue; end if;\n      if operator_key = ''after'' then conjuncts := array_append(conjuncts,format(''pi.verification_checked_at >= %L::timestamptz'',raw_values[1])); continue; end if;\n      if operator_key in (''on'',''between'') and cardinality(raw_values)=2 then conjuncts := array_append(conjuncts,format(''(pi.verification_checked_at >= %L::timestamptz and pi.verification_checked_at < %L::timestamptz)'',raw_values[1],raw_values[2])); continue; end if;\n      conjuncts := array_append(conjuncts,''false''); continue;\n    end if;';
    execute replace(v_def,v_anchor,v_new);
  end if;
  v_def:=pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  if v_def not like '%__work_email_status%' then
    v_anchor:='        when ''__email_provider_type'' then (p_row).email_provider_type';
    v_hits:=(length(v_def)-length(replace(v_def,v_anchor,'')))/length(v_anchor);
    if v_hits<>1 then raise exception 'prospect_index_matches_v1 verification field anchor appears % times',v_hits; end if;
    v_new:=v_anchor||E'\n          when ''__work_email_status'' then case when nullif(btrim((p_row).work_email), '''') is null then ''no_work_email'' else coalesce((p_row).verification_status, ''not_checked'') end\n          when ''__work_email_verified_at'' then (p_row).verification_checked_at::text';
    v_def:=replace(v_def,v_anchor,v_new);
    v_anchor:='    where not case';
    v_hits:=(length(v_def)-length(replace(v_def,v_anchor,'')))/length(v_anchor);
    if v_hits<>1 then raise exception 'prospect_index_matches_v1 date operator anchor appears % times',v_hits; end if;
    v_new:=E'    where not case\n      when filter_item->>''field'' = ''__work_email_verified_at'' then\n      coalesce(case coalesce(filter_item->>''operator'',''never'')\n        when ''never'' then (p_row).verification_checked_at is null\n        when ''before'' then (p_row).verification_checked_at < (filter_item->''values''->>0)::timestamptz\n        when ''after'' then (p_row).verification_checked_at >= (filter_item->''values''->>0)::timestamptz\n        when ''on'' then (p_row).verification_checked_at >= (filter_item->''values''->>0)::timestamptz and (p_row).verification_checked_at < (filter_item->''values''->>1)::timestamptz\n        when ''between'' then (p_row).verification_checked_at >= (filter_item->''values''->>0)::timestamptz and (p_row).verification_checked_at < (filter_item->''values''->>1)::timestamptz\n        else false end,false)';
    v_def:=replace(v_def,v_anchor,v_new);
    execute v_def;
  end if;
end $patch_verification_filters$;

-- New functions are private-by-default even though their API wrappers live in
-- public for PostgREST.  The worker receives only the queue capabilities.
revoke execute on function prospect_verification.normalize_email(text) from public,anon,authenticated;
revoke execute on function prospect_verification.invalidate_email_projection() from public,anon,authenticated;
revoke execute on function prospect_verification.sync_index_projection() from public,anon,authenticated;
revoke execute on function prospect_verification.hydrate_index_projection() from public,anon,authenticated;
revoke execute on function prospect_verification.account_deleted_prospect() from public,anon,authenticated;
revoke execute on function public.request_email_verification_v1(uuid,jsonb,uuid) from public,anon,authenticated;
revoke execute on function public.email_verification_runs_v1(integer) from public,anon,authenticated;
revoke execute on function public.control_email_verification_run_v1(uuid,text) from public,anon,authenticated;
revoke execute on function public.control_email_verification_provider_v1(text,text) from public,anon,authenticated;
revoke execute on function public.report_email_verification_worker_v1(boolean) from public,anon,authenticated;
revoke execute on function public.prepare_email_verification_run_v1(uuid,integer) from public,anon,authenticated;
revoke execute on function public.prepare_next_email_verification_run_v1() from public,anon,authenticated;
revoke execute on function public.claim_email_verification_check_v1(text,integer,integer) from public,anon,authenticated;
revoke execute on function public.complete_email_verification_check_v1(uuid,uuid,text,text,text,timestamptz) from public,anon,authenticated;
revoke execute on function public.retry_email_verification_check_v1(uuid,uuid,text,integer,boolean,integer,text) from public,anon,authenticated;
revoke execute on function public.complete_prospect_import_v2(text,text) from public,anon,authenticated;

grant execute on function public.request_email_verification_v1(uuid,jsonb,uuid) to service_role;
grant execute on function public.email_verification_runs_v1(integer) to service_role;
grant execute on function public.control_email_verification_run_v1(uuid,text) to service_role;
grant execute on function public.control_email_verification_provider_v1(text,text) to service_role;
grant execute on function public.complete_prospect_import_v2(text,text) to service_role;

do $$ begin
  if exists(select 1 from pg_roles where rolname='prospect_verifier') then
    execute 'grant usage on schema public to prospect_verifier';
    execute 'grant execute on function public.prepare_next_email_verification_run_v1() to prospect_verifier';
    execute 'grant execute on function public.report_email_verification_worker_v1(boolean) to prospect_verifier';
    execute 'grant execute on function public.claim_email_verification_check_v1(text,integer,integer) to prospect_verifier';
    execute 'grant execute on function public.complete_email_verification_check_v1(uuid,uuid,text,text,text,timestamptz) to prospect_verifier';
    execute 'grant execute on function public.retry_email_verification_check_v1(uuid,uuid,text,integer,boolean,integer,text) to prospect_verifier';
  end if;
end $$;

comment on schema prospect_verification is 'Private durable queue for MailTester Ninja; never exposed through the Data API.';
comment on column public.prospects.verification_status is 'Label-only work-email result. It does not change lead/client/export eligibility.';
