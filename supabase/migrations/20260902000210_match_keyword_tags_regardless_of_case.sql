-- Match a keyword tag whatever case it was typed in.
--
-- THE REPORT: "is keywords case sensitive?" It was, in one scope out of three,
-- which is the worst possible answer.
--
--   typed              keywords scope   name+description   all three
--   cloud computing        18,539            1,951          19,325
--   Cloud Computing             0            1,951           1,951
--
-- Capitalising cost 90% of the result. The name and description scopes use
-- ILIKE and never cared; the keywords scope is `c.keywords && ARRAY[...]`, an
-- exact array overlap, and tags are stored lowercase -- 2,356,733 of 2,357,195
-- distinct tags, the remaining 462 being mojibake rather than real capitals.
--
-- It bites exactly the vocabulary this filter is for. From a real 51-keyword
-- IT-services list, tag matches as typed against lowercased:
--
--   IT consulting          0 -> 8,482
--   IT services            0 -> 5,596
--   IT outsourcing         0 -> 1,343
--   DevOps services        0 -> 1,116
--   SaaS development       0 -> 1,114
--   ERP implementation     0 ->   773
--
-- Whole list, all three scopes: 38,448 companies / 73,094 prospects as typed,
-- 41,057 / 81,477 lowercased. 8,383 prospects lost to the shift key.
--
-- WHY NOT JUST LOWERCASE THE SEARCH VALUES. Because technologies are stored the
-- other way round: 9,877 of 10,017 distinct values carry uppercase ("WordPress",
-- "Google Analytics"). Lowercasing needles would fix keywords and break
-- technologies. So both forms are searched instead -- one array, one GIN scan,
-- and it can only ever match more than before, never less.
--
-- This is deliberately a widening, so the prefilter has to widen with it. Both
-- builders call the same helper; leaving the prefilter narrow would drop the
-- very rows the predicate has just started matching, and the prefilter's
-- superset invariant is what makes ANDing them safe.
--
-- STILL NOT FIXED, and named rather than left to be discovered: typing
-- "wordpress" for a tag stored as "WordPress" matches neither form. Doing that
-- properly needs a GIN index over a lowercased copy of the array, which is a new
-- index on a 419k-row table and its own piece of work. It does not affect the
-- reported case: `__technologies` uses ILIKE over array_to_string for contains,
-- which is already case-insensitive, and only its equals operator goes through
-- the array test.

begin;

-- Both spellings, de-duplicated. Immutable so it can be folded into a generated
-- predicate, strict so a null list stays null.
create or replace function public.keyword_tag_variants_v1(p_values text[])
returns text[]
language sql
immutable
strict
parallel safe
security invoker
set search_path = public
as $function$
  select coalesce(array(
    select distinct value
    from (
      select unnest(p_values) as value
      union
      select lower(unnest(p_values))
    ) both_cases
    where value is not null and value <> ''
  ), array[]::text[]);
$function$;

create or replace function public.company_substring_probe_sql_v1(
  p_columns text[],
  p_values text[],
  p_keyword_values text[] default null
)
returns text
language plpgsql
immutable
security invoker
set search_path = public
as $function$
declare
  branches text[] := array[]::text[];
  column_name text;
begin
  if cardinality(coalesce(p_values, array[]::text[])) = 0 then return null; end if;

  if cardinality(coalesce(p_keyword_values, array[]::text[])) > 0 then
    -- Tags are matched exactly, so the case the user typed must not decide it.
    branches := array_append(branches, format(
      'select p.id from public.companies p where p.keywords && %L::text[]',
      public.keyword_tag_variants_v1(p_keyword_values)));
  end if;

  foreach column_name in array coalesce(p_columns, array[]::text[]) loop
    branches := array_append(branches, format(
      $b$select p.id from unnest(%L::text[]) needle join public.companies p on p.%I ilike '%%' || needle || '%%'$b$,
      p_values, column_name));
  end loop;

  if cardinality(branches) = 0 then return null; end if;
  return 'c.id in (' || array_to_string(branches, ' union ') || ')';
end;
$function$;

create or replace function public.company_filter_sql_v3(p_search text, p_filters jsonb, p_probe boolean default false)
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
  selected_scopes jsonb;
  candidate_expr text;
  boolean_expr text;
  keyword_hit text;
  keyword_values text[];
  match_cols text[];
  probe_sql text;
  scope_parts text[];
  value_parts text[];
  raw_values text[];
  value_text text;
  lowered text[];
  minimum text;
  maximum text;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('(c.name ilike %1$L or c.domain ilike %1$L)', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    field_key := filter_item->>'field';

    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;

    if cardinality(raw_values) = 0 and coalesce(filter_item->>'setId', '') = '' and operator_key not in ('empty', 'not_empty') then
      continue;
    end if;

    keyword_hit := 'false';
    keyword_values := null;

    selected_scopes := case
      when field_key <> '__company_keywords' then null
      when jsonb_typeof(filter_item->'scopes') = 'array'
        then case when jsonb_array_length(filter_item->'scopes') > 0
          then filter_item->'scopes' else '["name","keywords"]'::jsonb end
      else '["name","keywords"]'::jsonb
    end;

    if field_key = '__company_keywords' then
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      candidate_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      match_cols := scope_parts;

      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'keywords' then scope_parts := array_append(scope_parts, 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      boolean_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      if selected_scopes ? 'keywords' and cardinality(raw_values) > 0 then
        -- Both spellings: the tag store is lowercase, so "IT services" typed as
        -- the user thinks of it matched nothing at all.
        keyword_hit := format('c.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
        keyword_values := raw_values;
      end if;
    else
      candidate_expr := case field_key
        when '__company' then 'c.name'
        when '__website' then 'c.domain'
        when '__industry' then 'c.industry'
        when '__company_city' then 'c.city'
        when '__company_state' then 'c.state'
        when '__company_country' then 'c.country'
        when '__company_location' then 'coalesce(nullif(c.location, ' || quote_literal('') || '), concat_ws(' || quote_literal(', ') || ', nullif(c.city, ' || quote_literal('') || '), nullif(c.state, ' || quote_literal('') || '), nullif(c.country, ' || quote_literal('') || ')))'
        when '__keywords' then 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'
        when '__short_description' then 'c.short_description'
        when '__founded_year' then 'c.founded_year::text'
        when '__technologies' then 'array_to_string(c.technologies, ' || quote_literal(' | ') || ')'
        when '__total_funding' then 'c.total_funding'
        when '__employee_count' then quote_literal('')
        else null
      end;
      if candidate_expr is null then return null; end if;
      boolean_expr := candidate_expr;
      match_cols := array[candidate_expr];
    end if;

    candidate_expr := 'coalesce(' || candidate_expr || ', ' || quote_literal('') || ')';
    match_cols := array(select 'coalesce(' || col || ', ' || quote_literal('') || ')' from unnest(match_cols) col);
    if cardinality(match_cols) = 0 then match_cols := array[candidate_expr]; end if;
    boolean_expr := 'coalesce(' || boolean_expr || ', ' || quote_literal('') || ')';

    if coalesce(filter_item->>'setId', '') <> '' then
      if operator_key <> 'equals' then
        raise exception 'A filter set supports the equals operator only, got %', operator_key
          using errcode = '22023';
      end if;
      value_parts := array(select format(
        'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))',
        (filter_item->>'setId')::uuid, col) from unnest(match_cols) col);
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      continue;
    end if;

    probe_sql := null;
    if coalesce(p_probe, false)
       and public.company_filter_is_probed_v1(field_key, selected_scopes, operator_key, raw_values) then
      probe_sql := public.company_substring_probe_sql_v1(
        public.company_probe_columns_v1(field_key, selected_scopes), raw_values, keyword_values);
    end if;

    if operator_key = 'equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := case when keyword_hit <> 'false' then array[keyword_hit] else array[]::text[] end;
      value_parts := value_parts || array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      if field_key = '__keywords' then
        value_parts := value_parts || format('c.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      elsif field_key = '__technologies' then
        value_parts := value_parts || format('c.technologies && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      end if;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'not_equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));

    elsif operator_key = 'not_contains' then
      if probe_sql is not null then
        conjuncts := conjuncts || format('(not (%s))', probe_sql);
      else
        value_parts := array[]::text[];
        foreach value_text in array raw_values loop
          value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(match_cols) col);
        end loop;
        conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));
      end if;

    elsif operator_key = 'boolean' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)', 'simple', boolean_expr, 'simple', value_text);
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'empty' then
      conjuncts := conjuncts || format('(btrim(%s) = %L)', candidate_expr, '');

    elsif operator_key = 'not_empty' then
      conjuncts := conjuncts || format('(btrim(%s) <> %L)', candidate_expr, '');

    elsif operator_key = 'number_ranges' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        if value_text = 'unknown' then
          if field_key = '__employee_count' then
            value_parts := array_append(value_parts, '(c.employee_count_min is null and c.employee_count_max is null)');
          elsif field_key = '__founded_year' then
            value_parts := array_append(value_parts, '(c.founded_year is null)');
          end if;
          continue;
        end if;
        if value_text !~ '^[0-9]+:[0-9]*$' then continue; end if;
        minimum := split_part(value_text, ':', 1);
        maximum := case when value_text ~ '^[0-9]+:[0-9]+$' then split_part(value_text, ':', 2) else null end;
        if field_key = '__employee_count' then
          value_parts := value_parts || format(
            '(c.employee_count_min is not null and (%s) and (c.employee_count_max is null or c.employee_count_max >= %s))',
            case when maximum is null then 'true' else format('c.employee_count_min <= %s', maximum) end, minimum);
        elsif field_key = '__founded_year' then
          value_parts := value_parts || format('(c.founded_year is not null and c.founded_year >= %s and (%s))',
            minimum, case when maximum is null then 'true' else format('c.founded_year <= %s', maximum) end);
        end if;
      end loop;
      if cardinality(value_parts) = 0 then
        conjuncts := array_append(conjuncts, 'false');
      else
        conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      end if;

    else
      if probe_sql is not null then
        conjuncts := conjuncts || ('(' || probe_sql || ')');
      else
        value_parts := case when keyword_hit <> 'false' then array[keyword_hit] else array[]::text[] end;
        foreach value_text in array raw_values loop
          value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(match_cols) col);
        end loop;
        conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      end if;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$;

-- The prefilter is ANDed onto the predicate, so it has to widen in step or it
-- drops the rows the predicate has just started matching.
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
        scope_parts := array_append(scope_parts, format('c.keywords && %L::text[]',
          public.keyword_tag_variants_v1(raw_values)));
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

    if operator_key = 'equals' and field_key = '__keywords' then
      conjuncts := conjuncts || format('c.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      continue;
    end if;
    if operator_key = 'equals' and field_key = '__technologies' then
      conjuncts := conjuncts || format('c.technologies && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      continue;
    end if;

    if operator_key = 'equals' and field_key = '__website' then
      conjuncts := conjuncts || format('c.normalized_domain = any (%L::text[])',
        array(select lower(value) from unnest(raw_values) value));
      continue;
    end if;

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
      null;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$;

revoke execute on function public.keyword_tag_variants_v1(text[]) from public, anon, authenticated;
grant execute on function public.keyword_tag_variants_v1(text[]) to service_role;

commit;
