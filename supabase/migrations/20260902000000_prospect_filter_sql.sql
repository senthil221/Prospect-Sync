-- Give prospect filters the complete-SQL path companies have had all along.
--
-- Reported as "Failed to fetch" on See Companies, and as statement timeouts when
-- several filters are combined. Both are the same shape.
--
-- Every prospect predicate exists twice: prospect_prefilter_sql emits indexable
-- SQL, and prospect_index_matches_v1 is the authoritative per-row test. The
-- prefilter narrows, then the row function is called once per surviving row.
-- That is fine for a page of 50, and ruinous whenever the whole match set is
-- needed -- a scope, a count, an export -- because every candidate pays a
-- non-inlinable function call.
--
-- Companies solved this: company_filter_sql_v2 returns a complete SQL
-- translation, and company_effective_filter_sql_v1 hands callers either that or
-- null. Callers that get SQL skip company_matches_filters_v1 entirely. The
-- prospect side never had an equivalent, so it always paid.
--
-- Measured on the reported filter (three title terms, resolving to companies):
--
--   prefilter only ......................  1,827 ms   94,864 companies
--   prefilter + prospect_index_matches_v1  60,039 ms   94,864 companies  (cancelled)
--
-- Identical answers, 33x apart. For contains the prefilter is already exact, so
-- the row function re-derives the same result one row at a time and contributes
-- nothing.
--
-- prospect_filter_sql_v1 translates a filter set into a single SQL expression
-- over the alias `pi`, or returns null when it meets a shape it cannot express
-- exactly. Null is the safe answer: callers fall back to the row function and
-- behave exactly as they do today, so a gap in coverage costs performance, never
-- correctness.
--
-- Deliberately not covered in this version:
--   * boolean -- the value is a compiled tsquery and the operator is the advanced
--     mode, already documented as slow and bounded rather than broken.
-- Everything else the row function implements is translated here, including the
-- __lists / __clients array equality special case, the concat and array_to_string
-- field shapes, custom: jsonb lookups, and __employee_count ranges.
--
-- Exactness notes, each mirroring prospect_index_matches_v1 rather than improving
-- on it:
--   * candidate values are coalesced to '' so a null column behaves as empty
--   * ILIKE patterns are not escaped, so % and _ in a filter value stay wildcards
--   * a filter carrying no values rejects every row for the value operators, which
--     is what the row function does; parseFilters strips those before they arrive,
--     so this only matters if one ever reaches the database another way
--   * an unmapped field yields '' and is compared as such

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
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('pi.search_text ilike %L', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    field_key := coalesce(filter_item->>'field', '');

    -- Boolean carries a compiled tsquery; leave the whole set to the row function
    -- rather than translating half of it.
    if operator_key = 'boolean' then return null; end if;

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

-- Same contract as company_effective_filter_sql_v1: the prefilter supplies the
-- index path, the complete predicate supplies exactness, and null means the
-- caller must keep using the row function.
CREATE OR REPLACE FUNCTION public.prospect_effective_filter_sql_v1(p_search text, p_filters jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
begin
  if v_complete is null then return null; end if;
  if v_prefilter <> 'true' then
    return '(' || v_prefilter || ') and (' || v_complete || ')';
  end if;
  return v_complete;
end;
$function$;

grant execute on function public.prospect_filter_sql_v1(text, jsonb) to service_role;
grant execute on function public.prospect_effective_filter_sql_v1(text, jsonb) to service_role;


-- The People-to-Companies pivot is the reported failure, so it adopts the new
-- path first. The prefilter still supplies the index route; the complete
-- predicate replaces the per-row call when it is available, and the row function
-- stays as the fallback for shapes that return null (today, Boolean).
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
  v_complete text;
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
  -- is unchanged -- but the authoritative predicate would be evaluated once per
  -- row of a 674k-row table to say so. Emit it only when it can exclude something.
  if btrim(v_search) <> '' or v_filters <> '[]'::jsonb then
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_sql := v_sql || ' and (' || coalesce(v_complete,
      format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  end if;
  v_sql := v_sql || format(' order by pi.company_id limit %s', v_limit);
  return query execute v_sql;
end;
$function$;

revoke execute on function public.people_scope_company_ids_v1(text, jsonb) from public, anon, authenticated;
grant execute on function public.people_scope_company_ids_v1(text, jsonb) to service_role;

commit;
