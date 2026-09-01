-- Two fixes the pg_stat_statements window and the scope audit both pointed at.
--
-- 1. The Companies tab's "Total linked prospects" card
--
-- The route counted through public.prospect_summaries, which is a live
-- aggregating view: it joins list_memberships, lists and clients, and computes
-- count(DISTINCT ...) and array_agg(DISTINCT ...) per prospect. Counting rows
-- through it re-runs that whole aggregation for all 674,804 prospects, to
-- produce a single number. Measured here:
--
--   select count(*) from prospect_summaries where company_id is not null  26,131 ms
--   select count(*) from prospect_index    where company_id is not null      321 ms
--
-- pg_stat_statements had it at 10,685 ms mean over 9 calls warm, and it is on
-- every unfiltered Companies page load. prospect_index is the denormalized
-- materialization of that view and is what every other read path already uses;
-- this one query was still going to the view. Same answer, both 674,793.
--
-- 2. A company scope that hits its cap now says so
--
-- company_scope_ids_v2 caps at 250,000 companies. Before 20260901000010 an
-- unfiltered "See People" silently truncated to that cap and lost 151,465
-- prospects. That case no longer joins at all, but a scope that genuinely
-- restricts and still matches more than the cap would truncate just as silently.
-- Return the flag so the UI can say the scope was capped, exactly as
-- total_capped already does for company listings (20260831200000).
--
-- DROP and CREATE for v12 rather than CREATE OR REPLACE, because the return type
-- gains a column. Verified first, the same way 20260831200000 did: no other
-- function references search_prospect_workspace_v12, and the API reads result
-- columns by name, so the extra column is backward compatible with the build
-- serving traffic while this migration runs.

begin;

-- 1. Linked-prospect total, off the index rather than the aggregating view.
CREATE OR REPLACE FUNCTION public.linked_prospect_total_v1(p_search text DEFAULT ''::text)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select count(*)::bigint
  from public.prospect_index pi
  where pi.company_id is not null
    and (
      btrim(coalesce(p_search, '')) = ''
      or pi.company_name ilike '%' || btrim(p_search) || '%'
      or pi.company_domain ilike '%' || btrim(p_search) || '%'
    );
$function$;

-- 2. search_prospect_workspace_v12 gains scope_capped.
DROP FUNCTION IF EXISTS public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean);

CREATE FUNCTION public.search_prospect_workspace_v12(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true)
 RETURNS TABLE(result_rows jsonb, total_count bigint, scope_capped boolean)
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
  v_scope_cte text;
  v_scope_join text;
  v_capped_expr text;
  v_order text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_total_expr text;
  v_sql text;
begin
  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text);
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

  v_order := format($o$
    case when %1$L = 'name' and lower(%2$L) = 'asc' then lower(full_name) end asc,
    case when %1$L = 'name' and lower(%2$L) = 'desc' then lower(full_name) end desc,
    case when %1$L = 'company' and lower(%2$L) = 'asc' then lower(company_name) end asc,
    case when %1$L = 'company' and lower(%2$L) = 'desc' then lower(company_name) end desc,
    case when %1$L = 'title' and lower(%2$L) = 'asc' then lower(title) end asc,
    case when %1$L = 'title' and lower(%2$L) = 'desc' then lower(title) end desc,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'asc' then last_contacted_at end asc nulls first,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'desc' then last_contacted_at end desc nulls last,
    case when %1$L = 'created_at' and lower(%2$L) = 'asc' then created_at end asc,
    created_at desc, id
  $o$, p_sort, p_direction);

  if not p_with_total then
    v_total_expr := 'null::bigint';
  elsif v_unscoped then
    v_total_expr := $t$(
      select pg_class.reltuples::bigint
      from pg_class
      join pg_namespace on pg_namespace.oid = pg_class.relnamespace
      where pg_namespace.nspname = 'public' and pg_class.relname = 'prospect_index'
    )$t$;
  else
    v_total_expr := '(select count(*) from matched)';
  end if;

  v_sql := format($q$
    with %1$s matched as materialized (
      select pi.id, pi.created_at, pi.full_name, pi.company_name, pi.title, pi.last_contacted_at
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched order by %5$s limit %6$s offset %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by %5$s) as page_order from ordered_page
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %3$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      %8$s,
      %9$s
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause, v_order,
       v_limit::text, v_offset::text, v_total_expr, v_capped_expr);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.linked_prospect_total_v1(text) from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) from public, anon, authenticated;

grant execute on function public.linked_prospect_total_v1(text) to service_role;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;

commit;
