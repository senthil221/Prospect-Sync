-- Make the filter engine's cost depend on the work implied, not on which filters
-- were chosen. Three ceilings, all reachable by ordinary use at scale.
--
-- 1. Boolean made every other filter slow.
--
-- 20260902000000 returned null the moment it met a Boolean operator, handing the
-- whole set back to prospect_index_matches_v1. Twenty-nine cheap filters plus one
-- Boolean fell off the same cliff as before: about 35s against 0.5s for the same
-- rows. Boolean is expressible -- the row function evaluates
-- to_tsvector('simple', candidate) @@ to_tsquery('simple', value) and so does
-- this, inline. It is still not index-served, so a Boolean filter is not free,
-- but it now costs a SQL expression per row instead of a non-inlinable function
-- call, and it stops dragging the rest of the set down with it.
--
-- to_tsquery raises on a malformed compiled query. It raises in the row function
-- too, at the same point, so that is unchanged rather than newly introduced.
--
-- 2. The generated SQL grew with values x filters.
--
-- contains, not_contains and boolean emitted one expression per value, each
-- carrying a full copy of the candidate expression. For a custom: field that
-- candidate is an entire jsonb subquery, so 40 filters carrying thousands of
-- values each produced megabytes of SQL, where planning alone dominates. Above
-- the same threshold the prefilter already uses, they now emit one array literal
-- and one copy of the candidate. The predicate is identical either way.
--
-- 3. The prefilters emitted a predicate no index could serve.
--
-- Above 40 values the substring branch produced a correlated lateral over the
-- array. The pattern is built per row, so no index can serve it -- and the
-- authoritative predicate tests the same thing again afterwards, so every
-- candidate row paid that scan twice. A prefilter exists to narrow via an index;
-- one that cannot narrow is worse than none. Both prefilters now emit nothing in
-- that case and let the complete predicate do the work once.
--
-- The prefilter stays a superset of the real predicate, which is what makes
-- dropping a conjunct safe: emitting nothing widens it, and the authoritative
-- predicate still decides.

begin;

CREATE OR REPLACE FUNCTION public.prospect_prefilter_sql(p_search text, p_filters jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  value_parts text[];
  raw_values text[];
  value_text text;
  -- Above this many values an OR chain costs more to plan than the index scan
  -- saves, so the pre-filter switches to an array predicate.
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('pi.search_text ilike %L', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';
    column_expr := case field_key
      when '__name' then 'pi.full_name'
      when '__first_name' then 'pi.first_name'
      when '__last_name' then 'pi.last_name'
      when '__company' then 'pi.company_name'
      when '__company_domain' then 'pi.company_domain'
      when '__title' then 'pi.title'
      when '__seniority' then 'pi.seniority'
      when '__department' then 'pi.department' when '__title_department' then 'pi.title_department' when '__title_sub_department' then 'pi.title_sub_department' when '__title_seniority_tier' then 'pi.title_seniority'
      when '__work_email' then 'pi.work_email'
      when '__personal_email' then 'pi.personal_email'
      when '__linkedin' then 'pi.linkedin_url'
      when '__city' then 'pi.city'
      when '__state' then 'pi.state'
      when '__country' then 'pi.country'
      when '__person_location' then 'pi.location'
      when '__company_city' then 'pi.company_city'
      when '__company_state' then 'pi.company_state'
      when '__company_country' then 'pi.company_country'
      when '__esp' then 'pi.esp'
      when '__email_provider_type' then 'pi.email_provider_type'
      when '__tags' then 'pi.tag_text'
      else null
    end;
    if column_expr is null then continue; end if;

    -- Collect the raw values once, then choose a shape by size. All three shapes
    -- below are exactly equivalent to the OR-of-values the real predicate applies,
    -- so the pre-filter stays implied by it no matter which one is emitted.
    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    if operator_key = 'equals' then
      -- Equality scales to any list size as a single array membership test.
      conjuncts := conjuncts || format('lower(%s) = any (%L::text[])',
        column_expr, array(select lower(value) from unnest(raw_values) value));
    elsif cardinality(raw_values) <= bulk_or_threshold then
      -- Few enough values that the planner can still BitmapOr the trigram index.
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      -- A pasted column of hundreds of values: one lateral over the array beats a
      -- several-hundred-branch OR, which costs more to plan than it saves.
      -- Above this size the only substring form is a correlated lateral over
      -- the array, and no index can serve it because the pattern is built per
      -- row. Emitting it makes every candidate pay that scan twice, since the
      -- authoritative predicate tests the same thing again. A prefilter that
      -- cannot narrow is worse than none, so emit nothing and let the complete
      -- predicate do the work once.
      null;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$

;

CREATE OR REPLACE FUNCTION public.company_prefilter_sql(p_search text, p_filters jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
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
      conjuncts := conjuncts || format('c.keywords && %L::text[]', raw_values);
      continue;
    end if;
    if operator_key = 'equals' and field_key = '__technologies' then
      conjuncts := conjuncts || format('c.technologies && %L::text[]', raw_values);
      continue;
    end if;

    -- A pasted list of websites. normalized_domain is indexed and equals
    -- lower(domain) on every row, so this is the same test the row predicate
    -- makes, served by idx_companies_normalized_domain instead of a scan.
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
      -- Above this size the only substring form is a correlated lateral over
      -- the array, and no index can serve it because the pattern is built per
      -- row. Emitting it makes every candidate pay that scan twice, since the
      -- authoritative predicate tests the same thing again. A prefilter that
      -- cannot narrow is worse than none, so emit nothing and let the complete
      -- predicate do the work once.
      null;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prospect_filter_sql_v1(p_search text, p_filters jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  candidate_expr text;
  value_parts text[];
  raw_values text[];
  lowered text[];
  value_text text;
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('pi.search_text ilike %L', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    field_key := coalesce(filter_item->>'field', '');

    -- Every operator the row function implements is translated, so no filter set
    -- falls back wholesale because of one advanced filter among thirty.

    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    lowered := array(select lower(value) from unnest(raw_values) value);

    candidate_expr := case field_key
      when '__name' then 'pi.full_name'
      when '__first_name' then 'pi.first_name'
      when '__last_name' then 'pi.last_name'
      when '__company' then 'pi.company_name'
      when '__company_domain' then 'pi.company_domain'
      when '__email' then 'concat_ws('' '', pi.work_email, pi.personal_email)'
      when '__work_email' then 'pi.work_email'
      when '__personal_email' then 'pi.personal_email'
      when '__title' then 'pi.title'
      when '__keywords' then 'array_to_string(pi.keywords, '' | '')'
      when '__linkedin' then 'pi.linkedin_url'
      when '__city' then 'pi.city'
      when '__state' then 'pi.state'
      when '__country' then 'pi.country'
      when '__person_location' then 'coalesce(nullif(pi.location, ''''), concat_ws('', '', nullif(pi.city, ''''), nullif(pi.state, ''''), nullif(pi.country, '''')))'
      when '__company_location' then 'concat_ws('', '', nullif(pi.company_location, ''''), nullif(pi.company_city, ''''), nullif(pi.company_state, ''''), nullif(pi.company_country, ''''))'
      when '__company_city' then 'pi.company_city'
      when '__company_state' then 'pi.company_state'
      when '__company_country' then 'pi.company_country'
      when '__seniority' then 'pi.seniority'
      when '__department' then 'pi.department'
      when '__title_department' then 'pi.title_department'
      when '__title_sub_department' then 'pi.title_sub_department'
      when '__title_seniority_tier' then 'pi.title_seniority'
      when '__esp' then 'pi.esp'
      when '__email_provider_type' then 'pi.email_provider_type'
      when '__tags' then 'pi.tag_text'
      when '__last_contacted' then 'pi.last_contacted_at::text'
      when '__lists' then 'array_to_string(pi.list_names, '' | '')'
      when '__clients' then 'array_to_string(pi.client_names, '' | '')'
      else case
        when field_key like 'custom:%' then format($c$coalesce((
          select string_agg(entry.value, ' | ' order by entry.key)
          from jsonb_each_text(pi.all_data) entry(key, value)
          where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = %L
        ), '')$c$, substring(field_key from 8))
        else quote_literal('')
      end
    end;
    candidate_expr := format('coalesce(%s, %L)', candidate_expr, '');

    if operator_key = 'empty' then
      conjuncts := conjuncts || format('btrim(%s) = %L', candidate_expr, '');
      continue;
    elsif operator_key = 'not_empty' then
      conjuncts := conjuncts || format('btrim(%s) <> %L', candidate_expr, '');
      continue;
    end if;

    -- The row function evaluates its value operators against an empty list as
    -- "no value matched", which rejects the row. Reproduce that rather than
    -- treating a value-less filter as absent.
    if cardinality(raw_values) = 0 then
      conjuncts := array_append(conjuncts, 'false');
      continue;
    end if;

    if operator_key = 'boolean' then
      -- Exactly the row function's branch, inline: to_tsquery can raise on a
      -- malformed compiled query, and it raises there too, so behaviour matches.
      if cardinality(raw_values) > bulk_or_threshold then
        conjuncts := conjuncts || format(
          'exists (select 1 from unnest(%L::text[]) needle where to_tsvector(''simple'', %s) @@ to_tsquery(''simple'', needle))',
          raw_values, candidate_expr);
        continue;
      end if;

      foreach value_text in array raw_values loop
        value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)',
          'simple', candidate_expr, 'simple', value_text);
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      continue;
    end if;

    if operator_key = 'number_ranges' then
      if field_key <> '__employee_count' then
        conjuncts := array_append(conjuncts, 'false');
        continue;
      end if;
      conjuncts := conjuncts || format($r$exists (
        select 1 from unnest(%L::text[]) as selected(value)
        cross join lateral (
          select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
        ) selected_range
        where (selected.value = 'unknown' and pi.employee_count_min is null and pi.employee_count_max is null)
          or (selected.value <> 'unknown' and pi.employee_count_min is not null
            and (selected_range.maximum is null or pi.employee_count_min <= selected_range.maximum)
            and (pi.employee_count_max is null or pi.employee_count_max >= selected_range.minimum))
      )$r$, raw_values);
      continue;
    end if;

    if operator_key = 'equals' then
      -- __lists and __clients also match a whole array element, not only the
      -- joined string, so a list named "A | B" cannot be matched by accident.
      if field_key in ('__lists', '__clients') then
        conjuncts := conjuncts || format('(lower(%s) = any (%L::text[]) or %s && %L::text[])',
          candidate_expr, lowered,
          case when field_key = '__lists' then 'pi.list_names' else 'pi.client_names' end,
          raw_values);
      else
        conjuncts := conjuncts || format('lower(%s) = any (%L::text[])', candidate_expr, lowered);
      end if;
      continue;
    elsif operator_key = 'not_equals' then
      conjuncts := conjuncts || format('not (lower(%s) = any (%L::text[]))', candidate_expr, lowered);
      continue;
    end if;

    -- contains / not_contains: one ILIKE per value, exactly as the row function
    -- tests them. Patterns stay unescaped so behaviour is unchanged.
    -- One array literal and one copy of the candidate expression, rather than a
    -- copy per value. A custom: field's candidate is a whole jsonb subquery, so at
    -- a few thousand values an OR chain becomes megabytes of SQL and the planning
    -- cost alone dominates. Same predicate either way.
    if cardinality(raw_values) > bulk_or_threshold then
      conjuncts := conjuncts || format(
        case when operator_key = 'not_contains'
          then 'not exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')'
          else 'exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')' end,
        raw_values, candidate_expr);
      continue;
    end if;

    value_parts := array[]::text[];
    foreach value_text in array raw_values loop
      value_parts := value_parts || format('%s ilike %L', candidate_expr, '%' || value_text || '%');
    end loop;

    if operator_key = 'not_contains' then
      conjuncts := conjuncts || ('not (' || array_to_string(value_parts, ' or ') || ')');
    else
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$;
;

grant execute on function public.prospect_prefilter_sql(text, jsonb) to service_role;
grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;
grant execute on function public.prospect_filter_sql_v1(text, jsonb) to service_role;

commit;
