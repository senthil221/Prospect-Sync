-- One Company location filter, matching what the person-level Location field
-- already does (20260825010000).
--
-- companies.location has existed since 20260810000000 with a trigram index, but
-- nothing used it as a filter: the Company DB panel offered Company city, state
-- and country as three separate fields, and __company_location — which did exist
-- in the matcher — recomputed concat_ws(city, state, country) per row, ignoring
-- the stored column. So the one filter people actually want was unreachable from
-- the UI and unindexable when reached from a pivot.
--
-- After this: location is the stored, indexed, canonical company geography field;
-- city / state / country stay exactly as they are behind it, for exports and for
-- the fill-from-company enrichment.

-- ---------------------------------------------------------------------------
-- 1. Backfill the stored column
-- ---------------------------------------------------------------------------
-- Only rows whose import supplied an explicit Company Location column have one.
-- Compose the rest from their parts so the filter covers the whole database.

update public.companies set location = concat_ws(', ',
  nullif(btrim(city), ''), nullif(btrim(state), ''), nullif(btrim(country), ''))
where btrim(location) = ''
  and (btrim(city) <> '' or btrim(state) <> '' or btrim(country) <> '');

-- ---------------------------------------------------------------------------
-- 2. Matcher reads the stored column
-- ---------------------------------------------------------------------------

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
        -- Stored location wins; the parts remain the fallback for any row the
        -- backfill could not compose.
        when '__company_location' then coalesce(nullif((p_row).location, ''),
          concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, '')))
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

-- ---------------------------------------------------------------------------
-- 3. Pre-filter can now narrow on it
-- ---------------------------------------------------------------------------
-- companies.location already carries a trigram index (idx_companies_location_trgm),
-- so this turns the new filter from a full scan into an index scan. Large pasted
-- lists get the same three-shape treatment as the people pre-filter.

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
  raw_values text[];
  value_text text;
  bulk_or_threshold constant integer := 40;
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
      when '__company_location' then 'c.location'
      when '__short_description' then 'c.short_description'
      when '__total_funding' then 'c.total_funding'
      when '__keywords' then 'array_to_string(c.keywords, '' | '')'
      when '__technologies' then 'array_to_string(c.technologies, '' | '')'
      else null
    end;
    if column_expr is null then continue; end if;

    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    -- All three shapes are exactly equivalent to the OR-of-values the real
    -- predicate applies, so the pre-filter stays implied by it either way.
    if operator_key = 'equals' then
      conjuncts := conjuncts || format('lower(%s) = any (%L::text[])',
        column_expr, array(select lower(value) from unnest(raw_values) value));
    elsif cardinality(raw_values) <= bulk_or_threshold then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      conjuncts := conjuncts || format(
        'exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')',
        raw_values, column_expr);
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Autocomplete offers whole locations
-- ---------------------------------------------------------------------------

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
        when '__company_location' then coalesce(nullif(c.location, ''),
          concat_ws(', ', nullif(c.city, ''), nullif(c.state, ''), nullif(c.country, '')))
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

-- ---------------------------------------------------------------------------
-- 5. Keep the stored column populated on import
-- ---------------------------------------------------------------------------
-- import_prospect_batch_v4 fills company geography from a person row; it set
-- location only when the file carried an explicit Company Location column, so a
-- file with just city/state/country left the new filter blank for that company.

create or replace function public.import_prospect_batch_v4(
  p_import_id text,
  p_list_id text,
  p_rows jsonb
)
returns table(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  base_result record;
  row_data jsonb;
  prospect_id_value text;
begin
  select * into base_result
  from public.import_prospect_batch_v3(p_import_id, p_list_id, p_rows);

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    select lr.prospect_id into prospect_id_value
    from public.list_rows lr
    where lr.import_id = p_import_id
      and lr.source_row_number = coalesce(nullif(row_data->>'sourceRowNumber', '')::integer, 0);

    if prospect_id_value is null then continue; end if;

    update public.prospects set
      keywords = (
        select coalesce(array_agg(minimum_value order by lower_value), '{}'::text[])
        from (
          select lower(value) as lower_value, min(value) as minimum_value
          from unnest(prospects.keywords || array(
            select jsonb_array_elements_text(coalesce(row_data->'keywords', '[]'::jsonb))
          )) value
          where btrim(value) <> ''
          group by lower(value)
        ) unique_keywords
      ),
      updated_at = now()
    where id = prospect_id_value;

    update public.companies set
      employee_count_min = coalesce(companies.employee_count_min, nullif(row_data->>'companyEmployeeCountMin', '')::integer),
      employee_count_max = case
        when companies.employee_count_min is not null then companies.employee_count_max
        else nullif(row_data->>'companyEmployeeCountMax', '')::integer
      end,
      -- An explicit Company Location column wins; otherwise compose it from the
      -- parts, so the single Location filter is always populated.
      location = case when companies.location = '' then coalesce(
        nullif(btrim(coalesce(row_data->>'companyLocation', '')), ''),
        nullif(concat_ws(', ',
          nullif(btrim(coalesce(row_data->>'companyCity', '')), ''),
          nullif(btrim(coalesce(row_data->>'companyState', '')), ''),
          nullif(btrim(coalesce(row_data->>'companyCountry', '')), '')), ''),
        '') else companies.location end,
      city = case when companies.city = '' then coalesce(row_data->>'companyCity', '') else companies.city end,
      state = case when companies.state = '' then coalesce(row_data->>'companyState', '') else companies.state end,
      country = case when companies.country = '' then coalesce(row_data->>'companyCountry', '') else companies.country end,
      updated_at = now()
    where id = (select company_id from public.prospects where id = prospect_id_value);
  end loop;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$$;

revoke execute on function public.company_matches_filters_v1(public.companies, text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_prefilter_sql(text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_filter_values_v1(text, text, integer) from public, anon, authenticated;
revoke execute on function public.import_prospect_batch_v4(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.company_matches_filters_v1(public.companies, text, jsonb) to service_role;
grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;
grant execute on function public.company_filter_values_v1(text, text, integer) to service_role;
grant execute on function public.import_prospect_batch_v4(text, text, jsonb) to service_role;

-- Company geography is carried into the people index too, so the People DB and
-- the pivots agree with the Company DB about what a company's location is.
update public.prospect_index pi
set company_location = c.location
from public.companies c
where c.id = pi.company_id and pi.company_location is distinct from c.location;

analyze public.companies;

-- ---------------------------------------------------------------------------
-- 6. Smoke test
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_sql text;
  v_row record;
  v_count bigint;
begin
  -- The pre-filter must now narrow on the indexed column rather than skipping it.
  v_sql := public.company_prefilter_sql('', '[{"field":"__company_location","operator":"contains","values":["london"]}]'::jsonb);
  if v_sql not like '%c.location%' then
    raise exception 'company location filters are still unindexed: %', v_sql;
  end if;
  v_sql := public.company_prefilter_sql('', '[{"field":"__company_location","operator":"equals","values":["London, United Kingdom"]}]'::jsonb);
  if v_sql not like '%= any%' then
    raise exception 'equals on company location must compile to an array predicate: %', v_sql;
  end if;

  -- Every read path must accept the field.
  select count(*) into v_count from public.company_filter_values_v1('__company_location', '', 5);
  select * into v_row from public.filter_companies_v4('',
    '[{"field":"__company_location","operator":"contains","values":["a"]}]'::jsonb, null, '{}'::jsonb, 5, 0);
  perform * from public.company_scope_ids_v2(null,
    '{"search":"","filters":[{"field":"__company_location","operator":"contains","values":["a"]}]}'::jsonb) limit 1;

  -- And the backfill must have composed a location wherever parts existed.
  if exists (
    select 1 from public.companies
    where btrim(location) = '' and (btrim(city) <> '' or btrim(state) <> '' or btrim(country) <> '')
  ) then
    raise exception 'company location backfill left rows with parts but no location';
  end if;
end;
$smoke$;
