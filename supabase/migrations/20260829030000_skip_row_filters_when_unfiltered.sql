-- Stop calling the per-row filter functions when there is nothing to filter.
--
-- Both Companies tabs were timing out at PostgREST's 120s ceiling:
--   canceling statement due to statement timeout
--     SQL function "company_matches_filters_v1" statement 1
--     SQL function "client_company_workspace_v2" statement 1
--
-- company_matches_filters_v1(p_row public.companies, ...) and its prospect-side
-- twin prospect_index_matches_v1 take a whole row and carry a SET clause, so the
-- planner cannot inline them. EXPLAIN shows the predicate as a Filter calling the
-- function with a constructed ROW() of all 27 columns, once per candidate row.
-- Measured against the live database, one client with 150,352 companies:
--
--   membership join alone .................................... 555 ms
--   + the two per-row lateral count subqueries ............... 238 ms
--   + company_matches_filters_v1 ............................. > 120 s (cancelled)
--
-- That is ~250us per call, and it is paid even when p_search is '' and p_filters
-- is '[]' -- the case where the function returns true for every row. Neither
-- passing the 14 columns it actually reads instead of the whole row, nor dropping
-- the SET clause to allow inlining, made any difference when measured: the cost is
-- the call itself, not the arguments.
--
-- So do not make the call when it cannot exclude anything. The guard is exactly
-- equivalent -- with an empty search and no filters the function's own body
-- reduces to `true and not exists (select from jsonb_array_elements('[]'))` -- and
-- it takes the client Companies tab from a timeout to 4.4s, verified end to end.
--
-- Filtered listings are unchanged and still pay the per-row cost. The prefilter
-- functions (company_prefilter_sql / prospect_prefilter_sql) remain the mechanism
-- that keeps those bounded.
--
-- Each function below is the definition currently live in production with only the
-- guard added, so this does not roll back any recent change to their bodies.

begin;

CREATE OR REPLACE FUNCTION public.people_scope_company_ids_v1(p_client_id text, p_scope jsonb)
 RETURNS TABLE(company_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '15s'
AS $function$
declare
  v_search text := coalesce(p_scope->>'search', '');
  v_filters jsonb := coalesce(p_scope->'filters', '[]'::jsonb);
  v_limit integer := case
    when coalesce(p_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((p_scope->>'limit')::bigint, 250000))::integer
    else 250000
  end;
  v_prefilter text;
  v_sql text := 'select distinct pi.company_id from public.prospect_index pi where pi.company_id is not null';
begin
  if p_scope is null then return; end if;
  v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
  if p_client_id is not null then
    v_sql := v_sql || format(' and pi.client_ids @> array[%L]', p_client_id);
  end if;
  if v_prefilter <> 'true' then
    v_sql := v_sql || ' and (' || v_prefilter || ')';
  end if;
  -- An empty scope still means "every person in this client", so the company set
    -- is unchanged -- but prospect_index_matches_v1 would be called once per row of
    -- a 674k-row table to say so. Emit it only when it can actually exclude something.
  if btrim(v_search) <> '' or v_filters <> '[]'::jsonb then
    v_sql := v_sql || format(' and public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text);
  end if;
  v_sql := v_sql || format(' order by pi.company_id limit %s', v_limit);
  return query execute v_sql;
end;
$function$
;

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
  v_sql text;
begin
  if btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb then
    -- Unfiltered listing: every row matches, so do not emit the row function.
    v_match_clause := 'true';
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  v_sql := format($q$
    with base as (
      select c.id, c.name, c.domain, c.created_at
      from public.companies c
      where (%1$s)
        and (%2$L is null or exists (select 1 from public.prospect_index scoped where scoped.company_id = c.id and scoped.client_ids @> array[%2$L]))
        and (%3$L::jsonb is null or c.id in (select company_id from public.people_scope_company_ids_v1(%2$L, %3$L::jsonb)))
    ), agg as (
      select b.id, b.name, b.domain, b.created_at,
        coalesce(counts.prospect_count, 0) as prospect_count,
        coalesce(counts.client_count, 0) as client_count
      from base b
      left join lateral (
        select count(distinct pi.id)::integer as prospect_count, count(distinct client_id)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) client_id on true
        where pi.company_id = b.id and (%2$L is null or pi.client_ids @> array[%2$L])
      ) counts on true
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
       v_offset::text, v_limit::text);

  return query execute v_sql;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '20s'
AS $function$
  with matched as materialized (
    select c.id, c.name, c.domain, c.created_at,
      coalesce(counts.prospect_count, 0)::integer as prospect_count,
      coalesce(coverage.client_count, 0)::integer as client_count
    from public.client_companies membership
    join public.companies c on c.id = membership.company_id
    left join lateral (
      select count(distinct pi.id)::integer as prospect_count
      from public.prospect_index pi
      where pi.company_id = c.id and pi.client_ids @> array[p_client_id]
    ) counts on true
    left join lateral (
      select count(*)::integer as client_count
      from public.client_companies all_memberships
      where all_memberships.company_id = c.id
    ) coverage on true
    where membership.client_id = p_client_id
      and (
        -- Nothing to filter: skip the per-row call entirely. It would return true
        -- for every row anyway, and it is not inlinable, so calling it 150k times
        -- costs ~250us each and turns a 0.5s page into a 120s timeout.
        (btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.company_matches_filters_v1(c, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb))
      )
      and (p_people_scope is null or c.id in (
        select company_id from public.people_scope_company_ids_v1(p_client_id, p_people_scope)
      ))
  ), page_rows as (
    select * from matched
    order by prospect_count desc, lower(name), id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id) from page_rows), '[]'::jsonb),
    (select count(*) from matched),
    (select count(*) from matched where matched.prospect_count > 0),
    (select coalesce(sum(matched.prospect_count), 0) from matched);
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_company_action_selection_v1(p_client_id text DEFAULT NULL::text, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_limit integer DEFAULT 250000)
 RETURNS TABLE(company_id text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
  select c.id
  from public.companies c
  where (p_client_id is null or exists (
      select 1 from public.client_companies membership
      where membership.client_id = p_client_id and membership.company_id = c.id
    ))
    and (
      (p_company_ids is not null and c.id = any(p_company_ids[1:50000]))
      or (p_company_ids is null and (
        (btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.company_matches_filters_v1(c, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb))
      ))
    )
    and (p_people_scope is null or c.id in (
      select company_id from public.people_scope_company_ids_v1(p_client_id, p_people_scope)
    ))
    and not (c.id = any(coalesce(p_excluded_ids, array[]::text[])))
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 250000), 250000));
$function$
;

-- All four are SECURITY DEFINER; re-assert the same execute policy they already
-- carry, so this file is self-contained for the migration guard.
revoke execute on function public.people_scope_company_ids_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) from public, anon, authenticated;

grant execute on function public.people_scope_company_ids_v1(text, jsonb) to service_role;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;
grant execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) to service_role;

commit;
