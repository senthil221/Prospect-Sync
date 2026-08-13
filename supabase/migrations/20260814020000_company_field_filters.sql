-- Apollo-style company filters. The Company tab now filters on the company's own
-- canonical columns (name, website, industry, #employees, city/state/country,
-- keywords, short description, founded year, technologies, total funding) using
-- the same {field, operator, values} filter model as the People tab -- instead of
-- the old name/domain/person-seniority/person-location bar.
--
-- Mirrors the prospect approach from 20260814000000: an opaque scalar matcher has
-- the final say, but an index-friendly SQL pre-filter (only ever emitting conjuncts
-- implied by the real predicate) runs first so trigram/gin indexes keep filtered
-- reads fast. All emitted values go through format()/%L, so the dynamic SQL is
-- injection safe.

-- Trigram / gin indexes so positive contains/equals pre-filter conjuncts on the
-- company detail columns can use an index instead of a sequential scan.
create index if not exists idx_companies_industry_trgm on public.companies using gin (industry gin_trgm_ops);
create index if not exists idx_companies_city_trgm on public.companies using gin (city gin_trgm_ops);
create index if not exists idx_companies_state_trgm on public.companies using gin (state gin_trgm_ops);
create index if not exists idx_companies_country_trgm on public.companies using gin (country gin_trgm_ops);
create index if not exists idx_companies_total_funding_trgm on public.companies using gin (total_funding gin_trgm_ops);
create index if not exists idx_companies_keywords_gin on public.companies using gin (keywords);
create index if not exists idx_companies_technologies_gin on public.companies using gin (technologies);
create index if not exists idx_companies_founded_year on public.companies (founded_year);
create index if not exists idx_companies_employee_count_min on public.companies (employee_count_min);

-- 1. Scalar matcher: does one company row satisfy the search + every filter?
create or replace function public.company_matches_filters_v1(
  p_row public.companies,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb
)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select (
    btrim(coalesce(p_search, '')) = ''
    or (p_row).name ilike '%' || btrim(p_search) || '%'
    or (p_row).domain ilike '%' || btrim(p_search) || '%'
  ) and not exists (
    select 1
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
    cross join lateral (
      select coalesce(case filter_item->>'field'
        when '__company' then (p_row).name
        when '__website' then (p_row).domain
        when '__industry' then (p_row).industry
        when '__company_city' then (p_row).city
        when '__company_state' then (p_row).state
        when '__company_country' then (p_row).country
        when '__company_location' then concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, ''))
        when '__keywords' then array_to_string((p_row).keywords, ' | ')
        when '__short_description' then (p_row).short_description
        when '__founded_year' then (p_row).founded_year::text
        when '__technologies' then array_to_string((p_row).technologies, ' | ')
        when '__total_funding' then (p_row).total_funding
        else '' end, '') as candidate_value
    ) candidate
    where not case coalesce(filter_item->>'operator', 'contains')
      when 'equals' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
          or (filter_item->>'field' = '__keywords' and selected.value = any((p_row).keywords))
          or (filter_item->>'field' = '__technologies' and selected.value = any((p_row).technologies))
      )
      when 'not_equals' then not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
      )
      when 'not_contains' then not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
      when 'boolean' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where to_tsvector('simple', candidate.candidate_value) @@ to_tsquery('simple', selected.value)
      )
      when 'number_ranges' then exists (
        select 1
        from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        cross join lateral (
          select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
        ) selected_range
        where (filter_item->>'field' = '__employee_count' and (
            (selected.value = 'unknown' and (p_row).employee_count_min is null and (p_row).employee_count_max is null)
            or (selected.value <> 'unknown' and (p_row).employee_count_min is not null
              and (selected_range.maximum is null or (p_row).employee_count_min <= selected_range.maximum)
              and ((p_row).employee_count_max is null or (p_row).employee_count_max >= selected_range.minimum))))
          or (filter_item->>'field' = '__founded_year' and (
            (selected.value = 'unknown' and (p_row).founded_year is null)
            or (selected.value <> 'unknown' and (p_row).founded_year is not null
              and (selected_range.minimum is null or (p_row).founded_year >= selected_range.minimum)
              and (selected_range.maximum is null or (p_row).founded_year <= selected_range.maximum))))
      )
      when 'empty' then btrim(candidate.candidate_value) = ''
      when 'not_empty' then btrim(candidate.candidate_value) <> ''
      else exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
    end
  );
$$;

-- 2. Index-usable pre-filter (a boolean SQL expression over alias `c`) that is
--    guaranteed to be implied by company_matches_filters_v1(c, search, filters).
create or replace function public.company_prefilter_sql(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  value_parts text[];
  value_text text;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('(c.name ilike %1$L or c.domain ilike %1$L)', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';
    column_expr := case field_key
      when '__company' then 'c.name'
      when '__website' then 'c.domain'
      when '__industry' then 'c.industry'
      when '__company_city' then 'c.city'
      when '__company_state' then 'c.state'
      when '__company_country' then 'c.country'
      when '__short_description' then 'c.short_description'
      when '__total_funding' then 'c.total_funding'
      when '__keywords' then 'array_to_string(c.keywords, '' | '')'
      when '__technologies' then 'array_to_string(c.technologies, '' | '')'
      else null
    end;
    if column_expr is null then continue; end if;

    value_parts := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      if operator_key = 'contains' then
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      else
        value_parts := value_parts || format('lower(%s) = lower(%L)', column_expr, value_text);
      end if;
    end loop;
    if cardinality(value_parts) > 0 then
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$$;

-- 3. Company tab query. Same return shape as filter_companies_v3 so the UI table
--    is unchanged; the filter model is now a single {field,operator,values} array.
create or replace function public.filter_companies_v4(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null,
  p_people_scope jsonb default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_sql text;
begin
  v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);

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
$fn$;

-- 4. Autocomplete values for the company filter token pickers.
create or replace function public.company_filter_values_v1(
  p_field text,
  p_search text default '',
  p_limit integer default 50
)
returns table(value text, match_count bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_search text := btrim(coalesce(p_search, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  if p_field in ('__keywords', '__technologies') then
    return query
      select entry.val, count(*)::bigint
      from public.companies c
      cross join lateral unnest(case when p_field = '__keywords' then c.keywords else c.technologies end) entry(val)
      where btrim(coalesce(entry.val, '')) <> '' and (v_search = '' or entry.val ilike '%' || v_search || '%')
      group by entry.val
      order by count(*) desc, lower(entry.val)
      limit v_limit;
    return;
  end if;

  return query
    select picked.val, count(*)::bigint
    from public.companies c
    cross join lateral (
      select case p_field
        when '__industry' then c.industry
        when '__company_city' then c.city
        when '__company_state' then c.state
        when '__company_country' then c.country
        when '__total_funding' then c.total_funding
        when '__company' then c.name
        when '__website' then c.domain
        else '' end as val
    ) picked
    where btrim(coalesce(picked.val, '')) <> '' and (v_search = '' or picked.val ilike '%' || v_search || '%')
    group by picked.val
    order by count(*) desc, lower(picked.val)
    limit v_limit;
end;
$$;

-- 5. Company -> People pivot ("See People") now resolves the scope through the same
--    company-column matcher. Signature is unchanged, so search_prospect_workspace_v10
--    / search_prospect_export_v4 keep calling it with no redeploy.
create or replace function public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb)
returns table(company_id text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_search text := coalesce(p_company_scope->>'search', '');
  v_filters jsonb := coalesce(p_company_scope->'filters', '[]'::jsonb);
  v_prefilter text := public.company_prefilter_sql(v_search, v_filters);
  v_sql text := 'select c.id from public.companies c where ';
begin
  v_sql := v_sql
    || case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', v_search, v_filters::text);
  return query execute v_sql;
end;
$$;

revoke execute on function public.company_matches_filters_v1(public.companies, text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_prefilter_sql(text, jsonb) from public, anon, authenticated;
revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.company_filter_values_v1(text, text, integer) from public, anon, authenticated;
revoke execute on function public.company_scope_ids_v2(text, jsonb) from public, anon, authenticated;

grant execute on function public.company_matches_filters_v1(public.companies, text, jsonb) to service_role;
grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;
grant execute on function public.company_filter_values_v1(text, text, integer) to service_role;
grant execute on function public.company_scope_ids_v2(text, jsonb) to service_role;
