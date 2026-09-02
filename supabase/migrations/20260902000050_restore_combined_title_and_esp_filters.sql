-- Restore the two combined People filters the panel still offers.
--
-- ApolloFilterPanel offers "Job Title & Seniority" (__title_seniority) and "ESP"
-- (__esp_type). Both are virtual fields: each concatenates two columns so a
-- single include/exclude matches either value. 20260814060000 introduced them by
-- splicing the arms into the deployed definitions of
-- search_prospect_workspace_v7, search_prospect_export_v1 and
-- prospect_index_matches_v1.
--
-- 20260825010000 then recreated prospect_index_matches_v1 from scratch and the
-- splice went with it. 20260902000000 wrote prospect_filter_sql_v1 from the row
-- function as it stood, so the gap was inherited rather than introduced. Only
-- search_prospect_export_v1 -- never recreated since -- still carried them.
--
-- Measured on production at 20260902000030:
--
--   prospect_filter_sql_v1('', '[{"field":"__title_seniority",
--     "operator":"contains","values":["vp"]}]')
--     -> (coalesce('', '') ilike '%vp%')
--
-- An unmapped field compiles to the empty string, so both filters are ALWAYS
-- FALSE. The People grid has been silently returning nothing for two filters the
-- UI advertises, while an export of the same filter returned rows -- the grid and
-- the export disagreeing about the same question, which is the parity failure
-- Release 1A exists to close.
--
-- This is why routing exports to search_prospect_export_v4 needs this migration
-- alongside it: v4 compiles through prospect_filter_sql_v1, so without these two
-- arms the re-route would have made exports agree with the grid by breaking them
-- too, rather than by fixing the grid.
--
-- Both definitions below are the deployed ones (pg_get_functiondef at
-- 20260902000030) with two CASE arms added and nothing else changed. Written out
-- in full rather than spliced: 20260826050000 documents that a splice skips
-- silently when its anchor moves, which is exactly how these arms were lost.
--
-- prospect_prefilter_sql is deliberately untouched. It maps a field to a single
-- indexable column, and a concat of two columns cannot be index-served; it skips
-- fields it cannot map, which widens the pre-filter and leaves the authoritative
-- predicate to decide. That is already correct.
--
-- Neither function is SECURITY DEFINER (prosecdef = false on both), so their
-- existing grants are unchanged.

begin;

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
      -- Two virtual fields the People panel offers: each concatenates the two
      -- underlying columns so one include/exclude matches either value.
      when '__title_seniority' then 'concat_ws('' '', pi.title, pi.seniority)'
      when '__esp_type' then 'concat_ws('' '', pi.esp, pi.email_provider_type)'
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

CREATE OR REPLACE FUNCTION public.prospect_index_matches_v1(p_row prospect_index, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select (
    btrim(coalesce(p_search, '')) = ''
    or (p_row).search_text ilike '%' || btrim(p_search) || '%'
  ) and not exists (
    select 1
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
    cross join lateral (
      select coalesce(case filter_item->>'field'
        when '__name' then (p_row).full_name
        when '__first_name' then (p_row).first_name
        when '__last_name' then (p_row).last_name
        when '__company' then (p_row).company_name
        when '__company_domain' then (p_row).company_domain
        when '__email' then concat_ws(' ', (p_row).work_email, (p_row).personal_email)
        when '__work_email' then (p_row).work_email
        when '__personal_email' then (p_row).personal_email
        when '__title' then (p_row).title
        when '__keywords' then array_to_string((p_row).keywords, ' | ')
        when '__linkedin' then (p_row).linkedin_url
        when '__city' then (p_row).city
        when '__state' then (p_row).state
        when '__country' then (p_row).country
        when '__person_location' then coalesce(nullif((p_row).location, ''),
          concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, '')))
        when '__company_location' then concat_ws(', ', nullif((p_row).company_location, ''), nullif((p_row).company_city, ''), nullif((p_row).company_state, ''), nullif((p_row).company_country, ''))
        when '__company_city' then (p_row).company_city
        when '__company_state' then (p_row).company_state
        when '__company_country' then (p_row).company_country
        when '__seniority' then (p_row).seniority
        when '__department' then (p_row).department when '__title_department' then (p_row).title_department when '__title_sub_department' then (p_row).title_sub_department when '__title_seniority_tier' then (p_row).title_seniority
        when '__esp' then (p_row).esp
        when '__title_seniority' then concat_ws(' ', (p_row).title, (p_row).seniority)
        when '__esp_type' then concat_ws(' ', (p_row).esp, (p_row).email_provider_type)
        when '__email_provider_type' then (p_row).email_provider_type
        when '__tags' then (p_row).tag_text
        when '__last_contacted' then (p_row).last_contacted_at::text
        when '__lists' then array_to_string((p_row).list_names, ' | ')
        when '__clients' then array_to_string((p_row).client_names, ' | ')
        else case when filter_item->>'field' like 'custom:%' then coalesce((
          select string_agg(entry.value, ' | ' order by entry.key)
          from jsonb_each_text((p_row).all_data) entry(key, value)
          where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
        ), '') else '' end
      end, '') as candidate_value
    ) candidate
    where not case coalesce(filter_item->>'operator', 'contains')
      when 'equals' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
          or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
            case when filter_item->>'field' = '__lists' then (p_row).list_names else (p_row).client_names end
          ))
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
        where filter_item->>'field' = '__employee_count'
          and ((selected.value = 'unknown' and (p_row).employee_count_min is null and (p_row).employee_count_max is null)
            or (selected.value <> 'unknown' and (p_row).employee_count_min is not null
              and (selected_range.maximum is null or (p_row).employee_count_min <= selected_range.maximum)
              and ((p_row).employee_count_max is null or (p_row).employee_count_max >= selected_range.minimum)))
      )
      when 'empty' then btrim(candidate.candidate_value) = ''
      when 'not_empty' then btrim(candidate.candidate_value) <> ''
      else exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
    end
  );
$function$;

commit;
