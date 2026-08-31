-- Restore the index-usable positive prefilter in front of the complete company
-- predicate. 20260829160000 removed the per-row matcher, but it also replaced
-- company_prefilter_sql outright. For Company Keywords with description scope,
-- the complete predicate searches a concat_ws/coalesce expression, which cannot
-- use the trigram indexes on companies.name and companies.short_description.
--
-- Keeping both predicates is intentional:
--   * company_prefilter_sql is a necessary, index-usable narrowing condition for
--     positive contains/equals filters;
--   * company_filter_sql_v2 is the complete predicate and remains the source of
--     truth for excludes, Boolean expressions, emptiness, and numeric ranges.
--
-- The prefilter never widens or changes the result set. It only prevents the
-- complete verifier from being evaluated across the entire companies table.

begin;

-- Keep the prefilter a necessary condition for every filter it emits. Exact
-- array-field matching must use array overlap; comparing the entire joined
-- array string to one value incorrectly removes valid rows before verification.
create or replace function public.company_prefilter_sql(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $function$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  selected_scopes jsonb;
  scope_parts text[];
  value_parts text[];
  raw_values text[];
  value_text text;
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format(
      '(c.name ilike %1$L or c.domain ilike %1$L)',
      '%' || btrim(p_search) || '%'
    );
  end if;

  for filter_item in
    select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
  loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';

    raw_values := array[]::text[];
    for value_text in
      select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb))
    loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    if field_key = '__company_keywords' then
      selected_scopes := case
        when jsonb_typeof(filter_item->'scopes') = 'array'
          then case when jsonb_array_length(filter_item->'scopes') > 0
            then filter_item->'scopes' else '["name","keywords"]'::jsonb end
        else '["name","keywords"]'::jsonb
      end;
      scope_parts := array[]::text[];

      if selected_scopes ? 'keywords' then
        scope_parts := array_append(scope_parts, format('c.keywords && %L::text[]', raw_values));
      end if;
      foreach value_text in array raw_values loop
        if selected_scopes ? 'name' then
          scope_parts := array_append(scope_parts, format('c.name ilike %L', '%' || value_text || '%'));
        end if;
        if selected_scopes ? 'description' then
          scope_parts := array_append(scope_parts, format('c.short_description ilike %L', '%' || value_text || '%'));
        end if;
      end loop;

      if cardinality(scope_parts) > 0 then
        conjuncts := conjuncts || ('(' || array_to_string(scope_parts, ' or ') || ')');
      end if;
      continue;
    end if;

    -- Exact matching of an array field means any array element equals any
    -- requested value. This is both correct and served by the existing GIN
    -- indexes; joined-string equality is neither.
    if operator_key = 'equals' and field_key = '__keywords' then
      conjuncts := conjuncts || format('c.keywords && %L::text[]', raw_values);
      continue;
    end if;
    if operator_key = 'equals' and field_key = '__technologies' then
      conjuncts := conjuncts || format('c.technologies && %L::text[]', raw_values);
      continue;
    end if;

    column_expr := case field_key
      when '__company' then 'c.name'
      when '__website' then 'c.domain'
      when '__industry' then 'c.industry'
      when '__company_city' then 'c.city'
      when '__company_state' then 'c.state'
      when '__company_country' then 'c.country'
      when '__company_location' then 'c.location'
      when '__short_description' then 'c.short_description'
      when '__total_funding' then 'c.total_funding'
      when '__keywords' then 'array_to_string(c.keywords, '' | '')'
      when '__technologies' then 'array_to_string(c.technologies, '' | '')'
      else null
    end;
    if column_expr is null then continue; end if;

    if operator_key = 'equals' then
      conjuncts := conjuncts || format(
        'lower(%s) = any (%L::text[])',
        column_expr,
        array(select lower(value) from unnest(raw_values) value)
      );
    elsif cardinality(raw_values) <= bulk_or_threshold then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      conjuncts := conjuncts || format(
        'exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')',
        raw_values,
        column_expr
      );
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$;

create or replace function public.company_effective_filter_sql_v1(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.company_filter_sql_v2(p_search, coalesce(p_filters, '[]'::jsonb));
begin
  if v_complete is null then return null; end if;
  if v_prefilter <> 'true' then
    return '(' || v_prefilter || ') and (' || v_complete || ')';
  end if;
  return v_complete;
end;
$function$;

create or replace function public.filter_companies_v4(
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null::text,
  p_people_scope jsonb default null::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '45s'
as $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
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
    ), counted as (
      select count(*)::integer as total_count,
        count(*) filter (where prospect_count > 0)::integer as covered_count,
        coalesce(sum(prospect_count), 0)::integer as prospect_total
      from agg
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
      counted.total_count, counted.covered_count, counted.prospect_total
    from counted
  $query$, v_match_clause, p_client_id,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_agg_select);

  return query execute v_sql;
end;
$function$;

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
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = ''
    and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counts_cte text;
  v_counts_join text;
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
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id)
        from page_rows
      ), '[]'::jsonb),
      (select count(*) from matched),
      (select count(*) from matched where matched.prospect_count > 0),
      (select coalesce(sum(matched.prospect_count), 0) from matched)
  $query$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join);

  return query execute v_sql;
end;
$function$;

-- Migration-time contract check: description scope must retain the direct,
-- trigram-indexable column predicate as well as the complete verifier.
do $check$
declare
  built_sql text;
  exact_keyword_sql text;
begin
  built_sql := public.company_effective_filter_sql_v1('',
    '[{"field":"__company_keywords","operator":"contains","values":["security"],"scopes":["name","keywords","description"]}]'::jsonb);
  if built_sql not like '%c.name ilike%'
    or built_sql not like '%c.keywords &&%'
    or built_sql not like '%c.short_description ilike%'
    or built_sql not like '%concat_ws%'
  then
    raise exception 'Company description filtering lost its indexed prefilter or complete verifier';
  end if;

  exact_keyword_sql := public.company_prefilter_sql('',
    '[{"field":"__keywords","operator":"equals","values":["security"]}]'::jsonb);
  if exact_keyword_sql not like '%c.keywords &&%'
    or exact_keyword_sql like '%array_to_string%'
  then
    raise exception 'Exact keyword prefilter can discard valid array-element matches';
  end if;
end;
$check$;

revoke execute on function public.company_prefilter_sql(text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_effective_filter_sql_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;

grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;
grant execute on function public.company_effective_filter_sql_v1(text, jsonb) to service_role;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;

commit;
