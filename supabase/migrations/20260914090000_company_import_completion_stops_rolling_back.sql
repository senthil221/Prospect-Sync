-- Company import completion committed its status flip and rebuilt the search
-- index in ONE transaction, so the index work rolled back the completion.
--
-- WHAT WAS OBSERVED. From the PostgREST log on production:
--
--   POST /rpc/complete_company_import_v1  ->  57014  13/Sep/2026:09:58:54
--   POST /rpc/complete_company_import_v1  ->  57014  14/Sep/2026:11:37:16
--
-- and import 6f67ba20-1ecb-4ba1-b9f8-ddd26102b9c0 left at status='processing'
-- with processed_rows = total_rows = 12498. Every row had been uploaded. Only
-- the completion was missing, and it could not be supplied.
--
-- WHY IT COULD NEVER SUCCEED. complete_company_import_v1 did two things under
-- one statement_timeout of 120s:
--
--   1. update public.company_imports set status = 'completed' ...
--   2. a single unbounded UPDATE of public.prospect_index rebuilding the
--      ~20-field search_text concat (including pi.all_data::text) for every
--      prospect whose company the import had touched.
--
-- Measured for that import: 12,498 company rows resolve to 131,769
-- prospect_index rows. Step 2 does not fit in 120s. And because both steps
-- shared a transaction, the 57014 rolled back step 1 as well - so the import
-- stayed 'processing', and the next attempt started the same 131,769 rows from
-- the beginning. The failure was not slow, it was closed: no number of retries
-- would ever have completed that import.
--
-- THE CONTRAST THAT NAMES THE BUG. lib/import-complete.ts, the People path,
-- does no index work in completion at all, which is exactly why People import
-- never times out. Company import was alone in doing the whole rebuild inside
-- the user's request.
--
-- WHAT THIS CHANGES IT TO. Completion queues instead of rebuilding. Measured
-- against production, resolving the affected prospects for that same import:
--
--   resolve 131,769 prospect ids            2,006 ms   (EXPLAIN ANALYZE)
--   the UPDATE it replaces                 >120,000 ms  (57014, twice)
--
-- The queue write is a narrow INSERT into a 5-column primary-key table, against
-- a wide UPDATE that rebuilt a large concat and paid prospect_index's index
-- maintenance on every one of 131,769 rows.
--
-- BE HONEST ABOUT THE TRADE. public.reindex_prospects recomputes the WHOLE
-- index row - list and client aggregates, tags, contact events - so per
-- prospect it is MORE expensive than the narrow company-column UPDATE removed
-- here. Total work goes up, not down. What changes is that the work is bounded
-- per call, resumable after a failure, and outside the transaction the user is
-- waiting on. That is the entire point; it is not a speedup.
--
-- THE SECOND REASON THIS COULD NOT WAIT. prospect_operations' worker calls
-- expire_abandoned_company_imports_v1(24, 50) every five minutes, and it closes
-- an import whose processed_rows >= total_rows once its staging is 24h stale.
-- It does NO index refresh. So the stuck import above would have flipped itself
-- to 'completed' within a day, the symptom would have disappeared, and 131,769
-- prospect_index rows would have been left permanently stale with nothing
-- recording it. A bug that fixes its own symptom and keeps its corruption is
-- worse than one that stays visible.
--
-- WHAT DRAINS THE QUEUE. Nothing did. Before this migration the only caller of
-- drain_reindex_backlog anywhere was POST /api/data-quality - a button. So
-- queueing alone would have been a slower way to leave the index stale. The
-- grant at the bottom of this file, plus the drain added to
-- worker/operations-worker.mjs in the same change, is what makes the queue mean
-- something. Do not separate them.
--
-- A TRAP WORTH NAMING. reindex_scope_v1's p_import_ids branch resolves through
-- public.list_rows, which is a PEOPLE import concept. Passing a company import
-- id to it matches nothing and returns reindexed=0 with no error at all. That
-- is why this file adds a company-import-aware resolver instead of reusing it.
--
-- This supersedes the 120s ceiling that 20260913020000 stated for
-- complete_company_import_v1. That migration set the bound where the function
-- inherited one; this one makes the function no longer need it.
-- ---------------------------------------------------------------------------

-- Premises. Each of these is machinery this migration delegates to; failing
-- loudly here beats discovering at runtime that the queue has no bottom.
do $$
begin
  if to_regclass('public.reindex_backlog') is null then
    raise exception 'reindex_backlog is missing; apply 20260825020000_reindex_reliability.sql first';
  end if;
  if to_regprocedure('public.drain_reindex_backlog(integer)') is null then
    raise exception 'drain_reindex_backlog is missing; apply 20260825020000_reindex_reliability.sql first';
  end if;
  if to_regprocedure('public.reindex_prospects(text[])') is null then
    raise exception 'reindex_prospects is missing; apply 20260825020000_reindex_reliability.sql first';
  end if;
  if to_regclass('public.company_import_rows') is null then
    raise exception 'company_import_rows is missing; apply the company import migrations first';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Queue one bounded, resumable slice of a company import's prospects.
--
-- WHY A KEYSET CURSOR AND NOT "not exists (select 1 from reindex_backlog)".
-- The obvious way to avoid re-queueing is to skip rows already queued. But the
-- drain is removing those rows concurrently, so a re-run would find them
-- missing and queue them again - a loop with no guaranteed end. Walking
-- prospects.id forward is exact, terminates, and can resume from any point,
-- which is also what makes it usable for repairing an import by hand.
create or replace function public.queue_company_import_reindex_v1(
  p_import_id text,
  p_after_prospect_id text default '',
  p_limit integer default 25000
)
returns table(queued integer, last_prospect_id text)
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_ids text[];
begin
  select coalesce(array_agg(slice.id order by slice.id), array[]::text[])
    into v_ids
  from (
    select p.id
      from public.prospects p
     where p.id > coalesce(p_after_prospect_id, '')
       and p.company_id in (
         select cir.company_id
           from public.company_import_rows cir
          where cir.import_id = p_import_id
            and cir.company_id is not null)
     order by p.id
     limit greatest(1, least(coalesce(p_limit, 25000), 100000))
  ) slice;

  if cardinality(v_ids) = 0 then
    queued := 0;
    last_prospect_id := coalesce(p_after_prospect_id, '');
    return next;
    return;
  end if;

  insert into public.reindex_backlog (prospect_id, last_error)
  select id, 'company import ' || p_import_id
    from unnest(v_ids) as id
  on conflict (prospect_id) do update set
    enqueued_at = least(public.reindex_backlog.enqueued_at, now());

  queued := cardinality(v_ids);
  last_prospect_id := v_ids[cardinality(v_ids)];
  return next;
end;
$$;

comment on function public.queue_company_import_reindex_v1(text, text, integer) is
  'Queue one bounded slice of a company import''s prospects for re-index. Loop it, feeding last_prospect_id back in, until queued < p_limit.';

revoke execute on function public.queue_company_import_reindex_v1(text, text, integer) from public, anon, authenticated;
grant execute on function public.queue_company_import_reindex_v1(text, text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- Completion: decide the import, queue the index work, return.
--
-- The signature and the five returned columns are deliberately unchanged.
-- PostgREST already has this function in its schema cache, so the fix lands
-- whether or not the cache is reloaded, and the running app reads only four of
-- the five columns. indexed_rows now carries rows QUEUED rather than rows
-- rewritten - a column whose name would otherwise lie, which is why it is said
-- here and in the comment below.
create or replace function public.complete_company_import_v1(p_import_id text)
returns table(processed_rows integer, added_count integer, updated_count integer, skipped_count integer, indexed_rows integer)
language plpgsql
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  result_processed integer;
  result_added integer;
  result_updated integer;
  result_skipped integer;
  result_queued integer := 0;
begin
  -- The status predicate keeps a late chunk replay and a completion from
  -- interleaving into a wrong state; import_company_batch_v3 takes the same row
  -- for update and refuses unless it is still 'processing'.
  update public.company_imports ci
  set status = 'completed', completed_at = coalesce(ci.completed_at, now())
  where ci.id = p_import_id and ci.status = 'processing'
  returning ci.processed_rows, ci.added_count, ci.updated_count, ci.skipped_count
  into result_processed, result_added, result_updated, result_skipped;

  if not found then
    -- Already completed - by an earlier partial attempt, or by
    -- expire_abandoned_company_imports_v1. Completion is idempotent now:
    -- re-calling it has to be how a half-finished import is finished, so it
    -- must not raise. P0002 is reserved for an id that genuinely does not exist.
    select ci.processed_rows, ci.added_count, ci.updated_count, ci.skipped_count
      into result_processed, result_added, result_updated, result_skipped
      from public.company_imports ci
     where ci.id = p_import_id;
    if not found then
      raise exception 'Company import not found' using errcode = 'P0002';
    end if;
  end if;

  -- Queue the first slice inline so the common import needs no follow-up at
  -- all. The caller keeps calling queue_company_import_reindex_v1 for the rest.
  --
  -- The subtransaction is the point: the import is already decided above, and
  -- nothing about queueing may take that back. That was the original bug, in
  -- miniature - so it is handled rather than trusted.
  begin
    select q.queued into result_queued
      from public.queue_company_import_reindex_v1(p_import_id, '', 25000) q;
  exception when others then
    result_queued := 0;
  end;

  return query select result_processed, result_added, result_updated,
    result_skipped, result_queued;
end;
$$;

comment on function public.complete_company_import_v1(text) is
  'Mark a company import completed and QUEUE its prospects for re-index. indexed_rows is rows queued, not rows rewritten. Idempotent: safe to call on an already-completed import.';

-- ---------------------------------------------------------------------------
-- The operations worker drains the backlog, so it needs to be allowed to.
--
-- prospect_ops_worker is a member of prospect_operator and has service_role
-- explicitly revoked, so the service_role grant in 20260825020000 does not
-- reach it. Same shape as 20260911130000's dual grant.
grant execute on function public.drain_reindex_backlog(integer) to prospect_operator;

-- ---------------------------------------------------------------------------
-- Assertions. Cheap only: no data repair here. Repairing the 131,769 stale rows
-- is a runtime loop over queue_company_import_reindex_v1 and
-- drain_reindex_backlog, deliberately NOT part of this file, because every
-- migration runs in one transaction and a repair that long would hold locks for
-- its whole duration and could not resume after a failure.
do $$
declare
  v_def text;
  v_cfg text[];
  v_queued integer;
begin
  v_def := pg_get_functiondef(to_regprocedure('public.complete_company_import_v1(text)'));
  if v_def ilike '%update public.prospect_index%' then
    raise exception 'complete_company_import_v1 still rebuilds prospect_index inline';
  end if;

  -- CREATE OR REPLACE rewrites proconfig wholesale, which is how a pinned
  -- search_path gets silently dropped by a later edit. 20260913020000 and
  -- verify-migrations.sql check 130 exist because of that failure mode.
  select p.proconfig into v_cfg from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'complete_company_import_v1';
  if not (array_to_string(v_cfg, ',') like '%search_path=%') then
    raise exception 'complete_company_import_v1 lost its pinned search_path: %', v_cfg;
  end if;
  if not (array_to_string(v_cfg, ',') like '%statement_timeout=%') then
    raise exception 'complete_company_import_v1 lost its statement_timeout: %', v_cfg;
  end if;

  select p.proconfig into v_cfg from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'queue_company_import_reindex_v1';
  if not (array_to_string(v_cfg, ',') like '%search_path=%')
     or not (array_to_string(v_cfg, ',') like '%statement_timeout=%') then
    raise exception 'queue_company_import_reindex_v1 is missing search_path or statement_timeout: %', v_cfg;
  end if;

  if not has_function_privilege('prospect_operator', 'public.drain_reindex_backlog(integer)', 'EXECUTE') then
    raise exception 'prospect_operator cannot drain the reindex backlog; the queue would have no bottom';
  end if;

  -- Smoke: an unknown import queues nothing and does not raise.
  select q.queued into v_queued
    from public.queue_company_import_reindex_v1('migration-smoke-test-no-such-import', '', 10) q;
  if v_queued <> 0 then
    raise exception 'queue_company_import_reindex_v1 queued % rows for an import that does not exist', v_queued;
  end if;
end $$;
