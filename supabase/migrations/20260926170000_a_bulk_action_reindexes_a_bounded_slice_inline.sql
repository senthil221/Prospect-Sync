-- A bulk action re-indexes a bounded slice inline and queues the rest.
--
-- MEASURED. The slow-plan log (72 h to 2026-09-26) shows user actions holding
-- an interactive PostgREST connection for most of a minute: deleting a list
-- 58 s (delete_list_and_reindex_v1), reindex_scope_v1 up to 55 s, the
-- reindex_prospects body 14 times up to 23 s. The work is re-indexing, and it
-- is proportional to the selection: reindex_scope_v1 resolved every affected
-- prospect and rebuilt all of them before returning. 13 functions call it -
-- delete a list, client or import; push to a client; ICP verification; client
-- tags; removals; enrich-from-company; both blocklist paths - so any of them
-- on a large selection occupied one of ~24 shared connections and a share of
-- 2 vCPUs for as long as that took, and the pages other people were loading
-- timed out behind it.
--
-- THE CHANGE. The first 200 prospects are re-indexed inline, as before, so a
-- small edit is visible the moment the request returns. Everything past that
-- is inserted into public.reindex_backlog - one narrow insert - and drained by
-- the operations worker on its own single connection, serially, in bounded
-- units. The foreground cost is now bounded by the constant, not the
-- selection: measured on production for a 5,000-prospect scope, 53 s before,
-- 10 s with 500 inline (about 20 ms a prospect, mostly the company-count
-- triggers), hence 200. Callers already report `queued`, and the app already says "N
-- records are queued for re-indexing and will refresh shortly" (indexNotice).
--
-- WHAT IS NOT DEFERRED. The actions whose visibility must be exact at once
-- already patch prospect_index directly before calling this - the blocklist
-- (client_ids/blocked_client_ids) is the case that matters - so for them the
-- deferred rebuild only refreshes derived columns.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

do $BODY$
declare
  v_def text := pg_get_functiondef('public.reindex_scope_v1(text,text[],text[],text[],text[],integer)'::regprocedure);
  v_old constant text :=
E'  while v_offset < cardinality(v_ids) loop
    v_batch := v_ids[v_offset + 1 : v_offset + v_size];';
  v_new constant text :=
E'  -- Bounded inline work (20260926170000): the first 200 now, the rest to the
  -- backlog the operations worker drains.
  if cardinality(v_ids) > 200 then
    perform public.enqueue_reindex(v_ids[201 : cardinality(v_ids)], '''');
    v_queued := cardinality(v_ids) - 200;
    v_ids := v_ids[1 : 200];
  end if;

  while v_offset < cardinality(v_ids) loop
    v_batch := v_ids[v_offset + 1 : v_offset + v_size];';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'reindex_scope_v1 no longer has the loop this migration bounds';
  end if;
  execute replace(v_def, v_old, v_new);
end $BODY$;

revoke execute on function public.reindex_scope_v1(text, text[], text[], text[], text[], integer) from public, anon, authenticated;
grant execute on function public.reindex_scope_v1(text, text[], text[], text[], text[], integer) to service_role;

-- ---------------------------------------------------------------------------
-- Proof on real rows: a 1,200-prospect scope re-indexes 200 inline, queues
-- exactly the other 1,000, and a small scope is still entirely inline. The
-- backlog is restored afterwards so this leaves nothing for the worker.
do $$
declare
  v_ids text[];
  v_row record;
  v_before bigint;
begin
  select count(*) into v_before from public.reindex_backlog;
  v_ids := array(select id from public.prospect_index order by id limit 1200);

  begin
    select * into v_row from public.reindex_scope_v1(p_prospect_ids => v_ids);
    if v_row.reindexed <> 200 or v_row.queued <> 1000 then
      raise exception 'FAIL: a 1,200 scope reported % inline and % queued', v_row.reindexed, v_row.queued;
    end if;
    if (select count(*) from public.reindex_backlog where prospect_id = any(v_ids[201:1200])) <> 1000 then
      raise exception 'FAIL: the deferred 1,000 are not all in the backlog';
    end if;

    select * into v_row from public.reindex_scope_v1(p_prospect_ids => v_ids[1:40]);
    if v_row.reindexed <> 40 or v_row.queued <> 0 then
      raise exception 'FAIL: a 40 scope reported % inline and % queued', v_row.reindexed, v_row.queued;
    end if;

    raise exception 'bounded-reindex-proof-passed';
  exception when others then
    if sqlerrm <> 'bounded-reindex-proof-passed' then
      raise;
    end if;
  end;

  if (select count(*) from public.reindex_backlog) <> v_before then
    raise exception 'the proof left rows in the reindex backlog';
  end if;
end $$;
