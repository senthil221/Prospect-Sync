-- Make both Companies tabs fast instead of merely not-failing.
--
-- 20260829030000 stopped the unfiltered listings calling a per-row filter that
-- could not exclude anything. That took them from a 120s timeout to ~4.6s. This
-- goes after the ~4.6s, and after the one path that was still timing out.
--
-- Measured against production (418,151 companies, 674,804 prospect_index rows,
-- a client with 150,352 companies), warm, three runs each:
--
--                             before          after
--   master, unfiltered        4.7 s           0.59 s
--   master, filtered          135 ms          62 ms
--   client, unfiltered        4.0 s (13.2 s   1.7 s
--                             on a cold cache)
--   client, filtered          > 90 s TIMEOUT  63 ms
--   client, text search       -               87 ms
--   client, + people scope    timeout         2.9 s
--
-- Three separate causes, each fixed with the shape that actually suits it:
--
-- 1. The master listing recomputed prospect_count and client_count with a lateral
--    per company -- 418,151 index lookups to derive numbers a trigger already
--    maintains on companies.prospect_count / companies.client_count. Sampling
--    3,000 companies, stored and recomputed values matched exactly, every row.
--    Unscoped listings now read the stored columns. A client-scoped listing needs
--    a different number (prospects of THIS client) that the global columns cannot
--    answer, so it keeps computing -- but set-based.
--
-- 2. The client listing had the same lateral-per-row shape. Unfiltered, that is
--    150,352 lookups at ~0.016ms: individually fast, 2.4s in aggregate. One hash
--    aggregate over the same index replaces it. Filtered, the opposite is true --
--    the page is small and an aggregate would compute counts for the whole client
--    to discard nearly all of them -- so the lateral is kept there. The function
--    picks the shape per call.
--
-- 3. client_company_workspace_v2 never applied company_prefilter_sql. That is why
--    a filtered client listing ran past 90s while the same filter on the master
--    listing took 135ms: without an index-usable predicate to narrow first, every
--    one of the client's companies reached company_matches_filters_v1. It now
--    prefilters exactly as filter_companies_v4 does. Same 51 rows, 63ms.
--
-- Also: count(*) replaces count(distinct pi.id). prospect_index.id is unique, so
-- they are identical and the sort behind distinct was pure cost.
--
-- Both functions are the definitions currently live in production, restructured;
-- no unrelated recent change to their bodies is rolled back.

begin;

CREATE OR REPLACE FUNCTION public.filter_companies_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '20s'
AS $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_counts_cte text;
  v_agg_select text;
  v_sql text;
begin
  if btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb then
    -- Unfiltered listing: every row matches, so do not emit the row function.
    v_match_clause := 'true';
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  -- The counts used to come from a lateral evaluated once per company. On the
  -- master listing that is 418,151 index lookups to recompute numbers a trigger
  -- already maintains on companies.prospect_count / companies.client_count;
  -- measured over a 3,000-company sample the stored values matched the
  -- recomputed ones exactly, and reading them is ~276ms against ~4.7s.
  --
  -- A client-scoped listing genuinely needs a different number -- prospects of
  -- THIS client -- which the global columns cannot answer. There the lateral
  -- becomes one hash aggregate over the same index instead of one lookup per row.
  if p_client_id is null then
    v_counts_cte := '';
    v_agg_select := 'select b.id, b.name, b.domain, b.created_at, b.prospect_count, b.client_count from base b';
  else
    v_counts_cte := format($c$client_counts as (
        select pi.company_id,
          count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) cid on true
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), $c$, p_client_id);
    v_agg_select := 'select b.id, b.name, b.domain, b.created_at,'
      || ' coalesce(k.prospect_count, 0) as prospect_count,'
      || ' coalesce(k.client_count, 0) as client_count'
      || ' from base b left join client_counts k on k.company_id = b.id';
  end if;

  v_sql := format($q$
    with base as (
      select c.id, c.name, c.domain, c.created_at, c.prospect_count, c.client_count
      from public.companies c
      where (%1$s)
        and (%2$L is null or exists (select 1 from public.prospect_index scoped where scoped.company_id = c.id and scoped.client_ids @> array[%2$L]))
        and (%3$L::jsonb is null or c.id in (select company_id from public.people_scope_company_ids_v1(%2$L, %3$L::jsonb)))
    ), %6$s agg as (
      %7$s
    ), counted as (
      select count(*)::integer as total_count,
        count(*) filter (where prospect_count > 0)::integer as covered_count,
        coalesce(sum(prospect_count), 0)::integer as prospect_total
      from agg
    ), page as (
      select id, name, domain, created_at, prospect_count, client_count
      from agg order by prospect_count desc, lower(name), id
      offset %4$s limit %5$s
    )
    select coalesce((select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id) from page), '[]'::jsonb),
      counted.total_count, counted.covered_count, counted.prospect_total
    from counted
  $q$, v_match_clause, p_client_id,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_agg_select);

  return query execute v_sql;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '20s'
AS $function$
declare
  -- Two shapes, because the fast plan is the opposite one in each case.
  --
  -- Unfiltered, the whole client is in scope (150,352 companies here), and a
  -- lateral per row plans as one index lookup per company -- 0.016ms each but
  -- 2.4s in total. One hash aggregate over the same index does it in a pass.
  --
  -- Filtered, the page is small, so the aggregate would compute counts for the
  -- entire client to then throw nearly all of them away. There the lateral wins,
  -- provided the filter narrows the set first -- which is what the prefilter is
  -- for. Without it this function called company_matches_filters_v1 once per
  -- company, which is why a filtered client listing used to run past 90s.
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counts_cte text;
  v_counts_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_sql text;
begin
  if v_unfiltered then
    v_match_clause := 'true';
    v_counts_cte := format($c$client_counts as (
        select pi.company_id, count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), coverage_counts as (
        select cc.company_id, count(*)::integer as client_count
        from public.client_companies cc
        group by cc.company_id
      ), $c$, p_client_id);
    v_counts_join := 'left join client_counts counts on counts.company_id = c.id'
      || ' left join coverage_counts coverage on coverage.company_id = c.id';
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
    v_counts_cte := '';
    v_counts_join := format($j$left join lateral (
        select count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id = c.id and pi.client_ids @> array[%L]
      ) counts on true
      left join lateral (
        select count(*)::integer as client_count
        from public.client_companies all_memberships
        where all_memberships.company_id = c.id
      ) coverage on true$j$, p_client_id);
  end if;

  -- count(*) rather than count(distinct pi.id): prospect_index.id is unique, so
  -- the two are identical and the sort behind distinct is pure cost.
  v_sql := format($q$
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
    )
    select coalesce((select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id) from page_rows), '[]'::jsonb),
      (select count(*) from matched),
      (select count(*) from matched where matched.prospect_count > 0),
      (select coalesce(sum(matched.prospect_count), 0) from matched)
  $q$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join);

  return query execute v_sql;
end;
$function$
;

revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;

grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;

commit;
