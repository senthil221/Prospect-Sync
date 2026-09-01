-- Read the stored client_count instead of recomputing it per listing.
--
-- 20260815010000 denormalized companies.prospect_count and client_count onto the
-- table, maintained by a statement-level trigger on prospect_index, precisely so
-- listings would stop aggregating them live. company_summaries honours that.
-- client_company_workspace_v2 did not: it recomputed client_count on both of its
-- paths, two different ways.
--
--   unfiltered: a coverage_counts CTE aggregating the whole client_companies table
--   filtered:   a per-row lateral, count(*) from client_companies per company
--
-- The stored column is not an approximation of that aggregate, it is equal to it.
-- Checked before relying on it:
--
--   select count(*) from companies c
--   left join (select company_id, count(*)::integer n from client_companies
--              group by company_id) agg on agg.company_id = c.id
--   where c.client_count is distinct from coalesce(agg.n, 0);
--   -> 0 of 418,151
--
-- Measured on the largest client (Unassigned, 150,352 companies), warm, with
-- identical results on both shapes every time:
--
--   unfiltered client tab ...................... 1,718 ms -> 1,457 ms
--   filtered, 51 matching companies ................ 82 ms ->     6 ms
--   filtered, 118,172 matching companies ........ 6,126 ms -> 2,378 ms
--
-- The small-match case improves most in relative terms because the lateral runs
-- as a nested loop there; at 118k the planner picks a better strategy on its own,
-- so the gain settles at ~2.6x rather than growing. Nothing here was timing out.
--
-- What this does not fix: the per-client prospect count, which is the larger
-- remaining cost (~949 ms on this client). That one is genuinely client-scoped
-- and companies.prospect_count is global, so it cannot come from an existing
-- column. Storing a per-(client, company) count on client_companies, maintained
-- by the trigger that already keeps companies.prospect_count fresh, is the
-- structural fix if this tab ever needs to be faster than ~1.5s.
--
-- Only the two client_count sources change; the rest is the definition currently
-- live in production.

begin;

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
    -- Only the per-client prospect count still has to be computed; client_count
    -- comes off companies, where the trigger keeps it current.
    v_counts_cte := format($counts$client_counts as (
        select pi.company_id, count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), $counts$, p_client_id);
    v_counts_join := 'left join client_counts counts on counts.company_id = c.id';
  else
    v_match_clause := coalesce(v_complete,
      case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
        || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text));
    v_counts_cte := '';
    v_counts_join := format($joins$left join lateral (
        select count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id = c.id and pi.client_ids @> array[%L]
      ) counts on true$joins$, p_client_id);
  end if;

  -- Cap only when something narrows the set. An unfiltered client listing is the
  -- headline count and has to stay exact.
  v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all' else '50001' end;

  v_sql := format($query$
    with %6$s matched as materialized (
      select c.id, c.name, c.domain, c.created_at,
        coalesce(counts.prospect_count, 0)::integer as prospect_count,
        c.client_count
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
$function$;

revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;

commit;
