-- Durable background result sets: freeze the answer, then page it.
--
-- Section 7. Some questions cannot be answered inside an interactive budget --
-- a 500-term substring search, a pivot whose scope exceeds 250,000 companies --
-- and the honest response is not to run them slowly on the interactive pool but
-- to compute them once, store the ids, and let every later surface read the
-- same frozen list.
--
-- IDENTITY IS THE ONE FROM SECTION 4.1, REUSED, NOT REINVENTED. The plan is
-- explicit that result_sets carry "exactly the cache identity from section 4.1
-- / 5.5 - one definition, reused":
--
--   content_hash        the normalized filter AST, as the count cache keys on
--   authorization_scope constant 'global:1' today, because every user is an
--                       allow-listed email with identical server-side access
--                       (section 4.1). The column exists so per-user permissions
--                       do not require a migration to the identity of every
--                       stored set; it is deliberately not a permission service.
--   version_vector      the data_versions_v1 vector from 20260902000070
--
-- WHY THE VECTOR MATTERS HERE MORE THAN IN THE COUNT CACHE. A stale count is a
-- wrong number on screen. A stale result set is a frozen list of ids that later
-- feeds a page, a count, a pivot, an export and a bulk action - so it must never
-- silently gain or lose rows. Section 7: "If any component of the version vector
-- has moved, show 'results as of T' and offer refresh; never silently add rows."
-- is_stale_v1 answers that question; nothing here rebuilds a set behind the
-- caller's back.
--
-- A scoped set records BOTH entity versions, which is why the vector is stored
-- whole rather than as a single number: a company-side write must be able to
-- invalidate a People result set that read companies through its scope.
--
-- ITEMS ARE ROWS, NOT AN ARRAY. Section 7 asks for "normalized items, not ID
-- arrays", keyed both ways: (result_set_id, entity_id) for membership - which is
-- what a bulk action asks - and (result_set_id, ordinal) for paging. An array
-- column would make membership a scan and paging a slice of something that has
-- to be read whole.
--
-- BUILDING IS RESUMABLE AND BOUNDED. The build inserts a batch at a time
-- against a keyset cursor stored on the row, so a build can stop and continue
-- without holding a transaction open for its whole duration, and progress is
-- readable while it runs. That is the same shape the import worker already uses.
--
-- NO WORKER DRIVES THIS YET. claim_next_v1 exists and is deliberately shaped
-- like claim_next_prospect_import_v1 (FOR UPDATE SKIP LOCKED, lease, heartbeat)
-- so the operations worker in Release 2 item 3 is wiring rather than design. A
-- set requested before that worker exists sits in 'pending', which is visible
-- and honest rather than a request that hangs.

begin;

create schema if not exists prospect_results;
revoke all on schema prospect_results from public, anon, authenticated;

create table if not exists prospect_results.result_sets (
  id uuid primary key default gen_random_uuid(),
  owner_id text not null,
  entity_type text not null check (entity_type in ('prospect', 'company')),
  client_scope text not null default '',
  compiler_version integer not null default 1,
  -- The section 4.1 identity, stored whole.
  content_hash text not null,
  authorization_scope text not null default 'global:1',
  version_vector jsonb not null,
  -- What to compute, kept so a build can resume and a refresh can repeat it.
  search text not null default '',
  filters jsonb not null default '[]'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'building', 'ready', 'failed')),
  row_count bigint not null default 0,
  -- Keyset cursor, so a build resumes where it stopped.
  cursor_created_at timestamptz,
  cursor_id text,
  error text,
  worker_id text,
  lease_expires_at timestamptz,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  expires_at timestamptz not null
);
revoke all on prospect_results.result_sets from public, anon, authenticated;

-- One ready set per identity: asking the same question twice reuses the answer
-- rather than computing it again. Partial, because a failed or superseded build
-- must not block a fresh attempt at the same question.
create unique index if not exists uq_result_sets_identity
  on prospect_results.result_sets
     (owner_id, entity_type, client_scope, authorization_scope, content_hash)
  where status in ('pending', 'building', 'ready');
create index if not exists idx_result_sets_pending
  on prospect_results.result_sets (created_at) where status = 'pending';
create index if not exists idx_result_sets_expires_at
  on prospect_results.result_sets (expires_at);

create table if not exists prospect_results.result_set_items (
  result_set_id uuid not null references prospect_results.result_sets(id) on delete cascade,
  ordinal bigint not null,
  entity_id text not null,
  -- Membership, which is what a bulk action asks.
  primary key (result_set_id, entity_id)
);
revoke all on prospect_results.result_set_items from public, anon, authenticated;
-- Paging, which is what the grid asks.
create unique index if not exists uq_result_set_items_ordinal
  on prospect_results.result_set_items (result_set_id, ordinal);

-- Request a set, or hand back the one that already answers this question.
--
-- Reuse is conditional on the version vector still matching: an answer computed
-- before a mutation is not the answer to the same question afterwards.
create or replace function prospect_results.request_set_v1(
  p_owner_id text,
  p_entity_type text,
  p_client_scope text,
  p_search text,
  p_filters jsonb,
  p_content_hash text,
  p_version_vector jsonb,
  p_ttl interval default interval '24 hours'
)
returns table(set_id uuid, status text, row_count bigint, reused boolean, stale boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '15s'
as $function$
declare
  v_scope text := coalesce(p_client_scope, '');
  v_existing prospect_results.result_sets%rowtype;
  v_new uuid;
begin
  if coalesce(btrim(p_owner_id), '') = '' then
    raise exception 'A result set needs an owner' using errcode = '22023';
  end if;
  if p_entity_type not in ('prospect', 'company') then
    raise exception 'Unknown entity type %', p_entity_type using errcode = '22023';
  end if;

  select * into v_existing from prospect_results.result_sets rs
  where rs.owner_id = p_owner_id
    and rs.entity_type = p_entity_type
    and rs.client_scope = v_scope
    and rs.content_hash = p_content_hash
    and rs.status in ('pending', 'building', 'ready')
    and rs.expires_at > now();

  if found then
    -- Reused, but say plainly whether the world moved since it was computed.
    -- The caller decides what to do; nothing is rebuilt behind its back.
    return query select v_existing.id, v_existing.status, v_existing.row_count, true,
      (v_existing.status = 'ready' and v_existing.version_vector is distinct from p_version_vector);
    return;
  end if;

  insert into prospect_results.result_sets
    (owner_id, entity_type, client_scope, content_hash, version_vector, search, filters, expires_at)
  values (p_owner_id, p_entity_type, v_scope, p_content_hash, p_version_vector,
          coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb), now() + p_ttl)
  returning id into v_new;

  return query select v_new, 'pending'::text, 0::bigint, false, false;
end;
$function$;

-- Claim the next set to build. Shaped exactly like the import worker's claim so
-- Release 2 item 3 is wiring rather than design: SKIP LOCKED so two workers
-- never take the same row, and a lease so a worker that dies frees its work.
create or replace function prospect_results.claim_next_v1(
  p_worker_id text,
  p_lease_seconds integer default 300
)
returns table(set_id uuid, entity_type text, client_scope text, search text, filters jsonb, row_count bigint)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '15s'
as $function$
declare
  v_id uuid;
begin
  select rs.id into v_id
  from prospect_results.result_sets rs
  where rs.expires_at > now()
    and (rs.status = 'pending'
         or (rs.status = 'building' and coalesce(rs.lease_expires_at, now()) <= now()))
  order by rs.created_at
  for update skip locked
  limit 1;

  if v_id is null then return; end if;

  update prospect_results.result_sets rs
  set status = 'building',
      worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds)),
      started_at = coalesce(rs.started_at, now())
  where rs.id = v_id;

  return query
  select rs.id, rs.entity_type, rs.client_scope, rs.search, rs.filters, rs.row_count
  from prospect_results.result_sets rs where rs.id = v_id;
end;
$function$;

-- Insert one bounded batch of ids, and say whether there is more to do.
--
-- The predicate is compiled by the same functions the interactive path uses, so
-- a result set and a listing answer the same question. Ordering is
-- (created_at desc, id), matching the listing's default and giving the keyset
-- cursor something total to resume from.
create or replace function prospect_results.build_batch_v1(
  p_set_id uuid,
  p_batch_size integer default 25000
)
returns table(inserted integer, total bigint, done boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '120s'
as $function$
declare
  v_row prospect_results.result_sets%rowtype;
  v_batch integer := greatest(1000, least(coalesce(p_batch_size, 25000), 100000));
  v_predicate text;
  v_sql text;
  v_inserted integer;
  v_last_created timestamptz;
  v_last_id text;
begin
  select * into v_row from prospect_results.result_sets where id = p_set_id for update;
  if not found then
    raise exception 'Result set does not exist' using errcode = 'P0002';
  end if;
  if v_row.status not in ('pending', 'building') then
    return query select 0, v_row.row_count, true;
    return;
  end if;

  if v_row.entity_type = 'prospect' then
    v_predicate := public.prospect_filter_sql_v1(v_row.search, v_row.filters);
    if v_predicate is null then
      raise exception 'This filter set cannot be compiled into a result set' using errcode = '22023';
    end if;
    v_sql := format($q$
      with batch as (
        select pi.id, pi.created_at
        from public.prospect_index pi
        where (%1$L is null or pi.client_ids @> array[%1$L])
          and (%2$s)
          and (%3$L::timestamptz is null
               or (pi.created_at, pi.id) < (%3$L::timestamptz, coalesce(%4$L, '')))
        order by pi.created_at desc, pi.id desc
        limit %5$s
      ), numbered as (
        select batch.*, %6$s + row_number() over (order by created_at desc, id desc) as ordinal
        from batch
      ), stored as (
        insert into prospect_results.result_set_items (result_set_id, ordinal, entity_id)
        select %7$L::uuid, numbered.ordinal, numbered.id from numbered
        on conflict do nothing
        returning 1
      )
      select (select count(*) from stored)::integer,
             (select created_at from numbered order by ordinal desc limit 1),
             (select id from numbered order by ordinal desc limit 1)
    $q$, nullif(v_row.client_scope, ''), v_predicate, v_row.cursor_created_at, v_row.cursor_id,
         v_batch::text, v_row.row_count::text, p_set_id);
  else
    v_predicate := public.company_effective_filter_sql_v1(v_row.search, v_row.filters);
    if v_predicate is null then
      raise exception 'This filter set cannot be compiled into a result set' using errcode = '22023';
    end if;
    v_sql := format($q$
      with batch as (
        select c.id, c.created_at
        from public.companies c
        where (%1$s)
          and (%2$L::timestamptz is null
               or (c.created_at, c.id) < (%2$L::timestamptz, coalesce(%3$L, '')))
        order by c.created_at desc, c.id desc
        limit %4$s
      ), numbered as (
        select batch.*, %5$s + row_number() over (order by created_at desc, id desc) as ordinal
        from batch
      ), stored as (
        insert into prospect_results.result_set_items (result_set_id, ordinal, entity_id)
        select %6$L::uuid, numbered.ordinal, numbered.id from numbered
        on conflict do nothing
        returning 1
      )
      select (select count(*) from stored)::integer,
             (select created_at from numbered order by ordinal desc limit 1),
             (select id from numbered order by ordinal desc limit 1)
    $q$, v_predicate, v_row.cursor_created_at, v_row.cursor_id,
         v_batch::text, v_row.row_count::text, p_set_id);
  end if;

  execute v_sql into v_inserted, v_last_created, v_last_id;
  v_inserted := coalesce(v_inserted, 0);

  if v_inserted = 0 then
    update prospect_results.result_sets
    set status = 'ready', completed_at = now(), lease_expires_at = null, worker_id = null
    where id = p_set_id;
    return query select 0, v_row.row_count, true;
    return;
  end if;

  update prospect_results.result_sets
  set row_count = row_count + v_inserted,
      cursor_created_at = v_last_created,
      cursor_id = v_last_id,
      lease_expires_at = greatest(coalesce(lease_expires_at, now()), now() + interval '120 seconds'),
      -- A short batch means the source is exhausted; no extra probing round.
      status = case when v_inserted < v_batch then 'ready' else status end,
      completed_at = case when v_inserted < v_batch then now() else completed_at end
  where id = p_set_id
  returning row_count, status = 'ready' into total, done;

  inserted := v_inserted;
  return next;
end;
$function$;

-- Read a page of a frozen set. Ownership is checked here, every time.
create or replace function prospect_results.page_v1(
  p_set_id uuid,
  p_owner_id text,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(entity_id text, ordinal bigint)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '20s'
as $function$
declare
  v_row prospect_results.result_sets%rowtype;
begin
  select * into v_row from prospect_results.result_sets rs
  where rs.id = p_set_id and rs.owner_id = p_owner_id and rs.expires_at > now();
  if not found then
    raise exception 'Result set is not available' using errcode = 'P0002';
  end if;

  return query
  select i.entity_id, i.ordinal
  from prospect_results.result_set_items i
  where i.result_set_id = p_set_id
  order by i.ordinal
  limit greatest(1, least(coalesce(p_limit, 50), 1000))
  offset greatest(0, coalesce(p_offset, 0));
end;
$function$;

-- Status, including whether the world moved since this answer was frozen.
create or replace function prospect_results.status_v1(
  p_set_id uuid,
  p_owner_id text,
  p_version_vector jsonb default null
)
returns table(status text, row_count bigint, stale boolean, frozen_at timestamptz, version_vector jsonb, error text)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '10s'
as $function$
declare
  v_row prospect_results.result_sets%rowtype;
begin
  select * into v_row from prospect_results.result_sets rs
  where rs.id = p_set_id and rs.owner_id = p_owner_id and rs.expires_at > now();
  if not found then
    raise exception 'Result set is not available' using errcode = 'P0002';
  end if;

  return query select
    v_row.status,
    v_row.row_count,
    -- Never "refresh it for them": say the answer is as of a moment, and let
    -- the caller ask again. Silently adding rows to a frozen list is the thing
    -- section 7 forbids.
    (p_version_vector is not null and v_row.version_vector is distinct from p_version_vector),
    coalesce(v_row.completed_at, v_row.started_at, v_row.created_at),
    v_row.version_vector,
    v_row.error;
end;
$function$;

create or replace function prospect_results.fail_set_v1(p_set_id uuid, p_error text)
returns void
language sql
security definer
set search_path = pg_catalog, public, prospect_results
as $function$
  update prospect_results.result_sets
  set status = 'failed', error = left(coalesce(p_error, 'unknown'), 2000),
      lease_expires_at = null, worker_id = null, completed_at = now()
  where id = p_set_id;
$function$;

create or replace function prospect_results.expire_sets_v1()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '120s'
as $function$
declare
  v_deleted integer;
begin
  with removed as (
    delete from prospect_results.result_sets where expires_at <= now() returning 1
  )
  select count(*)::integer into v_deleted from removed;
  return v_deleted;
end;
$function$;

create or replace function prospect_results.usage_v1()
returns table(sets bigint, pending bigint, building bigint, ready bigint, items bigint, bytes bigint)
language sql
stable
security definer
set search_path = pg_catalog, public, prospect_results
as $function$
  select (select count(*) from prospect_results.result_sets),
         (select count(*) from prospect_results.result_sets where status = 'pending'),
         (select count(*) from prospect_results.result_sets where status = 'building'),
         (select count(*) from prospect_results.result_sets where status = 'ready'),
         (select count(*) from prospect_results.result_set_items),
         pg_total_relation_size('prospect_results.result_set_items')
           + pg_total_relation_size('prospect_results.result_sets');
$function$;

revoke execute on function prospect_results.request_set_v1(text, text, text, text, jsonb, text, jsonb, interval) from public, anon, authenticated;
revoke execute on function prospect_results.claim_next_v1(text, integer) from public, anon, authenticated;
revoke execute on function prospect_results.build_batch_v1(uuid, integer) from public, anon, authenticated;
revoke execute on function prospect_results.page_v1(uuid, text, integer, integer) from public, anon, authenticated;
revoke execute on function prospect_results.status_v1(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function prospect_results.fail_set_v1(uuid, text) from public, anon, authenticated;
revoke execute on function prospect_results.expire_sets_v1() from public, anon, authenticated;
revoke execute on function prospect_results.usage_v1() from public, anon, authenticated;
grant usage on schema prospect_results to service_role;
grant execute on function prospect_results.request_set_v1(text, text, text, text, jsonb, text, jsonb, interval) to service_role;
grant execute on function prospect_results.claim_next_v1(text, integer) to service_role;
grant execute on function prospect_results.build_batch_v1(uuid, integer) to service_role;
grant execute on function prospect_results.page_v1(uuid, text, integer, integer) to service_role;
grant execute on function prospect_results.status_v1(uuid, text, jsonb) to service_role;
grant execute on function prospect_results.fail_set_v1(uuid, text) to service_role;
grant execute on function prospect_results.expire_sets_v1() to service_role;
grant execute on function prospect_results.usage_v1() to service_role;

commit;
