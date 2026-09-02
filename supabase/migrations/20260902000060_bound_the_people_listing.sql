-- Let the People listing stop early, the way the company listing already does.
--
-- Same shape, same fix as 20260902000010. search_prospect_workspace_v12 builds
-- `matched as materialized` and then reads it twice, once to sort a page of 50
-- and once to count. Materialising it means running the predicate over every
-- prospect and building the whole match set before either LIMIT can apply.
--
-- Measured on production at 20260902000030, unfiltered page 1 sorted by name --
-- the most ordinary request there is:
--
--   materialised match set + dynamic CASE order ... 170,527 buffers, 74 MB temp, 1,328 ms
--   static order, no CTE, id tie-break ...........      54 buffers,  no temp,     0.14 ms
--
-- The temp spill is the part that does not show up in a single-user test: 74 MB
-- written per page load, from every user, is a large share of the temp-file
-- growth the audit recorded.
--
-- Two things were expected to matter here and did not, so both are recorded
-- rather than acted on:
--
-- 1. The dynamic CASE ordering was expected to block sort indexes. It does not.
--    PostgreSQL constant-folds the literals and the plan showed
--    `Sort Key: (lower(full_name)), created_at DESC, id`, with the dead arms
--    removed. It is still replaced below, because a static branch is what a
--    keyset cursor can be built on and what an index can be matched against by
--    reading the SQL -- but it was not the cost.
--
-- 2. Composite (sort column, id) indexes were expected to be needed. They are
--    not. The existing single-column indexes already serve the ordered scan and
--    PostgreSQL adds a cheap Incremental Sort for the id tie-break:
--
--      Limit -> Incremental Sort (Presorted Key: lower(full_name))
--                 -> Index Scan using idx_prospect_index_full_name_lower
--
--    Building (lower(full_name), id) and its three siblings would add write cost
--    to every import to save ~0.1 ms on a query that already costs 0.14 ms.
--    Not built. Section 6.7's rule -- record the reason -- rather than a silent skip.
--
-- The count becomes bounded, matching the company listing exactly: scan to
-- 50,001, report least(count, 50000), and set total_capped so the UI says
-- "50,000+" instead of presenting a bounded number as an exact one. The wholly
-- unfiltered total keeps its planner estimate; that branch is unchanged.
--
--   capped count scan ... 4,308 buffers, 31.7 ms
--
-- Hydration is deliberately left alone. The plan asks not to read all_data
-- unless a visible custom column needs it; measured, that is not worth a
-- parameter through three layers:
--
--   all_data per row .... p50 262 B, p95 383 B, p99 634 B, max 1,934 B
--   prospect_index ...... heap 1,332 MB, indexes 563 MB, TOAST 10 MB
--   50-row page ......... 270 buffers with all_data, 266 without
--
-- It is inline, never TOASTed in practice, and costs four buffers a page.
--
-- The return type gains total_capped, so this is DROP and CREATE rather than
-- CREATE OR REPLACE. Both run inside one transaction, so a concurrent caller
-- waits briefly and then sees the new definition -- it never sees no function.
-- The API reads result columns by name and ignores ones it does not know, so the
-- build serving traffic while this migration runs is unaffected.
--
-- Ordering within ties changes: the tie-break is now id alone, where it was
-- (created_at desc, id). Both are total orders and both are stable; id alone is
-- what a keyset cursor can carry. Which rows match is untouched.

begin;

DROP FUNCTION IF EXISTS public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean);

CREATE FUNCTION public.search_prospect_workspace_v12(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true)
 RETURNS TABLE(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '20s'
AS $function$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  -- Mirrors the clamp inside company_scope_ids_v2, so "did the scope hit its
  -- ceiling" is answered against the same number the scope actually used.
  v_scope_limit integer := case
    when coalesce(v_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((v_scope->>'limit')::bigint, 250000))::integer
    else 250000
  end;
  v_has_people boolean := (btrim(v_search) <> '' or v_filters <> '[]'::jsonb);
  v_unscoped boolean := (not v_has_people and p_client_id is null and not v_has_scope);
  v_prefilter text;
  v_match_clause text;
  v_complete text;
  v_scope_cte text;
  v_scope_join text;
  v_capped_expr text;
  v_sort_expr text;
  v_sort_dir text;
  v_sort_nulls text;
  v_order text;
  v_count_cte text;
  v_total_expr text;
  v_total_capped_expr text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  -- One past the number shown, so "is there more" is answered by the same scan
  -- that produces the number. Identical to the company listing.
  v_count_cap constant integer := 50001;
  v_sql text;
begin
  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
    v_capped_expr := format('((select count(*) from eligible_companies) >= %s)', v_scope_limit::text);
  else
    v_scope_cte := '';
    v_scope_join := '';
    v_capped_expr := 'false';
  end if;

  -- Static, allow-listed sort. p_sort and p_direction never reach the SQL as
  -- text; they choose a branch, and the branch is a constant. An unknown sort
  -- falls to created_at, which is what the previous CASE chain did too.
  v_sort_dir := case when lower(coalesce(p_direction, 'desc')) = 'asc' then 'asc' else 'desc' end;
  case coalesce(p_sort, 'created_at')
    when 'name' then
      v_sort_expr := 'lower(pi.full_name)';
      v_sort_nulls := '';
    when 'company' then
      v_sort_expr := 'lower(pi.company_name)';
      v_sort_nulls := '';
    when 'title' then
      v_sort_expr := 'lower(pi.title)';
      v_sort_nulls := '';
    when 'last_contacted' then
      v_sort_expr := 'pi.last_contacted_at';
      -- Matches idx_prospect_index_last_contacted (DESC NULLS LAST) forwards,
      -- and its exact reverse backwards, so both directions are index-served.
      v_sort_nulls := case when v_sort_dir = 'asc' then ' nulls first' else ' nulls last' end;
    else
      v_sort_expr := 'pi.created_at';
      v_sort_nulls := '';
  end case;
  v_order := format('%s %s%s, pi.id', v_sort_expr, v_sort_dir, v_sort_nulls);

  -- The count is its own scan with its own LIMIT. It is not the page's scan
  -- reused, because a set that has been built cannot be short-circuited.
  if not p_with_total then
    v_count_cte := '';
    v_total_expr := 'null::bigint';
    v_total_capped_expr := 'false';
  elsif v_unscoped then
    -- The whole-database total: PostgreSQL's maintained estimate, so no page
    -- load counts 674,804 rows to say so.
    v_count_cte := '';
    v_total_expr := $t$(
      select pg_class.reltuples::bigint
      from pg_class
      join pg_namespace on pg_namespace.oid = pg_class.relnamespace
      where pg_namespace.nspname = 'public' and pg_class.relname = 'prospect_index'
    )$t$;
    v_total_capped_expr := 'false';
  else
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows from (
        select 1 from public.prospect_index pi%s
        where (%L is null or pi.client_ids @> array[%L]) and (%s)
        limit %s
      ) capped
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause, v_count_cap::text);
    v_total_expr := format('(select least(counted.matched_rows, %s) from counted)', (v_count_cap - 1)::text);
    v_total_capped_expr := format('(select counted.matched_rows > %s from counted)', (v_count_cap - 1)::text);
  end if;

  v_sql := format($q$
    with %1$s%2$sordered as (
      select pi.id, %3$s as sort_key
      from public.prospect_index pi%4$s
      where (%5$L is null or pi.client_ids @> array[%5$L]) and (%6$s)
      order by %7$s
      limit %8$s offset %9$s
    ), page as (
      select ordered.id,
        row_number() over (order by ordered.sort_key %10$s%11$s, ordered.id) as page_order
      from ordered
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %5$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      %12$s,
      %13$s,
      %14$s
  $q$, v_scope_cte, v_count_cte, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_order, v_limit::text, v_offset::text, v_sort_dir, v_sort_nulls,
       v_total_expr, v_capped_expr, v_total_capped_expr);

  return query execute v_sql;
end;
$function$;

-- DROP took the grants with it; restore exactly what 20260902000020 left.
revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;

commit;
