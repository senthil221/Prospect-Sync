-- Stop saying "50,000+" about people. Count them.
--
-- The Company DB stopped capping its counts in 20260902000200, and that
-- migration had to earn it: an exact count of 419,214 companies costs between
-- 2.3 s and 37 s depending on which of two plan shapes runs, so it needed a
-- sampler to choose the shape and a version cache to pay for it once. None of
-- that reasoning transfers here, and measuring rather than assuming it does is
-- the whole point of this migration.
--
-- People are not companies. The company predicate is a chain of ILIKEs over
-- name, keywords and short_description; the people predicate runs against
-- prospect_index, one denormalized table with company_id indexed. Measured on
-- production 2026-09-04, 681,085 rows, capped against exact:
--
--   what is counted                          matches    capped    exact
--   the whole People DB                      681,085     (est.)   0.18 s
--   pivot: every company, 250,000 ceiling    527,248    0.15 s    0.48 s
--   pivot: 10 company keywords               358,001    0.12 s    0.43 s
--   pivot: 1 company keyword                  62,084    0.19 s    0.33 s
--   title contains "manager"                 287,985    0.30 s    1.25 s
--
-- So exactness costs between 0.15 s and 0.95 s against a 10 s ceiling. There is
-- no plan chooser here and no sampler, because there is no crossover to find.
--
-- WHAT THE CAP WAS ACTUALLY HIDING. The expensive half of a pivot is resolving
-- the company scope, and it is paid whether the count stops at 50,000 or not.
-- The same 10-keyword pivot measured end to end through the RPC: 5.98 s, of
-- which 5.96 s is company_scope_ids_v2 and 0.12 s is the count. Capping the
-- count was never what made that query affordable, so uncapping it is not what
-- will make it unaffordable -- it moves 5.98 s to about 6.4 s. The scope
-- resolution is the thing to fix, and it is not fixed here.
--
-- THE WHOLE-DATABASE TOTAL WAS NEVER CORRECT. It came from pg_class.reltuples,
-- which read 681,304 against a true 681,085 -- 219 people that do not exist,
-- drifting with autovacuum, and impossible to reconcile against an export of
-- the same set. count(*) over prospect_index is an index-only scan measured at
-- 175-234 ms, and 20260902000070's version cache means a page load only pays it
-- when prospects have actually changed since the caller's cached answer.
--
-- WHAT THIS COSTS IF IT IS WRONG. A count that now scans instead of stopping
-- can only fail by exceeding the function's own 10 s statement_timeout, which
-- returns the existing "took longer than the database allows" message rather
-- than hanging. The measurements above leave an order of magnitude of headroom
-- on every shape, and total_capped stays in the result type so the capped
-- branches on both sides of the wire remain if that judgement is ever wrong.

begin;

CREATE OR REPLACE FUNCTION public.search_prospect_workspace_v12(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true, p_known_versions jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean, data_versions jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '10s'
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
  -- The dependency-version vector this answer is valid at, and whether the
  -- caller's cached total was computed at the same one.
  v_versions jsonb;
  v_want_total boolean;
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

  -- Which entity versions this query actually reads. A People query depends on
  -- the prospect version; one carrying a company scope reads public.companies
  -- through company_scope_ids_v2 and depends on the company version too. A
  -- single-entity query never carries a version it does not read, so a company
  -- import cannot invalidate every People count for no reason.
  v_versions := public.data_versions_v1(
    case when v_has_scope then array['prospect', 'company'] else array['prospect'] end);

  -- The caller caches a total against the vector it was counted at. If any
  -- component has moved since, that total is stale and this call recounts
  -- whether or not it was asked to -- so a completed mutation cannot leave a
  -- stale count on screen waiting for some later page load to notice.
  v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;

  -- The count is still its own scan rather than the page's, but it no longer
  -- carries a LIMIT: the number on screen is the number of matching rows.
  if not v_want_total then
    v_count_cte := '';
    v_total_expr := 'null::bigint';
    v_total_capped_expr := 'false';
  elsif v_unscoped then
    -- The whole-database total, counted rather than estimated. reltuples read
    -- 681,304 against a true 681,085 on the day this was written: 219 people
    -- the header invented, and a number that could never be reconciled against
    -- an export. Counting it is an index-only scan of one column -- 175-234 ms
    -- warm against a 10 s ceiling, behind a version cache that skips it
    -- entirely until prospects actually move.
    v_count_cte := '';
    v_total_expr := '(select count(*)::bigint from public.prospect_index)';
    v_total_capped_expr := 'false';
  else
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows
      from public.prospect_index pi%s
      where (%L is null or pi.client_ids @> array[%L]) and (%s)
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause);
    v_total_expr := '(select counted.matched_rows from counted)';
    -- Retained in the result type, and permanently false. The column is what
    -- the API and the grid read to decide whether to print a "+", so dropping
    -- it would be a wire change for no gain; and if a cap ever has to come
    -- back, the branches that honour it are still there on both sides.
    v_total_capped_expr := 'false';
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
      %14$s,
      %15$L::jsonb
  $q$, v_scope_cte, v_count_cte, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_order, v_limit::text, v_offset::text, v_sort_dir, v_sort_nulls,
       v_total_expr, v_capped_expr, v_total_capped_expr, v_versions::text);

  return query execute v_sql;
end;
$function$;
revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb) to service_role;

-- Assert against real rows, not against the DDL compiling. Every claim above is
-- checked here, and the migration refuses to commit if one of them is false.
do $assert$
declare
  v_problems text[] := array[]::text[];
  v_true bigint;
  v_total bigint;
  v_capped boolean;
  v_rows jsonb;
begin
  select count(*) into v_true from public.prospect_index;

  -- 1. The unfiltered total is the real row count, not an estimate.
  select total_count, total_capped into v_total, v_capped
  from public.search_prospect_workspace_v12('', '[]'::jsonb, 'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null);
  if v_total is distinct from v_true then
    v_problems := array_append(v_problems, format('unscoped total %s <> actual %s', v_total, v_true));
  end if;
  if v_capped then
    v_problems := array_append(v_problems, 'unscoped total still reports itself capped');
  end if;

  -- 2. A match set larger than the old cap now reports its real size. Anything
  --    landing on exactly 50,000 means the LIMIT survived somewhere.
  select total_count, total_capped, result_rows into v_total, v_capped, v_rows
  from public.search_prospect_workspace_v12(
    '', '[{"id":"assert","field":"__title","operator":"not_empty","values":[]}]'::jsonb,
    'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null);
  if v_total = 50000 or v_capped then
    v_problems := array_append(v_problems, format('filtered total still capped: %s (capped=%s)', v_total, v_capped));
  end if;
  if v_total <= 0 then
    v_problems := array_append(v_problems, format('filtered total is not a count: %s', v_total));
  end if;

  -- 3. The page itself still comes back. A count rewrite that quietly emptied
  --    result_rows would pass both checks above.
  if jsonb_array_length(coalesce(v_rows, '[]'::jsonb)) = 0 then
    v_problems := array_append(v_problems, 'the page returned no rows alongside a non-zero total');
  end if;

  if cardinality(v_problems) > 0 then
    raise exception 'search_prospect_workspace_v12 assertions failed: %', array_to_string(v_problems, '; ');
  end if;
  raise notice 'search_prospect_workspace_v12: exact counts verified against % rows', v_true;
end;
$assert$;

commit;
