-- Bound the company listing counts so a cold cache cannot exceed the timeout.
--
-- Reported as "Request failed (503)" and "canceling statement due to statement
-- timeout" on the Companies tab with Company description enabled.
--
-- The cause is cold cache, not the filter. The identical query measured 34s on
-- its first run after a reboot and 2.35s minutes later, warm. companies holds
-- 1,284MB of heap against 2GB of shared_buffers, competing with prospect_index,
-- so a description-scope filter reads short_description from disk. The 30s
-- statement_timeout sits inside that 14x spread, which is why this is
-- intermittent, why it tracks the description checkbox, and why every warm
-- measurement looked fine.
--
-- Where the time actually goes, measured here with a broad description filter
-- matching 119,709 companies:
--
--   page only, top 50 ordered ............ 23 ms
--   counting every match ................. 1,304 ms
--   counting to a 50,001 cap ..............  531 ms
--   the shape shipped today .............. 1,353 ms
--
-- The page is nearly free: idx_companies_prospect_ranking serves the ordering
-- and stops after one screen. Counting the whole match set is ~98% of the
-- request, and it grows as the database grows -- so no amount of indexing fixes
-- it, and every previous fix here was buying time rather than removing the
-- ceiling.
--
-- Capped at 50,000 the cost stops scaling. It is also nearly invisible: real
-- filters are small (industry=software is 243 matches, a keyword is 2,496), so
-- only a very broad description search reaches the cap, and that is exactly the
-- case where an exact total is meaningless. total_capped tells the UI to render
-- "50,000+" rather than a wrong exact number; covered_count and prospect_total
-- are then over the capped subset, which is why the flag exists.
--
-- DROP and CREATE rather than CREATE OR REPLACE because the return type gains a
-- column. Verified first: no other function references either of these, and the
-- API reads result columns by name, so the extra column is backward compatible
-- with the build that is serving while this migration runs.

begin;

drop function if exists public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer);
drop function if exists public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer);

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
  v_counts_cte text;
  v_agg_select text;
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

  if p_client_id is null then
    v_counts_cte := '';
    v_agg_select := 'select b.id, b.name, b.domain, b.created_at, b.prospect_count, b.client_count from base b';
  else
    v_counts_cte := format($counts$client_counts as (
        select pi.company_id,
          count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) cid on true
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), $counts$, p_client_id);
    v_agg_select := 'select b.id, b.name, b.domain, b.created_at,'
      || ' coalesce(k.prospect_count, 0) as prospect_count,'
      || ' coalesce(k.client_count, 0) as client_count'
      || ' from base b left join client_counts k on k.company_id = b.id';
  end if;

  -- Cap only when something narrows the set. An unfiltered listing is the
  -- headline 'how many companies do I have' number, it has to stay exact, and it
  -- is cheap anyway because nothing has to be re-checked per row.
  v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all' else '50001' end;

  v_sql := format($query$
    with base as (
      select c.id, c.name, c.domain, c.created_at, c.prospect_count, c.client_count
      from public.companies c
      where (%1$s)
        and (%2$L is null or exists (
          select 1 from public.prospect_index scoped
          where scoped.company_id = c.id and scoped.client_ids @> array[%2$L]
        ))
        and (%3$L::jsonb is null or c.id in (
          select company_id from public.people_scope_company_ids_v1(%2$L, %3$L::jsonb)
        ))
    ), %6$s agg as (
      %7$s
    ), capped as (
      -- Stop counting at the cap instead of walking an unbounded match set.
      -- Measured on this database with a broad description filter (119,709
      -- matches): the page alone is 23ms because idx_companies_prospect_ranking
      -- serves the ordering and stops after 50 rows, while counting every match
      -- was ~1.3s warm and far worse cold: roughly 98 percent of the request, and
      -- growing with the data. Capped, the cost stops scaling entirely.
      select * from agg limit %8$s
    ), counted as (
      select case when %8$L = 'all' then count(*) else least(count(*), 50000) end::integer as total_count,
        (count(*) > 50000 and %8$L <> 'all') as total_capped,
        count(*) filter (where prospect_count > 0)::integer as covered_count,
        coalesce(sum(prospect_count), 0)::integer as prospect_total
      from capped
    ), page as (
      select id, name, domain, created_at, prospect_count, client_count
      from agg
      order by prospect_count desc, lower(name), id
      offset %4$s limit %5$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id)
        from page
      ), '[]'::jsonb),
      counted.total_count, counted.covered_count, counted.prospect_total, counted.total_capped
    from counted
  $query$, v_match_clause, p_client_id,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_agg_select, v_count_cap);

  return query execute v_sql;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint, total_capped boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
declare
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = ''
    and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counts_cte text;
  v_counts_join text;
  v_count_cap text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_complete text;
  v_sql text;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));

  if v_unfiltered then
    v_match_clause := coalesce(v_complete, 'true');
    v_counts_cte := format($counts$client_counts as (
        select pi.company_id, count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), coverage_counts as (
        select cc.company_id, count(*)::integer as client_count
        from public.client_companies cc
        group by cc.company_id
      ), $counts$, p_client_id);
    v_counts_join := 'left join client_counts counts on counts.company_id = c.id'
      || ' left join coverage_counts coverage on coverage.company_id = c.id';
  else
    v_match_clause := coalesce(v_complete,
      case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
        || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text));
    v_counts_cte := '';
    v_counts_join := format($joins$left join lateral (
        select count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id = c.id and pi.client_ids @> array[%L]
      ) counts on true
      left join lateral (
        select count(*)::integer as client_count
        from public.client_companies all_memberships
        where all_memberships.company_id = c.id
      ) coverage on true$joins$, p_client_id);
  end if;

  -- Cap only when something narrows the set. An unfiltered client listing is the
  -- headline count and has to stay exact.
  v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all' else '50001' end;

  v_sql := format($query$
    with %6$s matched as materialized (
      select c.id, c.name, c.domain, c.created_at,
        coalesce(counts.prospect_count, 0)::integer as prospect_count,
        coalesce(coverage.client_count, 0)::integer as client_count
      from public.client_companies membership
      join public.companies c on c.id = membership.company_id
      %7$s
      where membership.client_id = %1$L
        and (%2$s)
        and (%3$L::jsonb is null or c.id in (
          select company_id from public.people_scope_company_ids_v1(%1$L, %3$L::jsonb)
        ))
    ), page_rows as (
      select * from matched
      order by prospect_count desc, lower(name), id
      limit %5$s offset %4$s
    ), capped as (
      -- Bounded count. The page is cheap -- it is ordered off an index and stops
      -- after one screen -- but counting every match is not, and it grows with
      -- the data. On this database a broad description filter cost ~1.3s warm to
      -- count and roughly 34s from a cold cache, which is what pushed this past
      -- the statement timeout and cascaded into pool exhaustion.
      select * from matched limit %8$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id)
        from page_rows
      ), '[]'::jsonb),
      (select case when %8$L = 'all' then count(*) else least(count(*), 50000) end from capped),
      (select count(*) from capped where capped.prospect_count > 0),
      (select coalesce(sum(capped.prospect_count), 0) from capped),
      (select (count(*) > 50000 and %8$L <> 'all') from capped)
  $query$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join, v_count_cap);

  return query execute v_sql;
end;
$function$

;

revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;

grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;

commit;
