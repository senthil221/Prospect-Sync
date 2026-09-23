-- A client's People page finds the client's rows first, then sorts them.
--
-- WHAT WENT WRONG, MEASURED. /api/prospects died at 10,032 ms on 2026-09-23
-- (request fc47a758): the People tab of one client, no search, no filters,
-- newest first. search_prospect_workspace_v12 carries statement_timeout=10s.
--
-- The count was never the problem: `client_ids @> array[...]` goes through the
-- GIN index idx_prospect_index_client_ids and counted that client's 10,536 rows
-- in 16 ms. The page was. `ordered` is `where client_ids @> ... order by
-- created_at desc limit 50`, and with a LIMIT the planner prefers walking
-- idx_prospect_index_created_at from the newest row and filtering, on the
-- assumption that a client's rows are spread evenly through time. They are
-- not: a client's people arrive in a few imports. For this client the walk
-- discarded 136,071 rows and read 66,652 buffers from disk to find 50 -
-- 2,036 ms alone, past 10 s with a cold cache while /api/dashboard and
-- /api/companies ran beside it.
--
-- The same shape, fetching the client's rows through the GIN index and sorting
-- those, took 132 ms. Its cost is the size of the client, not the position of
-- the client's rows in time, so it does not degrade as the table grows or as
-- other clients import newer people.
--
-- WHEN IT APPLIES. Only when the client has at most 50,000 members. Reading
-- every member is linear in the client, and the Unassigned bucket
-- (prospect-sync-no-client) holds almost the whole table; for a client that
-- large the index walk finds 50 matches almost immediately and stays the better
-- plan. The size check is a bounded index-only count of client_prospects, which
-- is exactly the membership client_ids is built from.
--
-- The materialized CTE is the fence: without it the planner would push the
-- ORDER BY/LIMIT back into the scan and pick the walk again. Search, filters
-- and a company scope are applied inside the fence, so they narrow the set that
-- gets sorted and cannot widen it.
-- ---------------------------------------------------------------------------

do $BODY$
declare
  v_def text := pg_get_functiondef('public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'::regprocedure);

  v_old_decl constant text := E'  v_sql text;\nbegin\n';
  v_new_decl constant text := E'  v_sql text;\n  v_ordered_cte text;\n  v_client_members bigint;\nbegin\n';

  v_old_build constant text := E'  v_sql := format($q$\n';
  v_new_build constant text :=
E'  -- A small client is read through the client_ids GIN index and then sorted;
  -- the index walk in sort order is kept for everything else. See
  -- 20260923090000 for the measurements.
  if p_client_id is not null then
    select count(*) into v_client_members from (
      select 1 from public.client_prospects
      where client_id = p_client_id
      limit 50001
    ) members;
  end if;

  if p_client_id is not null and v_client_members <= 50000 then
    v_ordered_cte := format($o$client_rows as materialized (
      select pi.id, %1$s as sort_key
      from public.prospect_index pi%2$s
      where pi.client_ids @> array[%3$L] and (%4$s)
    ), ordered as (
      select client_rows.id, client_rows.sort_key
      from client_rows
      order by client_rows.sort_key %5$s%6$s, client_rows.id
      limit %7$s offset %8$s
    )$o$, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_sort_dir, v_sort_nulls, v_limit::text, v_offset::text);
  else
    v_ordered_cte := format($o$ordered as (
      select pi.id, %1$s as sort_key
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
      order by %5$s
      limit %6$s offset %7$s
    )$o$, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_order, v_limit::text, v_offset::text);
  end if;

  v_sql := format($q$
';

  v_old_ordered constant text :=
E'    with %1$s%2$sordered as (
      select pi.id, %3$s as sort_key
      from public.prospect_index pi%4$s
      where (%5$L is null or pi.client_ids @> array[%5$L]) and (%6$s)
      order by %7$s
      limit %8$s offset %9$s
    ), page as (';
  v_new_ordered constant text := E'    with %1$s%2$s%16$s, page as (';

  v_old_args constant text := E'v_total_expr, v_capped_expr, v_total_capped_expr, v_versions::text);';
  v_new_args constant text := E'v_total_expr, v_capped_expr, v_total_capped_expr, v_versions::text, v_ordered_cte);';
begin
  if position(v_old_decl in v_def) = 0
     or position(v_old_build in v_def) = 0
     or position(v_old_ordered in v_def) = 0
     or position(v_old_args in v_def) = 0 then
    raise exception 'search_prospect_workspace_v12 no longer contains the ordered CTE this migration replaces';
  end if;

  v_def := replace(v_def, v_old_decl, v_new_decl);
  v_def := replace(v_def, v_old_build, v_new_build);
  v_def := replace(v_def, v_old_ordered, v_new_ordered);
  v_def := replace(v_def, v_old_args, v_new_args);

  if position('client_rows as materialized' in v_def) = 0
     or position('%16$s, page as (' in v_def) = 0
     or position('v_versions::text, v_ordered_cte);' in v_def) = 0 then
    raise exception 'the client-first page replacement did not take';
  end if;
  execute v_def;
end $BODY$;

-- ---------------------------------------------------------------------------
-- It is still the same function to everyone who calls it.
do $$
declare
  v_cfg text[];
begin
  select p.proconfig into v_cfg from pg_proc p
   where p.oid = 'public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'::regprocedure;
  if not (array_to_string(v_cfg, ',') like '%statement_timeout%') then
    raise exception 'the workspace function lost its statement_timeout: %', v_cfg;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The page is the same page. For every client small enough to take the new
-- path, and for each sort and direction, the ids returned must be exactly the
-- ids a plain query returns in the same order - on the first page and on a
-- later one, so the offset is proven too.
do $$
declare
  v_client record;
  v_case record;
  v_got text[];
  v_want text[];
  v_total bigint;
begin
  for v_client in
    select client_id, count(*) as members
    from public.client_prospects
    group by client_id
    having count(*) <= 50000
    order by count(*) desc
    limit 3
  loop
    for v_case in
      select * from (values
        ('created_at', 'desc', 0), ('created_at', 'asc', 100),
        ('name', 'asc', 0), ('last_contacted', 'desc', 50)
      ) as c(sort, dir, off)
    loop
      select array(select e->>'id' from jsonb_array_elements(w.result_rows) e), w.total_count
        into v_got, v_total
      from public.search_prospect_workspace_v12(
        '', '[]'::jsonb, v_case.sort, v_case.dir, 50, v_case.off,
        v_client.client_id, null, true, null) w;

      v_want := case
        when v_case.sort = 'created_at' and v_case.dir = 'desc' then array(
          select pi.id::text from public.prospect_index pi
          where pi.client_ids @> array[v_client.client_id]
          order by pi.created_at desc, pi.id limit 50 offset v_case.off)
        when v_case.sort = 'created_at' then array(
          select pi.id::text from public.prospect_index pi
          where pi.client_ids @> array[v_client.client_id]
          order by pi.created_at asc, pi.id limit 50 offset v_case.off)
        when v_case.sort = 'name' then array(
          select pi.id::text from public.prospect_index pi
          where pi.client_ids @> array[v_client.client_id]
          order by lower(pi.full_name) asc, pi.id limit 50 offset v_case.off)
        else array(
          select pi.id::text from public.prospect_index pi
          where pi.client_ids @> array[v_client.client_id]
          order by pi.last_contacted_at desc nulls last, pi.id limit 50 offset v_case.off)
      end;

      if v_got is distinct from v_want then
        raise exception 'client % sorted by % % offset % returned a different page',
          v_client.client_id, v_case.sort, v_case.dir, v_case.off;
      end if;
      if v_total <> (select count(*) from public.prospect_index pi
                     where pi.client_ids @> array[v_client.client_id]) then
        raise exception 'client % reported a different total', v_client.client_id;
      end if;
    end loop;
  end loop;
end $$;
