-- Only join the company scope when the scope actually restricts something.
--
-- "See People" always sends a scope, even when nothing is filtered:
--
--   {"limit": 250000, "search": "", "filters": []}
--
-- search_prospect_workspace_v12 already knew how to skip the join, but decided
-- with `v_scope <> '{}'::jsonb` -- which that payload passes. So an unfiltered
-- navigation joined against company_scope_ids_v2, whose generated SQL is:
--
--   select c.id from public.companies c
--   where public.company_matches_filters_v1(c, '', '[]'::jsonb)
--   order by c.id limit 250000;
--
-- company_matches_filters_v1 takes a whole companies row and carries a SET
-- clause, so the planner cannot inline it: 418,151 calls at ~250us each, to
-- answer a question with no filters in it. Measured on the live database:
--
--   company_scope_ids_v2, empty scope ......... 93,076 ms
--   People list, page 1, after See People ..... 97,967 ms
--   prospect export, same scope ............... 87,537 ms
--   the same pages with no scope .............. 1,422 ms
--
-- The Postgres log carries the cancellations, at company_scope_ids_v2 line 17.
--
-- It was also losing rows. The 250,000-company cap is smaller than the 418,151
-- companies that exist, so every prospect belonging to the other 168,151 vanished
-- from the list and from exports with no error:
--
--   674,804 prospects total
--   523,339 reachable through the capped scope
--   151,465 silently invisible (22.4%), of which only 11 have no company at all
--
-- An absent or unfiltered scope means "do not restrict", not "the first 250,000
-- companies by id". Deciding on whether the scope carries a search or filters
-- fixes the timeout and the missing rows together: the join disappears instead of
-- running against a truncated list.
--
-- Three changes, all narrow:
--   1. v12   - v_has_scope now tests whether the scope restricts, not whether the
--              payload is non-empty. Everything downstream already branches on it.
--   2. v4    - gains the same branch; it always joined unconditionally.
--   3. v2    - gains the guard its four siblings received in 20260829030000, so
--              the superseded workspace/export versions still reachable through
--              PostgREST cannot cost 93 seconds either.
--
-- Both bodies below are the definitions currently live in production with only
-- those changes applied.

begin;

-- 1. Defence in depth: an unfiltered scope must never call the per-row predicate.
CREATE OR REPLACE FUNCTION public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb)
 RETURNS TABLE(company_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '15s'
AS $function$
declare
  v_search text := coalesce(p_company_scope->>'search', '');
  v_filters jsonb := coalesce(p_company_scope->'filters', '[]'::jsonb);
  v_prefilter text := public.company_prefilter_sql(v_search, v_filters);
  v_limit integer := case
    when coalesce(p_company_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((p_company_scope->>'limit')::bigint, 250000))::integer
    else 250000
  end;
  v_sql text := 'select c.id from public.companies c where ';
begin
  -- With an empty search and no filters, company_matches_filters_v1 reduces to
  -- `true and not exists (select from jsonb_array_elements('[]'))` and returns
  -- true for every row. Calling it 418,151 times to learn that costs 93 seconds;
  -- not calling it costs 514 ms for the identical result set.
  if btrim(v_search) = '' and v_filters = '[]'::jsonb then
    return query execute format('select c.id from public.companies c order by c.id limit %s', v_limit);
    return;
  end if;

  v_sql := v_sql
    || case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', v_search, v_filters::text)
    || format(' order by c.id limit %s', v_limit);
  return query execute v_sql;
end;
$function$;

-- 2. The People list: decide on whether the scope restricts, not on whether the
--    payload happens to be a non-empty object.
CREATE OR REPLACE FUNCTION public.search_prospect_workspace_v12(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true)
 RETURNS TABLE(result_rows jsonb, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '20s'
AS $function$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  -- A scope restricts only when it carries a company search or company filters.
  -- "See People" sends {"limit":250000,"search":"","filters":[]} for an unfiltered
  -- navigation, which is not '{}' but restricts nothing.
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  v_has_people boolean := (btrim(v_search) <> '' or v_filters <> '[]'::jsonb);
  v_unscoped boolean := (not v_has_people and p_client_id is null and not v_has_scope);
  v_prefilter text;
  v_match_clause text;
  v_scope_cte text;
  v_scope_join text;
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
  else
    v_scope_cte := '';
    v_scope_join := '';
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
      %8$s
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause, v_order,
       v_limit::text, v_offset::text, v_total_expr);

  return query execute v_sql;
end;
$function$;

-- 3. The export: it always joined, with no branch at all.
CREATE OR REPLACE FUNCTION public.search_prospect_export_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000, p_with_total boolean DEFAULT false)
 RETURNS TABLE(result_rows jsonb, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '60s'
AS $function$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_scope_cte text;
  v_scope_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  else
    v_scope_cte := '';
    v_scope_join := '';
  end if;

  v_sql := format($q$
    with %1$s matched as materialized (
      select pi.id, pi.created_at
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched
      where %5$L::timestamptz is null or (matched.created_at, matched.id) < (%5$L::timestamptz, coalesce(%6$L, ''))
      order by matched.created_at desc, matched.id desc
      limit %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_index pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      case when %8$L then (select count(*) from matched) else null end
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause,
       p_after_created_at, p_after_id, v_limit::text, p_with_total);

  return query execute v_sql;
end;
$function$;

grant execute on function public.company_scope_ids_v2(text, jsonb) to service_role;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;
grant execute on function public.search_prospect_export_v4(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean) to service_role;

commit;
