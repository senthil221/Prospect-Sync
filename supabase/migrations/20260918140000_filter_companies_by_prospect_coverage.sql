-- __company_coverage: show all companies, only those with people, or only
-- those without.
--
-- WHAT NEEDS IT. Both Company databases sort busiest-first and page fifty at a
-- time, so the companies sitting at zero prospects are always on the last page.
-- That is the end of the list people actually need to audit: a company can carry
-- zero prospects and still belong on a client's ICP list - 20260916180000 makes
-- that asymmetry explicit, "person removed" deliberately leaves the company - so
-- "which of these has nobody behind it" is a real question with no way to ask it.
--
-- THE COUNT IT FILTERS ON IS THE COUNT ON SCREEN. That is the whole design
-- constraint, and it is why this is not one predicate but two.
--
--   Master Company DB   companies.prospect_count      every client's people
--   Client Company DB   this client's people only     scoped by client_ids
--
-- A company with 300 people, none of them this client's, is "with prospects" in
-- the master database and "without" inside that client. Both are correct; they
-- are answers to different questions. Compiling one predicate for both would
-- make the grid contradict the number printed in its own Prospects column,
-- which is the rule lib/quality-issues.ts states and 20260916110000 was built
-- around: a control that disagrees with its own count teaches you to distrust
-- the count.
--
-- So the master half is a filter field, compiled by the three company
-- compilers like any other, and the client half is intercepted by
-- client_company_workspace_v2 before compilation and applied to the per-client
-- count that function already computes for display.
--
-- Modelled on 20260916110000 (__company_ids), with one deliberate difference:
-- each patch asserts its anchor appears EXACTLY once before rewriting. replace()
-- rewrites every occurrence, so an anchor that appeared twice would silently
-- splice the block in twice.
-- ---------------------------------------------------------------------------

do $patch_coverage$
declare
  v_definition text;
  v_rewritten text;
  v_anchor text;
begin
  -- 1. The SQL builder. company_filter_sql_v2 delegates to v3, so patching v3
  --    reaches every caller.
  v_anchor := '      candidate_expr := case field_key';
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'company_filter_sql_v3 anchor appears % times, expected exactly 1',
      (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
  end if;
  v_rewritten := replace(v_definition, v_anchor,
    $new$      if field_key = '__company_coverage' then
        if cardinality(raw_values) = 0 then continue; end if;
        if raw_values[1] = 'with' then
          conjuncts := conjuncts || '(coalesce(c.prospect_count, 0) > 0)';
        elsif raw_values[1] = 'without' then
          conjuncts := conjuncts || '(coalesce(c.prospect_count, 0) = 0)';
        end if;
        continue;
      end if;
      candidate_expr := case field_key$new$);
  execute v_rewritten;

  -- 2. The row matcher, which bulk actions resolve their selection through. It
  --    must select the same set as the builder or the grid and a bulk action on
  --    the same filter act on different companies.
  v_anchor := '      else case coalesce(filter_item->>''operator'', ''contains'')';
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'company_matches_filters_v1 anchor appears % times, expected exactly 1',
      (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
  end if;
  v_rewritten := replace(v_definition, v_anchor,
    $new$      when filter_item->>'field' = '__company_coverage' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or case filter_item->'values'->>0
             when 'with' then coalesce((p_row).prospect_count, 0) > 0
             when 'without' then coalesce((p_row).prospect_count, 0) = 0
             else true
           end
      )
      else case coalesce(filter_item->>'operator', 'contains')$new$);
  execute v_rewritten;

  -- 3. The pre-filter. Both arms are exact and both are NECESSARY conditions -
  --    unlike __company_ids' exclude arm, which had to stay out for that reason -
  --    so the index-friendly probe carries the whole predicate.
  v_anchor := '    field_key := filter_item->>''field'';';
  select pg_get_functiondef('public.company_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'company_prefilter_sql anchor appears % times, expected exactly 1',
      (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
  end if;
  v_rewritten := replace(v_definition, v_anchor,
    $new$    field_key := filter_item->>'field';
    if field_key = '__company_coverage' then
      if coalesce(filter_item->'values'->>0, '') = 'with' then
        conjuncts := conjuncts || '(coalesce(c.prospect_count, 0) > 0)';
      elsif coalesce(filter_item->'values'->>0, '') = 'without' then
        conjuncts := conjuncts || '(coalesce(c.prospect_count, 0) = 0)';
      end if;
      continue;
    end if;
$new$);
  execute v_rewritten;
end $patch_coverage$;

-- ---------------------------------------------------------------------------
-- The client half. Same function as 20260831130211 with one addition: the
-- coverage filter is lifted out of p_filters before anything compiles it, and
-- applied instead to the per-client count in the `matched` CTE.
--
-- Applied OVER `matched` rather than inside it so the filter reads the exact
-- value the row displays, and so the three summary numbers below describe what
-- is actually on screen rather than what would have been without the filter.
create or replace function public.client_company_workspace_v2(
  p_client_id text,
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '45s'
as $function$
declare
  -- Taken out before compilation on purpose: company_filter_sql_v3 would render
  -- this as companies.prospect_count, which counts every client's people.
  v_coverage text := (
    select value->'values'->>0
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
    where value->>'field' = '__company_coverage'
    limit 1
  );
  v_filters jsonb := coalesce((
    select jsonb_agg(value)
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
    where value->>'field' <> '__company_coverage'
  ), '[]'::jsonb);
  v_coverage_clause text := case v_coverage
    when 'with' then 'where matched.prospect_count > 0'
    when 'without' then 'where matched.prospect_count = 0'
    else '' end;
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = '' and v_filters = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, v_filters);
  v_match_clause text;
  v_counts_cte text;
  v_counts_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_complete text;
  v_sql text;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, v_filters);

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
        || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, v_filters::text));
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
    ), visible as (
      select * from matched %8$s
    ), page_rows as (
      select * from visible
      order by prospect_count desc, lower(name), id
      limit %5$s offset %4$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id)
        from page_rows
      ), '[]'::jsonb),
      (select count(*) from visible),
      (select count(*) from visible where visible.prospect_count > 0),
      (select coalesce(sum(visible.prospect_count), 0) from visible)
  $query$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join, v_coverage_clause);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- MASTER: the two arms partition the database, and the builder, the row matcher
-- and the pre-filter all agree about which side a company falls on.
do $$
declare
  v_with bigint;
  v_without bigint;
  v_total bigint;
  v_matcher bigint;
  v_prefilter bigint;
  v_candidates text[];
  v_with_sampled bigint;
begin
  select count(*) into v_total from public.companies;
  if v_total = 0 then
    raise notice 'no companies; the coverage filter is unproven';
    return;
  end if;

  execute format('select count(*) from public.companies c where %s',
    public.company_filter_sql_v3('', '[{"field":"__company_coverage","operator":"equals","values":["with"]}]'::jsonb)) into v_with;
  execute format('select count(*) from public.companies c where %s',
    public.company_filter_sql_v3('', '[{"field":"__company_coverage","operator":"equals","values":["without"]}]'::jsonb)) into v_without;

  if v_with + v_without <> v_total then
    raise exception 'with (%) + without (%) <> % companies', v_with, v_without, v_total;
  end if;
  if v_with <> (select count(*) from public.companies where coalesce(prospect_count, 0) > 0) then
    raise exception 'the with-prospects arm selected % companies, the column says %',
      v_with, (select count(*) from public.companies where coalesce(prospect_count, 0) > 0);
  end if;

  -- Builder and row matcher must agree, bounded to a sample for the reason
  -- 20260916110000 records: the matcher is a per-row call with a jsonb parse.
  select coalesce(array_agg(id), array[]::text[]) into v_candidates
    from (select id from public.companies order by id limit 2500) sampled;
  execute format('select count(*) from public.companies c where c.id = any (%L::text[]) and (%s)',
    v_candidates, public.company_filter_sql_v3('', '[{"field":"__company_coverage","operator":"equals","values":["with"]}]'::jsonb)) into v_with_sampled;
  execute format('select count(*) from public.companies c where c.id = any (%L::text[]) and public.company_matches_filters_v1(c, %L, %L::jsonb)',
    v_candidates, '', '[{"field":"__company_coverage","operator":"equals","values":["with"]}]') into v_matcher;
  if v_matcher is distinct from v_with_sampled then
    raise exception '__company_coverage disagrees: builder % rows, row matcher %', v_with_sampled, v_matcher;
  end if;

  -- And the pre-filter never drops a row the complete predicate keeps.
  execute format('select count(*) from public.companies c where %s',
    public.company_prefilter_sql('', '[{"field":"__company_coverage","operator":"equals","values":["with"]}]'::jsonb)) into v_prefilter;
  if v_prefilter < v_with then
    raise exception 'the pre-filter (%) drops companies the complete filter keeps (%)', v_prefilter, v_with;
  end if;

  raise notice '__company_coverage: % with, % without, of % companies', v_with, v_without, v_total;
end $$;

-- An absent or unrecognised value narrows nothing, rather than matching
-- everything or nothing by accident. Both are reachable from a hand-edited URL.
do $$
declare
  v_sql text;
begin
  v_sql := public.company_filter_sql_v3('', '[{"field":"__company_coverage","operator":"equals","values":[]}]'::jsonb);
  if v_sql <> 'true' then
    raise exception 'an empty __company_coverage compiled to %, not to a no-op', v_sql;
  end if;
  v_sql := public.company_filter_sql_v3('', '[{"field":"__company_coverage","operator":"equals","values":["nonsense"]}]'::jsonb);
  if v_sql <> 'true' then
    raise exception 'an unrecognised __company_coverage compiled to %, not to a no-op', v_sql;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- CLIENT: the two arms partition the client's companies, the filter agrees with
-- the per-client number the row displays, and it is NOT the master answer.
do $$
declare
  v_client text;
  v_all bigint;
  v_with bigint;
  v_without bigint;
  v_rows jsonb;
  v_zero_rows integer;
begin
  select client_id into v_client
  from public.client_companies
  group by client_id
  having count(*) filter (where prospect_count = 0) > 0
     and count(*) filter (where prospect_count > 0) > 0
  limit 1;

  if v_client is null then
    raise notice 'no client mixes covered and uncovered companies; the client arm is unproven';
    return;
  end if;

  select total_count into v_all from public.client_company_workspace_v2(v_client, '', '[]'::jsonb, null, 1, 0);
  select total_count into v_with from public.client_company_workspace_v2(v_client, '',
    '[{"field":"__company_coverage","operator":"equals","values":["with"]}]'::jsonb, null, 1, 0);
  select total_count into v_without from public.client_company_workspace_v2(v_client, '',
    '[{"field":"__company_coverage","operator":"equals","values":["without"]}]'::jsonb, null, 1, 0);

  if v_with + v_without <> v_all then
    raise exception 'client %: with (%) + without (%) <> % companies', v_client, v_with, v_without, v_all;
  end if;
  if v_without = 0 then
    raise exception 'client % has zero-prospect companies but the without arm returned none', v_client;
  end if;

  -- Every row the without arm returns reads 0 in its own Prospects column. This
  -- is the constraint the whole design exists for.
  select result_rows into v_rows from public.client_company_workspace_v2(v_client, '',
    '[{"field":"__company_coverage","operator":"equals","values":["without"]}]'::jsonb, null, 50, 0);
  select count(*)::integer into v_zero_rows
  from jsonb_array_elements(v_rows) row_value
  where (row_value->>'prospect_count')::integer <> 0;
  if v_zero_rows > 0 then
    raise exception 'the without arm returned % rows whose own prospect count is not zero', v_zero_rows;
  end if;

  raise notice 'client %: % companies, % with people, % without', v_client, v_all, v_with, v_without;
end $$;
