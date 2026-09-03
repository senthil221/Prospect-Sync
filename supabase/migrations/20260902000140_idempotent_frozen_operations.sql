-- Bulk operations that a retry cannot double-apply, over a selection that
-- cannot silently grow.
--
-- Sections 9.2 and 9.3. Two separate problems, both real today:
--
-- 1. A bulk action is a POST. If the response is lost - a dropped connection, a
--    reload, an impatient second click - the client has no way to tell "it did
--    not happen" from "it happened and I did not hear". Retrying pushes 40,000
--    prospects into a client twice.
--
-- 2. "Select all matching, then push" resolves its ids at execution time. The
--    set that gets mutated is whatever matches when the mutation runs, not what
--    the user was looking at when they chose. An import landing in between
--    silently widens the action.
--
-- IDEMPOTENCY IS KEYED ON THE REQUEST, NOT THE CONTENT. Section 9.2 is explicit:
-- "unique per actor/action/request UUID ... Never deduplicate solely by content
-- hash." Two identical pushes a week apart are two legitimate operations; the
-- same request arriving twice is one. Only a client-generated request id can
-- tell those apart, so the unique index is (actor, action, request_id) and the
-- content hash is an audit field beside it rather than the key.
--
-- FREEZING REUSES RESULT SETS RATHER THAN REBUILDING THEM. Section 9.3 allows
-- "resolve IDs into operation_job_items (or reuse an authorized result set)".
-- 20260902000120 already builds, owns and freezes id lists with a version
-- vector, so a job freezes from one of those or from an explicit id list, and
-- there is exactly one piece of code that turns a question into a list of ids.
--
-- THE JOB NEVER SILENTLY EXPANDS. Items are written once, at freeze time, with
-- the version vector recorded. Nothing re-resolves them later; if the world
-- moved, status_v1 says so and the UI offers an explicit re-resolve, which is
-- what section 9.3 asks for.
--
-- BATCHES ARE RETRY-SAFE INDIVIDUALLY. Each item carries applied_at, so a batch
-- that fails halfway is resumed rather than repeated: next_batch_v1 only ever
-- returns items that have not been applied. That is what makes a worker crash
-- mid-operation safe, as opposed to merely unlikely.

begin;

create schema if not exists prospect_operations;
revoke all on schema prospect_operations from public, anon, authenticated;

create table if not exists prospect_operations.operation_jobs (
  id uuid primary key default gen_random_uuid(),
  -- The section 9.2 identity.
  actor text not null,
  action text not null,
  request_id uuid not null,
  entity_type text not null check (entity_type in ('prospect', 'company')),
  client_scope text not null default '',
  -- Audit fields kept beside it, never used as the key.
  content_hash text not null,
  authorization_scope text not null default 'global:1',
  version_vector jsonb not null,
  payload jsonb not null default '{}'::jsonb,
  excluded_ids text[] not null default array[]::text[],
  status text not null default 'pending'
    check (status in ('pending', 'frozen', 'running', 'completed', 'failed')),
  total_items bigint not null default 0,
  applied_items bigint not null default 0,
  excluded_count bigint not null default 0,
  -- What the operation answered. A retry returns this rather than running
  -- again, which is the difference between an idempotency key and a lock.
  result jsonb,
  error text,
  worker_id text,
  lease_expires_at timestamptz,
  created_at timestamptz not null default now(),
  frozen_at timestamptz,
  completed_at timestamptz,
  expires_at timestamptz not null
);
revoke all on prospect_operations.operation_jobs from public, anon, authenticated;

-- The whole point. A second arrival of the same request is the same job.
create unique index if not exists uq_operation_jobs_request
  on prospect_operations.operation_jobs (actor, action, request_id);
create index if not exists idx_operation_jobs_claimable
  on prospect_operations.operation_jobs (created_at) where status in ('frozen', 'running');
create index if not exists idx_operation_jobs_expires_at
  on prospect_operations.operation_jobs (expires_at);

create table if not exists prospect_operations.operation_job_items (
  job_id uuid not null references prospect_operations.operation_jobs(id) on delete cascade,
  ordinal bigint not null,
  entity_id text not null,
  -- Set when this id has actually been mutated. A resumed batch skips these,
  -- which is what makes a crash mid-operation safe rather than lucky.
  applied_at timestamptz,
  primary key (job_id, entity_id)
);
revoke all on prospect_operations.operation_job_items from public, anon, authenticated;
create unique index if not exists uq_operation_job_items_ordinal
  on prospect_operations.operation_job_items (job_id, ordinal);
create index if not exists idx_operation_job_items_pending
  on prospect_operations.operation_job_items (job_id, ordinal) where applied_at is null;

-- Enqueue, or hand back the job this request already created.
create or replace function prospect_operations.enqueue_v1(
  p_actor text,
  p_request_id uuid,
  p_action text,
  p_entity_type text,
  p_client_scope text,
  p_content_hash text,
  p_version_vector jsonb,
  p_payload jsonb default '{}'::jsonb,
  p_excluded_ids text[] default array[]::text[],
  p_ttl interval default interval '7 days'
)
returns table(job_id uuid, status text, total_items bigint, applied_items bigint, result jsonb, reused boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '15s'
as $function$
declare
  v_row prospect_operations.operation_jobs%rowtype;
begin
  if coalesce(btrim(p_actor), '') = '' then
    raise exception 'An operation needs an actor' using errcode = '22023';
  end if;
  if p_request_id is null then
    raise exception 'An operation needs a client-generated request id'
      using errcode = '22023',
            hint = 'Without one a retry cannot be told apart from a second, deliberate operation.';
  end if;

  insert into prospect_operations.operation_jobs
    (actor, action, request_id, entity_type, client_scope, content_hash, version_vector,
     payload, excluded_ids, expires_at)
  values (p_actor, p_action, p_request_id, p_entity_type, coalesce(p_client_scope, ''),
          p_content_hash, p_version_vector, coalesce(p_payload, '{}'::jsonb),
          coalesce(p_excluded_ids, array[]::text[]), now() + p_ttl)
  on conflict (actor, action, request_id) do nothing;

  select * into v_row from prospect_operations.operation_jobs j
  where j.actor = p_actor and j.action = p_action and j.request_id = p_request_id;

  -- `reused` means this exact request has been seen before, whatever state it
  -- reached. The caller checks status to decide whether to re-run or to answer
  -- with the recorded result.
  return query select v_row.id, v_row.status, v_row.total_items, v_row.applied_items, v_row.result,
    (v_row.status <> 'pending' or v_row.frozen_at is not null);
end;
$function$;

-- Freeze an explicit selection: the ids the user actually ticked.
create or replace function prospect_operations.freeze_from_ids_v1(
  p_job_id uuid,
  p_actor text,
  p_ids text[]
)
returns table(total_items bigint, excluded_count bigint)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '60s'
as $function$
declare
  v_row prospect_operations.operation_jobs%rowtype;
  v_inserted bigint;
  v_excluded bigint;
begin
  select * into v_row from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor for update;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
  -- Freezing twice would be the silent expansion this exists to prevent.
  if v_row.status <> 'pending' then
    return query select v_row.total_items, v_row.excluded_count;
    return;
  end if;

  with candidate as (
    select distinct value as entity_id from unnest(coalesce(p_ids, array[]::text[])) value
    where btrim(coalesce(value, '')) <> ''
  ), kept as (
    select entity_id, row_number() over (order by entity_id) as ordinal
    from candidate
    where not (entity_id = any (v_row.excluded_ids))
  ), stored as (
    insert into prospect_operations.operation_job_items (job_id, ordinal, entity_id)
    select p_job_id, kept.ordinal, kept.entity_id from kept
    on conflict do nothing
    returning 1
  )
  select (select count(*) from stored), (select count(*) from candidate) - (select count(*) from kept)
  into v_inserted, v_excluded;

  update prospect_operations.operation_jobs
  set status = 'frozen', total_items = v_inserted, excluded_count = v_excluded, frozen_at = now()
  where id = p_job_id;

  return query select v_inserted, v_excluded;
end;
$function$;

-- Freeze from an already-built, already-owned result set: "all matching".
--
-- The result set is the single place a question becomes a list of ids
-- (20260902000120), so this copies rather than re-resolving. It refuses a set
-- that is not the caller's or is not finished - a half-built set frozen into a
-- job would be a silently truncated operation.
create or replace function prospect_operations.freeze_from_result_set_v1(
  p_job_id uuid,
  p_actor text,
  p_result_set_id uuid
)
returns table(total_items bigint, excluded_count bigint)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations, prospect_results
set statement_timeout = '120s'
as $function$
declare
  v_row prospect_operations.operation_jobs%rowtype;
  v_set prospect_results.result_sets%rowtype;
  v_inserted bigint;
  v_excluded bigint;
begin
  select * into v_row from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor for update;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
  if v_row.status <> 'pending' then
    return query select v_row.total_items, v_row.excluded_count;
    return;
  end if;

  select * into v_set from prospect_results.result_sets rs
  where rs.id = p_result_set_id and rs.owner_id = p_actor and rs.expires_at > now();
  if not found then
    raise exception 'Result set is not available' using errcode = 'P0002';
  end if;
  if v_set.status <> 'ready' then
    raise exception 'That result set is still being built'
      using errcode = '22023',
            hint = 'Freezing a half-built set would silently truncate the operation.';
  end if;

  with kept as (
    select i.entity_id, row_number() over (order by i.ordinal) as ordinal
    from prospect_results.result_set_items i
    where i.result_set_id = p_result_set_id
      and not (i.entity_id = any (v_row.excluded_ids))
  ), stored as (
    insert into prospect_operations.operation_job_items (job_id, ordinal, entity_id)
    select p_job_id, kept.ordinal, kept.entity_id from kept
    on conflict do nothing
    returning 1
  )
  select (select count(*) from stored), v_set.row_count - (select count(*) from kept)
  into v_inserted, v_excluded;

  update prospect_operations.operation_jobs
  set status = 'frozen', total_items = v_inserted, excluded_count = greatest(v_excluded, 0),
      frozen_at = now()
  where id = p_job_id;

  return query select v_inserted, greatest(v_excluded, 0);
end;
$function$;

-- The next ids to mutate. Only ever unapplied ones, so a resumed operation
-- continues instead of repeating.
create or replace function prospect_operations.next_batch_v1(
  p_job_id uuid,
  p_batch_size integer default 500
)
returns table(entity_id text)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '30s'
as $function$
begin
  return query
  select i.entity_id from prospect_operations.operation_job_items i
  where i.job_id = p_job_id and i.applied_at is null
  order by i.ordinal
  limit greatest(1, least(coalesce(p_batch_size, 500), 5000));
end;
$function$;

-- Record that a batch actually happened. Called in the same transaction as the
-- mutation it describes, so the two cannot disagree.
create or replace function prospect_operations.mark_applied_v1(
  p_job_id uuid,
  p_ids text[]
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '30s'
as $function$
declare
  v_marked bigint;
begin
  with marked as (
    update prospect_operations.operation_job_items i
    set applied_at = now()
    where i.job_id = p_job_id and i.applied_at is null
      and i.entity_id = any (coalesce(p_ids, array[]::text[]))
    returning 1
  )
  select count(*) into v_marked from marked;

  update prospect_operations.operation_jobs j
  set applied_items = j.applied_items + v_marked,
      status = case when j.applied_items + v_marked >= j.total_items then 'completed' else 'running' end,
      completed_at = case when j.applied_items + v_marked >= j.total_items then now() else null end,
      lease_expires_at = case when j.applied_items + v_marked >= j.total_items then null else j.lease_expires_at end
  where j.id = p_job_id;

  return v_marked;
end;
$function$;

create or replace function prospect_operations.claim_next_v1(
  p_worker_id text,
  p_lease_seconds integer default 300
)
returns table(job_id uuid, action text, entity_type text, client_scope text, payload jsonb, total_items bigint, applied_items bigint)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '15s'
as $function$
declare
  v_id uuid;
begin
  select j.id into v_id from prospect_operations.operation_jobs j
  where j.expires_at > now()
    and (j.status = 'frozen'
         or (j.status = 'running' and coalesce(j.lease_expires_at, now()) <= now()))
  order by j.created_at
  for update skip locked
  limit 1;

  if v_id is null then return; end if;

  update prospect_operations.operation_jobs j
  set status = 'running', worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds))
  where j.id = v_id;

  return query
  select j.id, j.action, j.entity_type, j.client_scope, j.payload, j.total_items, j.applied_items
  from prospect_operations.operation_jobs j where j.id = v_id;
end;
$function$;

-- Record what an operation answered, and close it. Called by the request that
-- performed the mutation, in the same breath, so a retry can be answered from
-- here instead of repeating the work.
create or replace function prospect_operations.record_result_v1(
  p_job_id uuid,
  p_actor text,
  p_result jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '15s'
as $function$
begin
  update prospect_operations.operation_jobs
  set result = p_result, status = 'completed', completed_at = now(),
      worker_id = null, lease_expires_at = null
  where id = p_job_id and actor = p_actor;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
end;
$function$;

create or replace function prospect_operations.fail_v1(p_job_id uuid, p_error text)
returns void
language sql
security definer
set search_path = pg_catalog, public, prospect_operations
as $function$
  update prospect_operations.operation_jobs
  set status = 'failed', error = left(coalesce(p_error, 'unknown'), 2000),
      worker_id = null, lease_expires_at = null, completed_at = now()
  where id = p_job_id;
$function$;

-- What the UI shows: progress, and whether the frozen answer still matches the
-- world. Never repairs anything.
create or replace function prospect_operations.status_v1(
  p_job_id uuid,
  p_actor text,
  p_version_vector jsonb default null
)
returns table(status text, total_items bigint, applied_items bigint, excluded_count bigint,
              stale boolean, frozen_at timestamptz, error text)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '10s'
as $function$
declare
  v_row prospect_operations.operation_jobs%rowtype;
begin
  select * into v_row from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor and j.expires_at > now();
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;

  return query select v_row.status, v_row.total_items, v_row.applied_items, v_row.excluded_count,
    (p_version_vector is not null and v_row.version_vector is distinct from p_version_vector),
    v_row.frozen_at, v_row.error;
end;
$function$;

create or replace function prospect_operations.expire_jobs_v1()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '120s'
as $function$
declare
  v_deleted integer;
begin
  with removed as (
    delete from prospect_operations.operation_jobs where expires_at <= now() returning 1
  )
  select count(*)::integer into v_deleted from removed;
  return v_deleted;
end;
$function$;

revoke execute on function prospect_operations.enqueue_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[], interval) from public, anon, authenticated;
revoke execute on function prospect_operations.freeze_from_ids_v1(uuid, text, text[]) from public, anon, authenticated;
revoke execute on function prospect_operations.freeze_from_result_set_v1(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function prospect_operations.next_batch_v1(uuid, integer) from public, anon, authenticated;
revoke execute on function prospect_operations.mark_applied_v1(uuid, text[]) from public, anon, authenticated;
revoke execute on function prospect_operations.claim_next_v1(text, integer) from public, anon, authenticated;
revoke execute on function prospect_operations.record_result_v1(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function prospect_operations.fail_v1(uuid, text) from public, anon, authenticated;
revoke execute on function prospect_operations.status_v1(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function prospect_operations.expire_jobs_v1() from public, anon, authenticated;

grant usage on schema prospect_operations to service_role;
grant execute on function prospect_operations.enqueue_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[], interval) to service_role;
grant execute on function prospect_operations.freeze_from_ids_v1(uuid, text, text[]) to service_role;
grant execute on function prospect_operations.freeze_from_result_set_v1(uuid, text, uuid) to service_role;
grant execute on function prospect_operations.status_v1(uuid, text, jsonb) to service_role;
grant execute on function prospect_operations.record_result_v1(uuid, text, jsonb) to service_role;
grant execute on function prospect_operations.next_batch_v1(uuid, integer) to service_role;
grant execute on function prospect_operations.mark_applied_v1(uuid, text[]) to service_role;

-- The worker drives execution and retention; it does not enqueue or freeze,
-- because those belong to a signed-in request.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'prospect_operator') then
    raise exception using
      message = 'prospect_operator role is missing',
      hint = 'Run: docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh';
  end if;
end
$$;
grant usage on schema prospect_operations to prospect_operator;
grant execute on function prospect_operations.claim_next_v1(text, integer) to prospect_operator;
grant execute on function prospect_operations.next_batch_v1(uuid, integer) to prospect_operator;
grant execute on function prospect_operations.mark_applied_v1(uuid, text[]) to prospect_operator;
grant execute on function prospect_operations.fail_v1(uuid, text) to prospect_operator;
grant execute on function prospect_operations.expire_jobs_v1() to prospect_operator;

do $$
declare
  v_failures text[] := array[]::text[];
begin
  if has_function_privilege('prospect_operator',
    'prospect_operations.enqueue_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[], interval)', 'execute') then
    v_failures := array_append(v_failures, 'the worker can enqueue an operation on a user''s behalf');
  end if;
  if has_function_privilege('prospect_operator',
    'prospect_operations.freeze_from_result_set_v1(uuid, text, uuid)', 'execute') then
    v_failures := array_append(v_failures, 'the worker can freeze a selection');
  end if;
  if has_table_privilege('prospect_operator', 'prospect_operations.operation_job_items', 'select') then
    v_failures := array_append(v_failures, 'the worker can read frozen ids directly');
  end if;
  if cardinality(v_failures) > 0 then
    raise exception 'operation job privileges are wrong: %', array_to_string(v_failures, '; ');
  end if;
end
$$;


-- Public wrappers, because PGRST_DB_SCHEMAS is `public` and the storage
-- deliberately is not. These are the only doors the application uses; the
-- worker's functions have no wrapper at all, because the worker connects
-- directly and must not be reachable through the API.
create or replace function public.enqueue_operation_v1(
  p_actor text, p_request_id uuid, p_action text, p_entity_type text,
  p_client_scope text, p_content_hash text, p_version_vector jsonb,
  p_payload jsonb default '{}'::jsonb, p_excluded_ids text[] default array[]::text[]
)
returns table(job_id uuid, status text, total_items bigint, applied_items bigint, result jsonb, reused boolean)
language sql security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '15s'
as $function$
  select * from prospect_operations.enqueue_v1(p_actor, p_request_id, p_action, p_entity_type,
    p_client_scope, p_content_hash, p_version_vector, p_payload, p_excluded_ids);
$function$;

create or replace function public.freeze_operation_ids_v1(p_job_id uuid, p_actor text, p_ids text[])
returns table(total_items bigint, excluded_count bigint)
language sql security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '60s'
as $function$
  select * from prospect_operations.freeze_from_ids_v1(p_job_id, p_actor, p_ids);
$function$;

create or replace function public.freeze_operation_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid)
returns table(total_items bigint, excluded_count bigint)
language sql security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '120s'
as $function$
  select * from prospect_operations.freeze_from_result_set_v1(p_job_id, p_actor, p_result_set_id);
$function$;

create or replace function public.record_operation_result_v1(p_job_id uuid, p_actor text, p_result jsonb)
returns void
language sql security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '15s'
as $function$
  select prospect_operations.record_result_v1(p_job_id, p_actor, p_result);
$function$;

create or replace function public.operation_status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb default null)
returns table(status text, total_items bigint, applied_items bigint, excluded_count bigint,
              stale boolean, frozen_at timestamptz, error text)
language sql security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '10s'
as $function$
  select * from prospect_operations.status_v1(p_job_id, p_actor, p_version_vector);
$function$;

revoke execute on function public.enqueue_operation_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[]) from public, anon, authenticated;
revoke execute on function public.freeze_operation_ids_v1(uuid, text, text[]) from public, anon, authenticated;
revoke execute on function public.freeze_operation_from_result_set_v1(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.record_operation_result_v1(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.operation_status_v1(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.enqueue_operation_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[]) to service_role;
grant execute on function public.freeze_operation_ids_v1(uuid, text, text[]) to service_role;
grant execute on function public.freeze_operation_from_result_set_v1(uuid, text, uuid) to service_role;
grant execute on function public.record_operation_result_v1(uuid, text, jsonb) to service_role;
grant execute on function public.operation_status_v1(uuid, text, jsonb) to service_role;

commit;
