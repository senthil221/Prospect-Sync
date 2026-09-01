-- Use the complete-SQL translation in the People workspace and export too.
--
-- 20260902000000 added prospect_filter_sql_v1 and wired it into
-- people_scope_company_ids_v1, which was the reported failure. The two functions
-- that serve the People tab itself were left calling prospect_index_matches_v1
-- once per candidate row, so the same cost stayed in the everyday path.
--
-- Found by measuring, not by reading: a plain title filter on the People tab was
-- taking 38 seconds. Isolated, the two forms of the same predicate over the
-- 286,355 rows it matches:
--
--   prefilter + prospect_index_matches_v1 .... 35,444 ms
--   prefilter + the complete SQL .............     553 ms
--
-- Identical counts, 64x apart.
--
-- Same contract as before: prospect_filter_sql_v1 returns null for shapes it
-- cannot express exactly -- today only Boolean -- and both callers keep the row
-- function as the fallback, so a coverage gap costs speed and never correctness.
-- The translation was proved equivalent row by row across 30 filter shapes in
-- 20260902000000 before it was used anywhere.
--
-- Both bodies are the definitions currently live with only that substitution.

begin;

CREATE OR REPLACE FUNCTION public.search_prospect_workspace_v12(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true)
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
  v_complete text;
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
$function$

;
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
  v_complete text := public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_scope_cte text;
  v_scope_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text)) || ')';
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
$function$

;

revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.search_prospect_export_v4(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;
grant execute on function public.search_prospect_export_v4(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean) to service_role;

commit;
