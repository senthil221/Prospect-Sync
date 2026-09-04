-- The ESP filter's "equals" matched nothing, on almost every row.
--
-- __esp_type and __title_seniority are virtual fields: their candidate value is
-- concat_ws(' ', esp, email_provider_type) and concat_ws(' ', title, seniority).
-- For a substring test that join is exactly right -- "contains google" should
-- hit either half, and matches that span the join are real matches.
--
-- For an EQUALITY test it is nonsense. 649,288 of 681,085 prospects have both
-- columns populated, so the value being compared is always a two-part string:
--
--   microsoft 365 mailbox provider      245,111
--   google workspace mailbox provider   217,844
--   custom / unknown unknown             76,820
--   zoho mail mailbox provider           24,941
--
-- Nothing a person could reasonably type ever equalled that. Filtering ESP for
-- "google workspace" returned zero rows, and the panel's own description says
-- "Matches the ESP or the email provider type".
--
-- NOBODY CAN BE RELYING ON THE OLD BEHAVIOUR. prospect_filter_values_v3 returns
-- no suggestions at all for these two fields -- against 10 values for __esp and
-- 4 for __email_provider_type -- so the joined string was undiscoverable through
-- the UI. A saved view would have had to contain a hand-typed full
-- concatenation, and it would have been returning nothing ever since.
--
-- WHAT CHANGES, MEASURED. Over a 40,000-row sample on production:
--
--   filter                                  before    after
--   esp_type equals "google workspace"           0   12,815
--   esp_type equals "mailbox provider"           0   29,064
--   esp_type equals both values                  0   15,544
--   esp_type not_equals "google workspace"  40,000   27,185
--   title_seniority equals "manager"             0      717
--   title_seniority not_equals "manager"    40,000   39,283
--
-- The complements are exact -- 40,000 - 12,815 = 27,185 and
-- 40,000 - 717 = 39,283 -- so not_equals is still precisely the negation of
-- equals rather than an independently written predicate that happens to look
-- right.
--
-- WHAT DOES NOT CHANGE. contains, not_contains, empty, not_empty and boolean on
-- these two fields all keep the concatenation, because narrowing a substring
-- test to per-column WOULD lose matches that legitimately span the join. And
-- every other field is untouched: name, title, department, email and lists were
-- all measured before and after and returned identical counts.
--
-- BOTH FUNCTIONS MOVE TOGETHER, WHICH IS THE WHOLE RISK. prospect_index_matches_v1
-- is the reference implementation and it is what the bulk paths still use --
-- prospect_ids_matching_v1 and delete_prospects_matching_v1. Changing only the
-- SQL compiler would mean the grid shows one set and a bulk delete acts on
-- another. They are changed identically here, and the assertion block below
-- checks all fifteen shapes agree between them before this commits.
--
-- THE INDEXES. Equality against the underlying columns is finally indexable,
-- where the concatenation never could be -- concat_ws is STABLE, not IMMUTABLE,
-- so Postgres refuses to build an index on it at all. Two indexable disjuncts
-- let the planner use a BitmapOr: measured 800 ms of sequential scan down to
-- 0.080 ms. lower(title) already exists from an earlier migration.

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
  raw_expr text;
  match_exprs text[];
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
    -- The two virtual fields whose candidate is a concatenation of two real
    -- columns. For a substring test the join is exactly right -- "contains
    -- google" should hit either half. For an EQUALITY test it is nonsense: the
    -- value is always "google workspace mailbox provider", so nothing a person
    -- could type ever equalled it, on 649,288 of 681,085 rows. The panel offers
    -- no suggestions for these two fields either (prospect_filter_values_v3
    -- returns nothing for them, against 10 values for __esp and 4 for
    -- __email_provider_type), so there was no way to discover the joined string
    -- and no saved view can be relying on it.
    --
    -- Equality therefore tests the underlying columns instead, which is what the
    -- filter's own description has always promised: "Matches the ESP or the
    -- email provider type". Substring tests keep the concatenation, because
    -- narrowing those WOULD lose matches that span the join.
    match_exprs := case field_key
      when '__esp_type' then array['pi.esp', 'pi.email_provider_type']
      when '__title_seniority' then array['pi.title', 'pi.seniority']
      else null
    end;
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
      elsif match_exprs is not null then
        conjuncts := conjuncts || ('(' || array_to_string(
          array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_exprs) col),
          ' or ') || ')');
      else
        conjuncts := conjuncts || format('lower(%s) = any (%L::text[])', raw_expr, lowered);
      end if;
      continue;
    elsif operator_key = 'not_equals' then
      if match_exprs is not null then
        -- The exact negation of the branch above, so not_equals stays the
        -- complement of equals. coalesce is back: not(NULL = any(...)) would
        -- drop a row whose column is null, and the row function keeps it.
        conjuncts := conjuncts || ('(not (' || array_to_string(
          array(select format('lower(coalesce(%s, %L)) = any (%L::text[])', col, '', lowered) from unnest(match_exprs) col),
          ' or ') || '))');
      else
        conjuncts := conjuncts || format('not (lower(%s) = any (%L::text[]))', candidate_expr, lowered);
      end if;
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
      end, '') as candidate_value,
      -- Non-null only for the virtual concat fields; see prospect_filter_sql_v1.
      -- Equality is answered against these instead of the joined string, and
      -- both functions have to agree or the grid and a bulk delete act on
      -- different sets.
      case filter_item->>'field'
        when '__esp_type' then array[coalesce((p_row).esp, ''), coalesce((p_row).email_provider_type, '')]
        when '__title_seniority' then array[coalesce((p_row).title, ''), coalesce((p_row).seniority, '')]
        else null::text[]
      end as candidate_parts
    ) candidate
    where not case coalesce(filter_item->>'operator', 'contains')
      when 'equals' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where (case when candidate.candidate_parts is null
                 then lower(candidate.candidate_value) = lower(selected.value)
                 else exists (select 1 from unnest(candidate.candidate_parts) part
                              where lower(part) = lower(selected.value)) end)
          or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
            case when filter_item->>'field' = '__lists' then (p_row).list_names else (p_row).client_names end
          ))
      )
      when 'not_equals' then not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where (case when candidate.candidate_parts is null
                 then lower(candidate.candidate_value) = lower(selected.value)
                 else exists (select 1 from unnest(candidate.candidate_parts) part
                              where lower(part) = lower(selected.value)) end)
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
-- Equality against these columns is reachable by an index for the first time;
-- the concatenation never could be, because concat_ws is STABLE and Postgres
-- refuses to index a non-IMMUTABLE expression. lower(title) already exists.
create index if not exists idx_prospect_index_esp_lower
  on public.prospect_index (lower(esp));
create index if not exists idx_prospect_index_email_provider_type_lower
  on public.prospect_index (lower(email_provider_type));
create index if not exists idx_prospect_index_seniority_lower
  on public.prospect_index (lower(seniority));

revoke execute on function public.prospect_filter_sql_v1(text, jsonb) from public, anon, authenticated;
grant execute on function public.prospect_filter_sql_v1(text, jsonb) to service_role;

do $assert$
declare
  v_problems text[] := array[]::text[];
  v_case record;
  v_sql text;
  v_compiled bigint;
  v_rowfn bigint;
begin
  -- The two implementations must agree, including on the operators this
  -- migration deliberately leaves alone. The sample is ordered because LIMIT
  -- alone does not guarantee the two sides see the same rows.
  for v_case in select * from (values
    ('esp_type equals',           '[{"field":"__esp_type","operator":"equals","values":["google workspace"]}]'::jsonb),
    ('esp_type equals multi',     '[{"field":"__esp_type","operator":"equals","values":["google workspace","seg"]}]'::jsonb),
    ('esp_type not_equals',       '[{"field":"__esp_type","operator":"not_equals","values":["google workspace"]}]'::jsonb),
    ('esp_type contains',         '[{"field":"__esp_type","operator":"contains","values":["google"]}]'::jsonb),
    ('esp_type not_contains',     '[{"field":"__esp_type","operator":"not_contains","values":["google"]}]'::jsonb),
    ('esp_type empty',            '[{"field":"__esp_type","operator":"empty","values":[]}]'::jsonb),
    ('esp_type not_empty',        '[{"field":"__esp_type","operator":"not_empty","values":[]}]'::jsonb),
    ('title_seniority equals',    '[{"field":"__title_seniority","operator":"equals","values":["manager"]}]'::jsonb),
    ('title_seniority not_equals','[{"field":"__title_seniority","operator":"not_equals","values":["manager"]}]'::jsonb),
    ('title_seniority contains',  '[{"field":"__title_seniority","operator":"contains","values":["director"]}]'::jsonb),
    ('untouched name equals',     '[{"field":"__name","operator":"equals","values":["Rahul Sharma"]}]'::jsonb),
    ('untouched title equals',    '[{"field":"__title","operator":"equals","values":["Software Engineer"]}]'::jsonb),
    ('untouched dept not_equals', '[{"field":"__department","operator":"not_equals","values":["Engineering"]}]'::jsonb),
    ('untouched email contains',  '[{"field":"__email","operator":"contains","values":["gmail"]}]'::jsonb),
    ('untouched lists equals',    '[{"field":"__lists","operator":"equals","values":["Q1 outreach"]}]'::jsonb)
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

  -- not_equals must be the exact complement of equals, not a lookalike written
  -- separately. Anything else and "exclude Google Workspace" quietly disagrees
  -- with "is Google Workspace" about the rows in between.
  execute $q$select count(*) from (select * from public.prospect_index order by id limit 20000) pi
    where $q$ || public.prospect_filter_sql_v1('', '[{"field":"__esp_type","operator":"equals","values":["google workspace"]}]'::jsonb) into v_compiled;
  execute $q$select count(*) from (select * from public.prospect_index order by id limit 20000) pi
    where $q$ || public.prospect_filter_sql_v1('', '[{"field":"__esp_type","operator":"not_equals","values":["google workspace"]}]'::jsonb) into v_rowfn;
  if v_compiled + v_rowfn <> 20000 then
    v_problems := array_append(v_problems,
      format('equals (%s) + not_equals (%s) = %s, expected 20000', v_compiled, v_rowfn, v_compiled + v_rowfn));
  end if;

  -- And the structural claim, so a later edit cannot quietly put the
  -- concatenation back on the equality path.
  if public.prospect_filter_sql_v1('', '[{"field":"__esp_type","operator":"equals","values":["x"]}]'::jsonb) like '%concat_ws%' then
    v_problems := array_append(v_problems, 'esp_type equals still compares against the concatenation');
  end if;
  if public.prospect_filter_sql_v1('', '[{"field":"__esp_type","operator":"contains","values":["x"]}]'::jsonb) not like '%concat_ws%' then
    v_problems := array_append(v_problems, 'esp_type contains lost the concatenation it needs for spanning matches');
  end if;

  if cardinality(v_problems) > 0 then
    raise exception 'esp_type/title_seniority assertions failed: %', array_to_string(v_problems, '; ');
  end if;
  raise notice 'virtual concat fields: both implementations agree across 15 shapes, and not_equals complements equals exactly';
end;
$assert$;

commit;
