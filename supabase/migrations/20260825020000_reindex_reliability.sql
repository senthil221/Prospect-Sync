-- The search index could drift from the truth permanently and invisibly.
--
-- reindex_prospects returns an error on failure and every one of the eight
-- call sites discarded it: the write committed, the API returned 200, and
-- prospect_index quietly stopped matching prospects. There was no detection and
-- no repair path short of a manual reindex_all.
--
-- It was not hypothetical. reindex_prospects carries a 15s statement timeout and
-- the client-delete route passed EVERY affected prospect id in one unbatched
-- call, so deleting a large client was guaranteed to time out — and be ignored.
--
-- Three parts: a backlog table so a failed reindex is remembered rather than
-- lost, server-side scope resolution so ids never round-trip through the app,
-- and a drift check so "is the index correct?" has an answer.

-- ---------------------------------------------------------------------------
-- 1. Backlog
-- ---------------------------------------------------------------------------

create table if not exists public.reindex_backlog (
  prospect_id text primary key,
  enqueued_at timestamptz not null default now(),
  attempts integer not null default 0,
  last_error text not null default '',
  last_attempt_at timestamptz
);

create index if not exists idx_reindex_backlog_enqueued
  on public.reindex_backlog (enqueued_at);

alter table public.reindex_backlog enable row level security;
revoke all on public.reindex_backlog from anon, authenticated;

create or replace function public.enqueue_reindex(p_ids text[], p_error text default '')
returns integer
language sql
security definer
set search_path = public
as $$
  insert into public.reindex_backlog (prospect_id, last_error)
  select distinct id, coalesce(left(p_error, 500), '')
  from unnest(coalesce(p_ids, array[]::text[])) as id
  where id is not null and id <> ''
  on conflict (prospect_id) do update set
    enqueued_at = least(public.reindex_backlog.enqueued_at, now()),
    last_error = coalesce(left(excluded.last_error, 500), '')
  returning 1;
$$;

-- Drain a bounded slice of the backlog. Returns what happened so a caller (the
-- maintenance timer, or the Data Quality panel) can loop until it reports zero.
create or replace function public.drain_reindex_backlog(p_limit integer default 2000)
returns table(processed integer, remaining bigint)
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_ids text[];
  v_done integer := 0;
begin
  select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
  from (
    select prospect_id from public.reindex_backlog
    order by enqueued_at
    limit greatest(1, least(coalesce(p_limit, 2000), 10000))
    for update skip locked
  ) batch;

  if cardinality(v_ids) = 0 then
    processed := 0;
    remaining := 0;
    return next;
    return;
  end if;

  begin
    v_done := public.reindex_prospects(v_ids);
    delete from public.reindex_backlog where prospect_id = any(v_ids);
  exception when others then
    -- Leave the rows queued, record why, and let the next drain retry them.
    update public.reindex_backlog set
      attempts = attempts + 1,
      last_attempt_at = now(),
      last_error = left(sqlerrm, 500)
    where prospect_id = any(v_ids);
    v_done := 0;
  end;

  processed := v_done;
  select count(*) into remaining from public.reindex_backlog;
  return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Server-side scope resolution
-- ---------------------------------------------------------------------------
-- Reindexing everything attached to a client / list / import used to mean the
-- app SELECTing every prospect_id over HTTP and handing them straight back.
-- These resolve and reindex in one call, in bounded batches, and queue whatever
-- they could not finish instead of dropping it.

create or replace function public.reindex_scope_v1(
  p_client_id text default null,
  p_list_ids text[] default null,
  p_import_ids text[] default null,
  p_company_ids text[] default null,
  p_prospect_ids text[] default null,
  p_batch integer default 2000
)
returns table(reindexed integer, queued integer)
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_ids text[];
  v_batch text[];
  v_size integer := greatest(100, least(coalesce(p_batch, 2000), 5000));
  v_offset integer := 0;
  v_done integer := 0;
  v_queued integer := 0;
begin
  select coalesce(array_agg(distinct target_id), array[]::text[]) into v_ids
  from (
    select lm.prospect_id as target_id
    from public.list_memberships lm
    join public.lists l on l.id = lm.list_id
    where p_client_id is not null and l.client_id = p_client_id
    union
    select lm.prospect_id
    from public.list_memberships lm
    where p_list_ids is not null and lm.list_id = any(p_list_ids)
    union
    select lr.prospect_id
    from public.list_rows lr
    where p_import_ids is not null and lr.import_id = any(p_import_ids) and lr.prospect_id is not null
    union
    select p.id
    from public.prospects p
    where p_company_ids is not null and p.company_id = any(p_company_ids)
    union
    select id
    from unnest(coalesce(p_prospect_ids, array[]::text[])) as id
  ) targets
  where target_id is not null;

  while v_offset < cardinality(v_ids) loop
    v_batch := v_ids[v_offset + 1 : v_offset + v_size];
    begin
      v_done := v_done + public.reindex_prospects(v_batch);
    exception when others then
      -- A batch that times out is remembered, not lost.
      perform public.enqueue_reindex(v_batch, sqlerrm);
      v_queued := v_queued + cardinality(v_batch);
    end;
    v_offset := v_offset + v_size;
  end loop;

  reindexed := v_done;
  queued := v_queued;
  return next;
end;
$$;

-- Delete + reindex as one server-side call. The app used to SELECT every
-- affected prospect_id over HTTP, delete, then hand the same ids back; for a
-- client with 100k prospects that is 100k ids across the wire twice, and the
-- reindex that followed was a single call certain to exceed its timeout.
create or replace function public.delete_client_and_reindex_v1(p_client_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_result jsonb;
  v_reindex record;
begin
  select coalesce(array_agg(distinct lm.prospect_id), array[]::text[]) into v_ids
  from public.list_memberships lm
  join public.lists l on l.id = lm.list_id
  where l.client_id = p_client_id and lm.prospect_id is not null;

  v_result := public.delete_client_with_cleanup(p_client_id, false);
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  return v_result || jsonb_build_object('reindexed', v_reindex.reindexed, 'queued', v_reindex.queued);
end;
$$;

create or replace function public.delete_list_and_reindex_v1(p_list_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_result jsonb;
  v_reindex record;
begin
  select coalesce(array_agg(distinct lm.prospect_id), array[]::text[]) into v_ids
  from public.list_memberships lm
  where lm.list_id = p_list_id and lm.prospect_id is not null;

  v_result := public.delete_list_with_cleanup(p_list_id, false);
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  return v_result || jsonb_build_object('reindexed', v_reindex.reindexed, 'queued', v_reindex.queued);
end;
$$;

create or replace function public.delete_import_and_reindex_v1(p_import_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_result jsonb;
  v_reindex record;
begin
  select coalesce(array_agg(distinct lr.prospect_id), array[]::text[]) into v_ids
  from public.list_rows lr
  where lr.import_id = p_import_id and lr.prospect_id is not null;

  v_result := public.delete_import_with_cleanup(p_import_id, false);
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  return v_result || jsonb_build_object('reindexed', v_reindex.reindexed, 'queued', v_reindex.queued);
end;
$$;

revoke execute on function public.delete_client_and_reindex_v1(text) from public, anon, authenticated;
revoke execute on function public.delete_list_and_reindex_v1(text) from public, anon, authenticated;
revoke execute on function public.delete_import_and_reindex_v1(text) from public, anon, authenticated;
grant execute on function public.delete_client_and_reindex_v1(text) to service_role;
grant execute on function public.delete_list_and_reindex_v1(text) to service_role;
grant execute on function public.delete_import_and_reindex_v1(text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Drift detection
-- ---------------------------------------------------------------------------
-- A denormalized index you cannot verify is one you cannot trust. This is cheap
-- enough to run on the Data Quality page: three counts and one anti-join capped
-- at a sample, not a full row-by-row comparison.

create or replace function public.prospect_index_drift()
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
  select jsonb_build_object(
    'prospects', (select count(*) from public.prospects),
    'indexed', (select count(*) from public.prospect_index),
    'missingFromIndex', (
      select count(*) from (
        select 1 from public.prospects p
        where not exists (select 1 from public.prospect_index pi where pi.id = p.id)
        limit 10000
      ) sample
    ),
    'staleInIndex', (
      select count(*) from (
        select 1 from public.prospects p
        join public.prospect_index pi on pi.id = p.id
        where pi.updated_at < p.updated_at
        limit 10000
      ) sample
    ),
    'queued', (select count(*) from public.reindex_backlog),
    'queuedFailing', (select count(*) from public.reindex_backlog where attempts > 0),
    'oldestQueuedAt', (select min(enqueued_at) from public.reindex_backlog)
  );
$$;

revoke execute on function public.enqueue_reindex(text[], text) from public, anon, authenticated;
revoke execute on function public.drain_reindex_backlog(integer) from public, anon, authenticated;
revoke execute on function public.reindex_scope_v1(text, text[], text[], text[], text[], integer) from public, anon, authenticated;
revoke execute on function public.prospect_index_drift() from public, anon, authenticated;
grant execute on function public.enqueue_reindex(text[], text) to service_role;
grant execute on function public.drain_reindex_backlog(integer) to service_role;
grant execute on function public.reindex_scope_v1(text, text[], text[], text[], text[], integer) to service_role;
grant execute on function public.prospect_index_drift() to service_role;

-- ---------------------------------------------------------------------------
-- 4. Smoke test
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_row record;
  v_drift jsonb;
begin
  -- Every scope argument, including all-null (which must resolve to no work).
  select * into v_row from public.reindex_scope_v1();
  if v_row.reindexed <> 0 or v_row.queued <> 0 then
    raise exception 'an empty scope must do no work, got % / %', v_row.reindexed, v_row.queued;
  end if;
  select * into v_row from public.reindex_scope_v1(p_prospect_ids => array(select id from public.prospects limit 3));
  select * into v_row from public.reindex_scope_v1(p_client_id => (select id from public.clients limit 1));
  select * into v_row from public.reindex_scope_v1(p_list_ids => array(select id from public.lists limit 1));
  select * into v_row from public.reindex_scope_v1(p_company_ids => array(select id from public.companies limit 1));

  -- Backlog round-trip: enqueue, drain, confirm it emptied.
  perform public.enqueue_reindex(array(select id from public.prospects limit 2), 'smoke test');
  select * into v_row from public.drain_reindex_backlog(10);
  if exists (select 1 from public.reindex_backlog where last_error = 'smoke test') then
    raise exception 'drain_reindex_backlog left its own test rows queued';
  end if;

  v_drift := public.prospect_index_drift();
  if v_drift->'prospects' is null or v_drift->'queued' is null then
    raise exception 'prospect_index_drift returned an unexpected shape: %', v_drift;
  end if;
end;
$smoke$;
