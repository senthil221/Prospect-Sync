-- Company keyword filtering becomes exact, and therefore fast.
--
-- "keyword contains hr" used to mean a substring match over
-- concat_ws(' | ', name, keywords, description), so it returned 'nephrology'
-- and 'threat detection'. It also could not use an index -- ILIKE with a
-- leading wildcard over a concatenation of the whole row is answerable by
-- nothing -- so it scanned all 418,151 companies and cost ~12s, close enough to
-- the 20s function timeout to fail under load.
--
-- Both problems have the same root and the same fix. A keyword is a discrete
-- value picked from a list, not free text, so it should match an ELEMENT of
-- companies.keywords exactly. That is answerable by a GIN index.
--
-- Measured on production, "hr consulting":
--
--   exact match, keywords scope ............  12 s  ->  3.9 ms
--   several values at once .................          2.8 ms
--   name + keywords scopes .................          4.9 ms
--   all three scopes .......................           66 ms
--
-- Scope by scope:
--   keywords     exact match against an array element   (GIN on keywords)
--   name         substring, unchanged                   (GIN trigram on name)
--   description  substring, unchanged                   (GIN trigram on it)
--
-- Name and description stay substring matches because they are free text and
-- "exact" is meaningless for them. What changes is that each is emitted as its
-- own disjunct against its own column with a literal pattern, so a trigram
-- index can serve it; buried inside concat_ws() none of that was possible.
--
-- Boolean (advanced) search is deliberately left matching keywords as text. It
-- is an expression the user wrote rather than a value they picked, so narrowing
-- it to exact elements would remove capability rather than add precision.
--
-- company_prefilter_sql and company_matches_filters_v1 are changed together and
-- must stay in agreement: the first narrows, the second confirms, and if they
-- disagree the listing silently returns the wrong rows.

begin;

set local maintenance_work_mem = '512MB';

-- ~66s, ~3s and ~70s respectively when measured on production.
create index if not exists idx_companies_keywords_gin on public.companies using gin (keywords);
create index if not exists idx_companies_name_trgm on public.companies using gin (name gin_trgm_ops);
create index if not exists idx_companies_short_description_trgm on public.companies using gin (short_description gin_trgm_ops);

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
  selected_scopes jsonb;
  scope_parts text[];
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

    -- Gathered before the branch now: the keyword branch needs the values too.
    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
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

      -- Keywords match EXACTLY against an element of the array, not as a substring
      -- of a concatenation of the whole row. Correctness first: '%hr%' matched
      -- 'nephrology' and 'threat detection'. Speed follows from it -- an array
      -- overlap is answerable by a GIN index on keywords, while ILIKE over
      -- concat_ws() is answerable by nothing, which is why a keyword filter cost
      -- 12s across 418,151 companies.
      if selected_scopes ? 'keywords' then
        scope_parts := array_append(scope_parts, format('c.keywords && %L::text[]', raw_values));
      end if;

      -- Name and description stay substring matches: they are free text and
      -- "exact" is meaningless for them. Each becomes its own disjunct against its
      -- own column, with literal patterns, so a trigram index can serve it --
      -- buried inside concat_ws() none of that was possible.
      foreach value_text in array raw_values loop
        if selected_scopes ? 'name' then
          scope_parts := array_append(scope_parts, format('c.name ilike %L', '%' || value_text || '%'));
        end if;
        if selected_scopes ? 'description' then
          scope_parts := array_append(scope_parts, format('c.short_description ilike %L', '%' || value_text || '%'));
        end if;
      end loop;

      if cardinality(scope_parts) = 0 then continue; end if;
      conjuncts := conjuncts || ('(' || array_to_string(scope_parts, ' or ') || ')');
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
      select case
        when filter_item->>'field' = '__company_keywords' and jsonb_typeof(filter_item->'scopes') = 'array'
          then case when jsonb_array_length(filter_item->'scopes') > 0
            then filter_item->'scopes' else '["name","keywords"]'::jsonb end
        else '["name","keywords"]'::jsonb
      end as selected_scopes
    ) scope
    cross join lateral (
      select coalesce(case filter_item->>'field'
        when '__company_keywords' then concat_ws(' | ',
          case when scope.selected_scopes ? 'name' then (p_row).name end,
          case when scope.selected_scopes ? 'description' then (p_row).short_description end)
        when '__company' then (p_row).name
        when '__website' then (p_row).domain
        when '__industry' then (p_row).industry
        when '__company_city' then (p_row).city
        when '__company_state' then (p_row).state
        when '__company_country' then (p_row).country
        when '__company_location' then coalesce(nullif((p_row).location, ''),
          concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, '')))
        when '__keywords' then array_to_string((p_row).keywords, ' | ')
        when '__short_description' then (p_row).short_description
        when '__founded_year' then (p_row).founded_year::text
        when '__technologies' then array_to_string((p_row).technologies, ' | ')
        when '__total_funding' then (p_row).total_funding
        else '' end, '') as candidate_value
    ) candidate
    cross join lateral (
      select
        filter_item->>'field' = '__company_keywords'
        and scope.selected_scopes ? 'keywords'
        and (p_row).keywords && (
          select coalesce(array_agg(value), array[]::text[])
          from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb))
        ) as keyword_hit,
        -- Boolean search keeps matching keywords as text. It is an expression the
        -- user wrote, not a value they picked, so narrowing it to exact array
        -- elements would remove capability rather than add precision.
        concat_ws(' | ',
          case when scope.selected_scopes ? 'name' then (p_row).name end,
          case when scope.selected_scopes ? 'keywords' then array_to_string((p_row).keywords, ' | ') end,
          case when scope.selected_scopes ? 'description' then (p_row).short_description end) as boolean_value
    ) kw
    where not case coalesce(filter_item->>'operator', 'contains')
      when 'equals' then kw.keyword_hit or exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
          or (filter_item->>'field' = '__keywords' and selected.value = any((p_row).keywords))
          or (filter_item->>'field' = '__technologies' and selected.value = any((p_row).technologies))
      )
      when 'not_equals' then not kw.keyword_hit and not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
      )
      when 'not_contains' then not kw.keyword_hit and not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
      when 'boolean' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where to_tsvector('simple', kw.boolean_value) @@ to_tsquery('simple', selected.value)
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
      else kw.keyword_hit or exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
    end
  );
$$;

revoke execute on function public.company_prefilter_sql(text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_matches_filters_v1(public.companies, text, jsonb) from public, anon, authenticated;

grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;
grant execute on function public.company_matches_filters_v1(public.companies, text, jsonb) to service_role;

commit;
