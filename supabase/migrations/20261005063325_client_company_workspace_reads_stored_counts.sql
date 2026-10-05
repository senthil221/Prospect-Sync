-- Client Company DB already owns an exact, trigger-maintained prospect count on
-- client_companies.  The interactive listing nevertheless rebuilt that count
-- from prospect_index on every request: one whole-client aggregate for the
-- ordinary path, or one lateral count per candidate on filtered paths.  Read
-- the maintained membership fact instead.  This removes prospect_index from
-- the listing plan without changing the filter, row, summary, ordering or cap
-- contracts.
--
-- Production evidence before this migration (2026-10-05), one paired warm run
-- in the same read-only session with identical rows and summaries: the
-- 13,111-company complete view changed from 924.00 ms to 303.46 ms and the
-- 3,914-company Incomplete Info view from 164.17 ms to 72.85 ms.  A first cold
-- complete read still exceeded five seconds, so this is a targeted count-shape
-- fix, not a p95, cold-storage or every-filter claim.

set local lock_timeout = '5s';

create or replace function public.client_company_workspace_v2(
  p_client_id text,
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(
  result_rows jsonb,
  total_count bigint,
  covered_count bigint,
  prospect_count bigint,
  total_capped boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
declare
  -- Coverage is client-relative here.  Remove it before compiling ordinary
  -- company predicates, then apply it to the same stored value the row shows.
  v_coverage text := (
    select value->'values'->>0
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
    where value->>'field' = '__company_coverage'
    limit 1
  );
  -- The route already bound __client_company_scope to p_client_id.  Membership
  -- below is the authoritative origin, so compiling the private predicate again
  -- would only turn an ordinary client page into a filtered query.
  v_filters jsonb := coalesce((
    select jsonb_agg(value)
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
    where value->>'field' not in ('__company_coverage', '__client_company_scope')
  ), '[]'::jsonb);
  v_coverage_clause text := case v_coverage
    when 'with' then 'where matched.prospect_count > 0'
    when 'without' then 'where matched.prospect_count = 0'
    else '' end;
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = ''
    and v_filters = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, v_filters);
  v_match_clause text;
  v_count_cap text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_complete text;
  v_sql text;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, v_filters);

  if v_unfiltered then
    v_match_clause := coalesce(v_complete, 'true');
  else
    v_match_clause := coalesce(v_complete,
      case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
        || format('public.company_matches_filters_v1(c, %L, %L::jsonb)',
          p_search, v_filters::text));
  end if;

  -- The ordinary client headline remains exact.  Narrowed questions retain the
  -- existing 50,000 lower-bound contract and one extra row proves the cap.
  v_count_cap := case
    when v_match_clause = 'true' and p_people_scope is null and v_coverage is null
      then 'all'
    else '50001'
  end;

  v_sql := format($query$
    with matched as materialized (
      select c.id, c.name, c.domain, c.created_at,
        membership.prospect_count,
        c.client_count
      from public.client_companies membership
      join public.companies c on c.id = membership.company_id
      where membership.client_id = %1$L
        and (%2$s)
        and (%3$L::jsonb is null or c.id in (
          select company_id from public.people_scope_company_ids_v1(%1$L, %3$L::jsonb)
        ))
    ), visible as (
      select * from matched %7$s
    ), page_rows as (
      select * from visible
      order by prospect_count desc, lower(name), id
      limit %5$s offset %4$s
    ), capped as (
      select * from visible limit %6$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page_rows)
          order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id)
        from page_rows
      ), '[]'::jsonb),
      (select case when %6$L = 'all' then count(*) else least(count(*), 50000) end from capped),
      (select count(*) from capped where capped.prospect_count > 0),
      (select coalesce(sum(capped.prospect_count), 0) from capped),
      (select (count(*) > 50000 and %6$L <> 'all') from capped)
  $query$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_count_cap, v_coverage_clause);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer)
  from public, anon, authenticated;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer)
  to service_role;

-- Fail closed if a future migration has removed either half of the stored-count
-- authority.  The disposable data fixtures below prove the values across real
-- write paths; this bounded migration assertion protects the definition itself.
do $proof$
declare
  v_listing text := pg_get_functiondef(
    'public.client_company_workspace_v2(text,text,jsonb,jsonb,integer,integer)'::regprocedure);
  v_trigger text := pg_get_functiondef('public.sync_company_counts_statement()'::regprocedure);
begin
  if v_listing not like '%membership.prospect_count%'
     or v_listing like '%from public.prospect_index pi%'
     or v_listing like '%join lateral (%' then
    raise exception 'client_company_workspace_v2 did not keep the stored-count query shape';
  end if;
  if v_trigger not like '%recompute_client_company_counts_bulk(v_ids)%' then
    raise exception 'prospect_index no longer maintains client_companies.prospect_count';
  end if;
  if has_function_privilege('anon',
       'public.client_company_workspace_v2(text,text,jsonb,jsonb,integer,integer)', 'EXECUTE')
     or has_function_privilege('authenticated',
       'public.client_company_workspace_v2(text,text,jsonb,jsonb,integer,integer)', 'EXECUTE')
     or not has_function_privilege('service_role',
       'public.client_company_workspace_v2(text,text,jsonb,jsonb,integer,integer)', 'EXECUTE') then
    raise exception 'client_company_workspace_v2 has unsafe role grants';
  end if;
end;
$proof$;
