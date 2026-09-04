-- Give "See People" the plan chooser the company listing already has.
--
-- THE REPORT: "See People" returned "This filter combination took longer than
-- the database allows." The Companies tab had just answered the same filter in
-- about six seconds.
--
-- WHY. The pivot resolves the company scope through company_scope_ids_v2, which
-- has always used company_effective_filter_sql_v1 -- the OR chain. 20260902000190
-- taught filter_companies_v4 to choose between that chain and the index probe,
-- and taught it nowhere else. On the reported 51-keyword filter:
--
--   company_scope_ids_v2, OR chain    41,057 ids in 24,833 ms
--   the same ids, probe shape         41,057 ids in  9,533 ms
--
-- search_prospect_workspace_v12 runs under SET statement_timeout '20s', so 24.8s
-- is not slow, it is a failed request. The scope resolver has no early exit by
-- construction -- it needs every matching id, up to its 250,000 ceiling -- which
-- is precisely the case the probe was measured to win.
--
-- ONE CHOOSER, NOT TWO. The obvious fix is to paste the sampling block into
-- company_scope_ids_v2. That is how the first cut of 20260902000190 broke
-- __company_location: the same decision taken in two places, and they disagreed.
-- So the decision moves into company_full_scan_filter_sql_v1 and both callers
-- ask it. Anything that later needs to scan a whole company match set -- an
-- export, a delete, a future pivot -- asks the same function and gets the same
-- answer.
--
-- The threshold is the exact-count one (0.72), not the capped one (0.40),
-- because scanning for every id has no early exit. That distinction is the whole
-- reason the two numbers exist; see 20260902000200.

begin;

-- The best predicate for reading a company match set in full. Null only when the
-- filter cannot be translated at all, which is the caller's signal to fall back
-- to the per-row function exactly as before.
create or replace function public.company_full_scan_filter_sql_v1(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $function$
declare
  v_complete text;
  v_probe text;
  v_fraction numeric;
  v_value_count integer;
  v_sample_rows integer;
  -- Counting or collecting every match has no early exit, so the OR chain only
  -- wins once the filter is very broad. Measured either side: at 65.1% of the
  -- table the probe won 32.2s to 37.3s, at 79.9% the chain won 6.9s to 12.7s.
  v_broad_fraction constant numeric := 0.72;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is null then return null; end if;

  v_probe := public.company_probe_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_probe is null then return v_complete; end if;

  select coalesce(max(cardinality(v)), 0) into v_value_count
  from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) f
  cross join lateral (select array(select jsonb_array_elements_text(f.value->'values'))) s(v);

  -- Per-row sample cost grows with the value list, so bound the product rather
  -- than the row count.
  v_sample_rows := greatest(120, least(400, 60000 / greatest(v_value_count, 1)));

  begin
    -- Sampled, not estimated: EXPLAIN raises 0A000 in a non-volatile function,
    -- and the planner's estimate was wrong by 2.4x on exactly this shape.
    execute format(
      'select coalesce(avg(case when %s then 1.0 else 0.0 end), 1.0) from '
      || '(select * from public.companies tablesample system (0.05) repeatable (1) limit %s) c',
      v_complete, v_sample_rows) into v_fraction;
  exception when others then
    -- Choosing a shape is an optimisation, never a correctness input.
    return v_complete;
  end;

  return case when v_fraction < v_broad_fraction then v_probe else v_complete end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb)
 RETURNS TABLE(company_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_search text := coalesce(p_company_scope->>'search', '');
  v_filters jsonb := coalesce(p_company_scope->'filters', '[]'::jsonb);
  v_prefilter text := public.company_prefilter_sql(v_search, v_filters);
  v_complete text;
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

  -- Every id is wanted, so there is no early exit and this is the full-scan
  -- case. Same chooser the listing's count uses, so the two cannot drift.
  v_complete := public.company_full_scan_filter_sql_v1(v_search, v_filters);

  v_sql := v_sql
    || coalesce(v_complete,
         case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
           || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', v_search, v_filters::text))
    || format(' order by c.id limit %s', v_limit);
  return query execute v_sql;
end;
$function$;

-- The listing's counting scan is the same question, so it stops carrying its own
-- copy of the sampling block and asks the shared chooser too.
CREATE OR REPLACE FUNCTION public.filter_companies_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_known_versions jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer, total_capped boolean, data_versions jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counting_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_ctes text[] := array[]::text[];
  v_cte_sql text;
  v_join text;
  v_prospect_expr text;
  v_client_expr text;
  v_where text;
  v_where_counting text;
  v_scope_suffix text := '';
  v_complete text;
  v_versions jsonb;
  v_want_total boolean;
  v_sql text;
begin
  v_versions := public.data_versions_v1(array['company', 'prospect']);
  v_want_total := p_known_versions is null or p_known_versions <> v_versions;

  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  -- The page always keeps the OR chain: it walks idx_companies_prospect_ranking
  -- and stops at fifty, which is fast at any selectivity. Only the counting scan
  -- may switch, and only when there is a count to take.
  v_counting_clause := v_match_clause;
  if v_want_total then
    v_counting_clause := coalesce(
      public.company_full_scan_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb)),
      v_match_clause);
  end if;

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

  if p_client_id is not null then
    v_scope_suffix := v_scope_suffix || format($e$ and exists (
      select 1 from public.prospect_index scoped
      where scoped.company_id = c.id and scoped.client_ids @> array[%L]
    )$e$, p_client_id);
  end if;
  if p_people_scope is not null then
    v_ctes := array_append(v_ctes, format($s$scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(%L, %L::jsonb)
      )$s$, p_client_id, p_people_scope::text));
    v_scope_suffix := v_scope_suffix || ' and c.id in (select company_id from scope_ids)';
  end if;

  v_where := format('(%s)', v_match_clause) || v_scope_suffix;
  v_where_counting := format('(%s)', v_counting_clause) || v_scope_suffix;

  v_cte_sql := case when cardinality(v_ctes) > 0
    then array_to_string(v_ctes, ', ') || ', ' else '' end;

  v_sql := format($query$
    with %1$s page as (
      select c.id, c.name, c.domain, c.created_at,
        %2$s as prospect_count, %3$s as client_count
      from public.companies c%4$s
      where %5$s
      order by %2$s desc, lower(c.name), c.id
      offset %6$s limit %7$s
    ), counted as (
      select count(*)::integer as total_count,
        count(*) filter (where %2$s > 0)::integer as covered_count,
        coalesce(sum(%2$s), 0)::integer as prospect_total
      from public.companies c%4$s
      where %8$s and %9$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id)
        from page
      ), '[]'::jsonb),
      case when %9$s then counted.total_count end,
      case when %9$s then counted.covered_count end,
      case when %9$s then counted.prospect_total end,
      false,
      %10$L::jsonb
    from counted
  $query$, v_cte_sql, v_prospect_expr, v_client_expr, v_join, v_where,
       v_offset::text, v_limit::text, v_where_counting, v_want_total::text, v_versions::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.company_full_scan_filter_sql_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_scope_ids_v2(text, jsonb) from public, anon, authenticated;
revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer, jsonb) from public, anon, authenticated;
grant execute on function public.company_full_scan_filter_sql_v1(text, jsonb) to service_role;
grant execute on function public.company_scope_ids_v2(text, jsonb) to service_role;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer, jsonb) to service_role;

commit;
