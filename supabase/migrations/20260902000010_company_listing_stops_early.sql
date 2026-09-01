-- Let the company listing stop early instead of building every match first.
--
-- Reported as a statement timeout when several company keywords are combined
-- with the description scope switched on.
--
-- The cap added in 20260831200000 was meant to stop the count walking an
-- unbounded match set, and its own note records the page being 23ms while
-- counting everything was the rest of the request. The cap did not take effect,
-- because of the query's shape rather than the cap itself:
--
--   with base as (...), agg as (select ... from base),
--        capped as (select * from agg limit 50001),
--        page   as (select ... from agg order by ... limit 50)
--
-- agg is referenced twice, so PostgreSQL materialises it -- and materialising it
-- means running the predicate over every company and building the whole match set
-- before either LIMIT can apply. A cap cannot short-circuit a set that has
-- already been built.
--
-- The predicate itself is not the problem and no index can help it. Six common
-- keywords across name and description match 279,292 of 418,151 companies, so a
-- sequential scan is the correct plan; the planner picks it deliberately. The
-- cost was in scanning all of them twice over rather than stopping at 50 rows for
-- the page and 50,001 for the count.
--
-- Written as two independent scans, each with its own LIMIT, both stop early.
-- Measured on the reported filter, identical results (50,000 total, 50 rows):
--
--   one materialised match set, referenced twice ....... 4,790 ms
--   independent, early-terminating count and page ......   713 ms
--
-- A tsvector side table was considered first, since 20260831230000 recommends one
-- after the inline column had to be reverted. It would not have helped here: at
-- 67% selectivity a GIN index is worse than the sequential scan, and matching
-- lexemes rather than substrings would quietly change which companies match --
-- '%HR%' currently matches "CHRIS". That remains the right shape for Boolean
-- search, which is a different feature, and stays unbuilt rather than built for
-- the wrong reason.
--
-- Two references are kept deliberate rather than accidental: client_counts is an
-- aggregate worth computing once, and scope_ids materialises only company ids so
-- people_scope_company_ids_v1 runs once rather than once per scan. Neither
-- carries the match set.

begin;

CREATE OR REPLACE FUNCTION public.filter_companies_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer, total_capped boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_count_cap text;
  v_ctes text[] := array[]::text[];
  v_cte_sql text;
  v_join text;
  v_prospect_expr text;
  v_client_expr text;
  v_where text;
  v_complete text;
  v_sql text;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  -- Per-client counts are an aggregate, not a match set: computing it once and
  -- joining it from both scans is exactly what a shared CTE is for.
  if p_client_id is null then
    v_join := '';
    v_prospect_expr := 'c.prospect_count';
    v_client_expr := 'c.client_count';
  else
    v_ctes := array_append(v_ctes, format($counts$client_counts as (
        select pi.company_id,
          count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) cid on true
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      )$counts$, p_client_id));
    v_join := ' left join client_counts k on k.company_id = c.id';
    v_prospect_expr := 'coalesce(k.prospect_count, 0)';
    v_client_expr := 'coalesce(k.client_count, 0)';
  end if;

  v_where := format('(%s)', v_match_clause);
  if p_client_id is not null then
    v_where := v_where || format($e$ and exists (
      select 1 from public.prospect_index scoped
      where scoped.company_id = c.id and scoped.client_ids @> array[%L]
    )$e$, p_client_id);
  end if;
  if p_people_scope is not null then
    -- Only the ids are materialised, so the scope function runs once for both
    -- scans without carrying any of the match set with it.
    v_ctes := array_append(v_ctes, format($s$scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(%L, %L::jsonb)
      )$s$, p_client_id, p_people_scope::text));
    v_where := v_where || ' and c.id in (select company_id from scope_ids)';
  end if;

  -- Cap only when something narrows the set. An unfiltered listing is the
  -- headline 'how many companies do I have' number, it has to stay exact, and it
  -- is cheap anyway because nothing has to be re-checked per row.
  v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all' else '50001' end;

  v_cte_sql := case when cardinality(v_ctes) > 0
    then array_to_string(v_ctes, ', ') || ', ' else '' end;

  -- page and capped each read public.companies directly and carry their own
  -- LIMIT, so neither is referenced twice and neither forces the other to build
  -- the whole match set first.
  v_sql := format($query$
    with %1$s page as (
      select c.id, c.name, c.domain, c.created_at,
        %2$s as prospect_count, %3$s as client_count
      from public.companies c%4$s
      where %5$s
      order by %2$s desc, lower(c.name), c.id
      offset %6$s limit %7$s
    ), capped as (
      select %2$s as prospect_count
      from public.companies c%4$s
      where %5$s
      limit %8$s
    ), counted as (
      select case when %8$L = 'all' then count(*) else least(count(*), 50000) end::integer as total_count,
        (count(*) > 50000 and %8$L <> 'all') as total_capped,
        count(*) filter (where prospect_count > 0)::integer as covered_count,
        coalesce(sum(prospect_count), 0)::integer as prospect_total
      from capped
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id)
        from page
      ), '[]'::jsonb),
      counted.total_count, counted.covered_count, counted.prospect_total, counted.total_capped
    from counted
  $query$, v_cte_sql, v_prospect_expr, v_client_expr, v_join, v_where,
       v_offset::text, v_limit::text, v_count_cap);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;

commit;
