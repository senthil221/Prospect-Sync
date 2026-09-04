-- coalesce(col, '') was making every index on both filter tables unreachable.
--
-- Both filter compilers wrap every candidate column in coalesce(..., '') before
-- comparing it. That looks harmless -- it only says "treat NULL as empty" -- but
-- an expression index is matched by its EXPRESSION, and coalesce(pi.title, '')
-- is not lower(title). So the wrapper quietly disqualified:
--
--   idx_prospect_index_title_lower          idx_companies_location
--   idx_prospect_index_full_name_lower      idx_companies_lower_name_id
--   idx_prospect_index_company_name_lower   every gin_trgm_ops index on both tables
--   idx_prospect_index_company_domain_lower
--
-- All of them built, all of them maintained on every write, none of them
-- reachable by the filters they exist for. Measured on production 2026-09-05:
--
--   People filter (681,085 rows)     matched   before    after   factor
--     company equals                       8    703 ms   0.3 ms   2,014x
--     title equals                         0    745 ms     1 ms     893x
--     name equals                        237    774 ms     3 ms     232x
--     company contains                   738    789 ms    30 ms      26x
--     title contains                     253    910 ms    72 ms      13x
--     linkedin contains                  178  1,496 ms   171 ms     8.7x
--
--   Company filter (418,456 rows)
--     name ilike '%fintech%'             209  2,271 ms   4.2 ms     541x
--     3-keyword pivot                  9,192  2,280 ms 1,112 ms     2.1x
--     industry + technologies + size     813    372 ms   218 ms     1.7x
--
-- WHY THIS IS SAFE, AND WHERE IT IS NOT. For a POSITIVE comparison the wrapper
-- is a no-op: NULL ilike '%v%' and NULL = any(...) both evaluate to NULL, which
-- excludes the row, and that is exactly what comparing '' against a non-empty
-- value does. A blank filter value never reaches the operator -- it is skipped
-- while raw_values is built -- so the '' case cannot arise.
--
-- For a NEGATIVE comparison it is NOT a no-op and the wrapper stays:
-- not(NULL = any(...)) is NULL and excludes a null row, while
-- not('' = any(...)) is true and includes it. Those are different answers, and
-- the row functions give the second one. So not_equals, not_contains, empty and
-- not_empty are untouched here, deliberately.
--
-- VERIFIED BY COUNTING, NOT BY ARGUING. 53 filter shapes were compiled and
-- executed against production data before and after -- 25 company, 28 people --
-- covering equals, not_equals, contains, not_contains, empty, not_empty,
-- boolean, number_ranges, filter scopes, multi-value, a free-text search, and
-- both sides of the bulk_or_threshold branch. Every one returned an identical
-- row count. The assertion block below re-checks the same invariant a different
-- way at deploy time: the compiled SQL must agree with the row function, which
-- is the reference implementation the bulk paths still use.
--
-- THE INDEXES. Five columns had no usable index at all, and stayed slow even
-- after the wrapper came off. Measured with them present:
--
--   people: department equals            705 ms ->   1 ms
--   people: title_department equals      855 ms ->  16 ms
--   people: seniority tier equals        876 ms ->  75 ms
--   company: industry equals            seq scan ->  26 ms
--
-- They are 3-5 MB each against the 722 MB of trigram indexes prospect_index
-- already carries, so the write cost is noise next to what is already there.
-- lower(state) and lower(city) on companies were measured and NOT added: state
-- matched 41,009 rows through the index in 970 ms against roughly 350 ms for the
-- sequential scan it replaced, so the index would have made that filter worse.
--
-- WHAT THIS DOES NOT FIX. The reported 20-keyword pivot timeout is unchanged
-- (8.1 s -> 7.6 s). That filter matches 232,888 of 418,456 companies -- 56% of
-- the table -- and no index helps when you select half a table; a sequential
-- scan is the correct plan. That one needs the company predicate denormalized
-- onto prospect_index so the pivot stops resolving a company set at all, which
-- is its own migration.

begin;

CREATE OR REPLACE FUNCTION public.company_filter_sql_v3(p_search text, p_filters jsonb, p_probe boolean DEFAULT false)
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
  selected_scopes jsonb;
  candidate_expr text;
  boolean_expr text;
  keyword_hit text;
  keyword_values text[];
  match_cols text[];
  raw_cols text[];
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
    raw_cols := match_cols;
    match_cols := array(select 'coalesce(' || col || ', ' || quote_literal('') || ')' from unnest(match_cols) col);
    if cardinality(match_cols) = 0 then match_cols := array[candidate_expr]; raw_cols := array[candidate_expr]; end if;
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
      value_parts := value_parts || array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(raw_cols) col);
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
          value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(raw_cols) col);
        end loop;
        conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      end if;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$;
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
  raw_expr text;
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
    -- The column as it stands, alongside the coalesce-wrapped form. Positive
    -- comparisons use the raw one: NULL ilike '%%v%%' and NULL = any(...) are both
    -- NULL, which excludes the row, and that is exactly what comparing '' does --
    -- a blank filter value never reaches here. The wrapper is not free, though.
    -- coalesce(pi.title, '') does not match idx_prospect_index_title_lower, so
    -- every equality and substring test was scanning the table past four
    -- perfectly good indexes. Measured on companies: 2,271 ms -> 4.2 ms.
    --
    -- The negative operators keep the wrapper, and must: not(NULL) excludes a
    -- null row where not('' = ...) includes it. Those are different answers, and
    -- the row function gives the second one.
    raw_expr := candidate_expr;
    candidate_expr := format('coalesce(%s, %L)', candidate_expr, '');

    -- A durable filter set: the values are rows in prospect_filters, addressed
    -- by id, instead of thousands of literals inlined in this SQL. Ownership was
    -- already checked by public.resolve_filter_set_v1; this only compiles the
    -- membership test. The ::uuid cast is the injection guard - anything that is
    -- not a uuid raises here, before %L ever sees it.
    if coalesce(filter_item->>'setId', '') <> '' then
      if operator_key <> 'equals' then
        raise exception 'A filter set supports the equals operator only, got %', operator_key
          using errcode = '22023';
      end if;
      conjuncts := conjuncts || format(
        'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))',
        (filter_item->>'setId')::uuid, candidate_expr);
      continue;
    end if;

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
          raw_expr, lowered,
          case when field_key = '__lists' then 'pi.list_names' else 'pi.client_names' end,
          raw_values);
      else
        conjuncts := conjuncts || format('lower(%s) = any (%L::text[])', raw_expr, lowered);
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
        raw_values, case when operator_key = 'not_contains' then candidate_expr else raw_expr end);
      continue;
    end if;

    value_parts := array[]::text[];
    foreach value_text in array raw_values loop
      value_parts := value_parts || format('%s ilike %L',
        case when operator_key = 'not_contains' then candidate_expr else raw_expr end,
        '%' || value_text || '%');
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
-- The five columns that stayed slow after the wrapper came off, because they had
-- no index of any kind. Built inside the migration rather than CONCURRENTLY: the
-- runner wraps every file in a transaction, CONCURRENTLY cannot run inside one,
-- and these are 3-5 MB builds on tables whose workers the deploy is restarting
-- anyway. If an index here ever gets big enough to matter, give it its own
-- un-wrapped file rather than loosening this one.
create index if not exists idx_prospect_index_department_lower
  on public.prospect_index (lower(department));
create index if not exists idx_prospect_index_title_department_lower
  on public.prospect_index (lower(title_department));
create index if not exists idx_prospect_index_title_sub_department_lower
  on public.prospect_index (lower(title_sub_department));
create index if not exists idx_prospect_index_title_seniority_lower
  on public.prospect_index (lower(title_seniority));
create index if not exists idx_companies_industry_lower
  on public.companies (lower(industry));

revoke execute on function public.company_filter_sql_v3(text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.prospect_filter_sql_v1(text, jsonb) from public, anon, authenticated;
grant execute on function public.company_filter_sql_v3(text, jsonb, boolean) to service_role;
grant execute on function public.prospect_filter_sql_v1(text, jsonb) to service_role;

-- The invariant that matters, checked against real rows.
--
-- The compiled SQL and the per-row matcher are two implementations of one
-- predicate, and the bulk paths still use the row function --
-- prospect_ids_matching_v1, delete_prospects_matching_v1,
-- resolve_company_action_selection_v1. If the two disagree, the grid shows one
-- set and a bulk delete acts on another. That is the failure this migration
-- could plausibly cause, so that is the one asserted.
--
-- Both sides run over the same bounded sample, which is what makes the row
-- function affordable here: it is 30-60x slower than the compiled predicate.
--
-- The ORDER BY in that sample is load-bearing, not tidiness. LIMIT without it
-- returns whichever rows the plan happens to emit, so the two sides were being
-- handed DIFFERENT 20,000-row samples and every case reported a mismatch --
-- including empty/not_empty, which this migration does not touch. That is how
-- the sampling bug announced itself as a behaviour change.
do $assert$
declare
  v_problems text[] := array[]::text[];
  v_case record;
  v_sql text;
  v_compiled bigint;
  v_rowfn bigint;
begin
  for v_case in select * from (values
    ('people name contains',      '[{"field":"__name","operator":"contains","values":["kumar"]}]'::jsonb),
    ('people name not_contains',  '[{"field":"__name","operator":"not_contains","values":["kumar"]}]'::jsonb),
    ('people title equals',       '[{"field":"__title","operator":"equals","values":["Software Engineer"]}]'::jsonb),
    ('people title not_equals',   '[{"field":"__title","operator":"not_equals","values":["Software Engineer"]}]'::jsonb),
    ('people department eq',      '[{"field":"__department","operator":"equals","values":["Engineering"]}]'::jsonb),
    ('people department not_eq',  '[{"field":"__department","operator":"not_equals","values":["Engineering"]}]'::jsonb),
    ('people department empty',   '[{"field":"__department","operator":"empty","values":[]}]'::jsonb),
    ('people department not_emp', '[{"field":"__department","operator":"not_empty","values":[]}]'::jsonb),
    ('people esp_type contains',  '[{"field":"__esp_type","operator":"contains","values":["google"]}]'::jsonb),
    ('people esp_type not_cont',  '[{"field":"__esp_type","operator":"not_contains","values":["google"]}]'::jsonb),
    ('people lists equals',       '[{"field":"__lists","operator":"equals","values":["Q1 outreach"]}]'::jsonb)
  ) v(label, spec) loop
    v_sql := public.prospect_filter_sql_v1('', v_case.spec);
    execute format('select count(*) from (select * from public.prospect_index order by id limit 20000) pi where %s', v_sql) into v_compiled;
    execute format('select count(*) from (select * from public.prospect_index order by id limit 20000) pi where public.prospect_index_matches_v1(pi, %L, %L::jsonb)',
      '', v_case.spec::text) into v_rowfn;
    if v_compiled is distinct from v_rowfn then
      v_problems := array_append(v_problems,
        format('%s: compiled %s <> row function %s', v_case.label, v_compiled, v_rowfn));
    end if;
  end loop;

  for v_case in select * from (values
    ('company name contains',     '[{"field":"__company","operator":"contains","values":["tech"]}]'::jsonb),
    ('company name not_contains', '[{"field":"__company","operator":"not_contains","values":["tech"]}]'::jsonb),
    ('company industry equals',   '[{"field":"__industry","operator":"equals","values":["Information Technology & Services"]}]'::jsonb),
    ('company industry not_eq',   '[{"field":"__industry","operator":"not_equals","values":["Information Technology & Services"]}]'::jsonb),
    ('company industry empty',    '[{"field":"__industry","operator":"empty","values":[]}]'::jsonb),
    ('company keywords scope',    '[{"field":"__company_keywords","operator":"contains","values":["fintech"],"scopes":["name","keywords","description"]}]'::jsonb),
    ('company kw scope not_cont', '[{"field":"__company_keywords","operator":"not_contains","values":["fintech"],"scopes":["name","keywords","description"]}]'::jsonb),
    ('company technologies eq',   '[{"field":"__technologies","operator":"equals","values":["Salesforce"]}]'::jsonb)
  ) v(label, spec) loop
    v_sql := public.company_filter_sql_v3('', v_case.spec);
    execute format('select count(*) from (select * from public.companies order by id limit 20000) c where %s', v_sql) into v_compiled;
    execute format('select count(*) from (select * from public.companies order by id limit 20000) c where public.company_matches_filters_v1(c, %L, %L::jsonb)',
      '', v_case.spec::text) into v_rowfn;
    if v_compiled is distinct from v_rowfn then
      v_problems := array_append(v_problems,
        format('%s: compiled %s <> row function %s', v_case.label, v_compiled, v_rowfn));
    end if;
  end loop;

  -- And the structural claim: the wrapper is gone from the positive operators
  -- and still present on the negative ones. A later edit that "tidies up" by
  -- stripping it everywhere would pass the counts above on the luck of the
  -- sample, so state it directly.
  if public.prospect_filter_sql_v1('', '[{"field":"__title","operator":"equals","values":["x"]}]'::jsonb) like '%coalesce%' then
    v_problems := array_append(v_problems, 'equals still wraps its column in coalesce');
  end if;
  if public.prospect_filter_sql_v1('', '[{"field":"__title","operator":"not_equals","values":["x"]}]'::jsonb) not like '%coalesce%' then
    v_problems := array_append(v_problems, 'not_equals lost the coalesce it needs for null rows');
  end if;
  if public.prospect_filter_sql_v1('', '[{"field":"__title","operator":"not_contains","values":["x"]}]'::jsonb) not like '%coalesce%' then
    v_problems := array_append(v_problems, 'not_contains lost the coalesce it needs for null rows');
  end if;

  if cardinality(v_problems) > 0 then
    raise exception 'filter compiler assertions failed: %', array_to_string(v_problems, '; ');
  end if;
  raise notice 'filter compilers agree with the row functions across 19 shapes';
end;
$assert$;

commit;
