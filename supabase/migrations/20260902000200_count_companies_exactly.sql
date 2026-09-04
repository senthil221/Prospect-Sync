-- Stop saying "50,000+". Count the companies, say how many there are.
--
-- WHY THE CAP EXISTED. Counting to a ceiling lets the scan stop as soon as it
-- has found 50,001 matches, so a broad filter never looked at the rest of the
-- table. That is genuinely why broad searches were fast, and removing it means
-- evaluating the predicate on all 419,214 rows. Measured, exact and uncapped,
-- with the better shape for each class:
--
--   matches    keywords-first chain    index probe
--    22,662          72.9 s              2.3 s
--    29,227         timed out            5.1 s
--   240,777          34.1 s             22.4 s
--   278,607          37.3 s             32.2 s
--   319,443           6.9 s             12.7 s
--   333,050          10.8 s             26.9 s
--
-- So exactness is affordable everywhere, but the shape has to be chosen, and the
-- boundary is NOT the one 20260902000190 uses. That migration picks a shape for
-- a CAPPED count, where the chain wins from 40% of the table upward because it
-- exits early. Counting exactly there is no early exit, so the chain only wins
-- once it is very broad -- above about 72%, between the 65.1% and 79.9% samples
-- either side of the crossover. Same classifier, different threshold, because it
-- is answering a different question.
--
-- TWO BUGS DIE WITH THE CAP.
--
-- covered_count and prospect_total were computed over `limit 50001` with no
-- ORDER BY, so above the cap they described whichever arbitrary 50,001 rows the
-- plan emitted. Two identical calls against production returned
-- covered=24874/prospects=58020 and then covered=13365/prospects=34815 -- a 2x
-- swing on refresh, presented as exact. Counting everything makes them exact and
-- stable; there is no sample left to be arbitrary about.
--
-- And "Total linked prospects: across all matching companies" becomes true. It
-- was summed over the capped sample.
--
-- THE ONE CHEAP TEST NOW RUNS FIRST. company_filter_sql_v3 appended the indexed
-- `c.keywords && ARRAY[...]` disjunct LAST, after every ILIKE, so a row that
-- matched on keywords still paid the whole substring chain before reaching it.
-- Postgres short-circuits an OR left to right, so moving it to the front is a
-- pure reordering with byte-identical results:
--
--   mid50, capped     12.6 s -> 5.8 s
--   mid120, capped    18.5 s -> 7.3 s
--   broad120, capped   6.4 s -> 1.7 s
--
-- PAID ONCE, NOT EVERY TIME. An exact count of a quarter-million matches costs
-- real seconds no matter how it is shaped, so filter_companies_v4 joins the
-- versioned count cache from 20260902000070: the caller passes the versions it
-- already has an answer for, and when the data has not moved since, the count is
-- skipped and total_count comes back null for the client to fill from its cache.
-- Both entities are asked for, not just company -- companies.prospect_count is
-- maintained by a trigger on prospect_index, so a prospect import changes
-- covered_count and prospect_total without touching a company row.

begin;

-- Keyword-first ordering. Only the disjunct order changes; every branch tests
-- exactly what it tested before.
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

    -- Mirrors the row function: with no values only the emptiness tests mean
    -- anything, and every other operator is a no-op rather than a rejection.
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
      -- Substring scopes only; keywords are matched exactly, below.
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      candidate_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      -- Match each substring scope against its OWN column rather than against a
      -- concatenation of them, so "description contains X" is about the
      -- description and not about a string spanning the ' | ' join.
      match_cols := scope_parts;

      -- Boolean search keeps spanning keywords as text.
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'keywords' then scope_parts := array_append(scope_parts, 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      boolean_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      if selected_scopes ? 'keywords' and cardinality(raw_values) > 0 then
        keyword_hit := format('c.keywords && %L::text[]', raw_values);
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
      -- An unknown field makes the row function compare against '', so nothing
      -- matches. Rather than encode that, refuse and let the caller fall back.
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
      -- Indexed array overlap first: an OR short-circuits left to right, so a row
      -- that matches on keywords never evaluates the rest.
      value_parts := case when keyword_hit <> 'false' then array[keyword_hit] else array[]::text[] end;
      value_parts := value_parts || array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      if field_key = '__keywords' then
        value_parts := value_parts || format('c.keywords && %L::text[]', raw_values);
      elsif field_key = '__technologies' then
        value_parts := value_parts || format('c.technologies && %L::text[]', raw_values);
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
        -- Indexed array overlap first, for the same short-circuit reason.
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

-- The return type gains data_versions, so the function has to be replaced rather
-- than redefined. The only in-repo caller is app/api/companies/route.ts, which
-- reads fields by name.
drop function if exists public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer);

create function public.filter_companies_v4(
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null::text,
  p_people_scope jsonb default null::jsonb,
  p_limit integer default 50,
  p_offset integer default 0,
  p_known_versions jsonb default null::jsonb
)
 returns table(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer, total_capped boolean, data_versions jsonb)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counting_clause text;
  v_probe text;
  v_fraction numeric;
  v_value_count integer;
  v_sample_rows integer;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_ctes text[] := array[]::text[];
  v_cte_sql text;
  v_join text;
  v_prospect_expr text;
  v_client_expr text;
  v_where text;
  v_where_counting text;
  v_scope_suffix text := '';
  v_complete text;
  v_versions jsonb;
  v_want_total boolean;
  v_sql text;
  -- Counting exactly there is no early exit, so the OR chain only wins once the
  -- filter is very broad. Measured either side of the crossover: at 65.1% of the
  -- table the probe won 32.2s to 37.3s, at 79.9% the chain won 6.9s to 12.7s.
  -- 20260902000190's 0.40 is the boundary for a CAPPED count and is a different
  -- question -- there the chain exits early and wins much sooner.
  v_broad_fraction constant numeric := 0.72;
begin
  -- companies.prospect_count is kept current by a trigger on prospect_index, so
  -- covered_count and prospect_total move when prospects change even though no
  -- company row was touched. Both entities gate this cache.
  v_versions := public.data_versions_v1(array['company', 'prospect']);
  v_want_total := p_known_versions is null or p_known_versions <> v_versions;

  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  -- Shape for the counting scan only; the page always keeps the OR chain,
  -- which walks idx_companies_prospect_ranking and stops at fifty.
  v_counting_clause := v_match_clause;
  if v_complete is not null and v_want_total then
    v_probe := public.company_probe_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
    if v_probe is not null then
      select coalesce(max(cardinality(v)), 0) into v_value_count
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) f
      cross join lateral (select array(select jsonb_array_elements_text(f.value->'values'))) s(v);
      v_sample_rows := greatest(120, least(400, 60000 / greatest(v_value_count, 1)));
      begin
        execute format(
          'select coalesce(avg(case when %s then 1.0 else 0.0 end), 1.0) from '
          || '(select * from public.companies tablesample system (0.05) repeatable (1) limit %s) c',
          v_match_clause, v_sample_rows) into v_fraction;
        if v_fraction < v_broad_fraction then
          v_counting_clause := v_probe;
        end if;
      exception when others then
        v_counting_clause := v_match_clause;
      end;
    end if;
  end if;

  if p_client_id is null then
    v_join := '';
    v_prospect_expr := 'c.prospect_count';
    v_client_expr := 'c.client_count';
  else
    v_ctes := array_append(v_ctes, format($counts$client_counts as (
        select pi.company_id,
          count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) cid on true
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      )$counts$, p_client_id));
    v_join := ' left join client_counts k on k.company_id = c.id';
    v_prospect_expr := 'coalesce(k.prospect_count, 0)';
    v_client_expr := 'coalesce(k.client_count, 0)';
  end if;

  if p_client_id is not null then
    v_scope_suffix := v_scope_suffix || format($e$ and exists (
      select 1 from public.prospect_index scoped
      where scoped.company_id = c.id and scoped.client_ids @> array[%L]
    )$e$, p_client_id);
  end if;
  if p_people_scope is not null then
    v_ctes := array_append(v_ctes, format($s$scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(%L, %L::jsonb)
      )$s$, p_client_id, p_people_scope::text));
    v_scope_suffix := v_scope_suffix || ' and c.id in (select company_id from scope_ids)';
  end if;

  v_where := format('(%s)', v_match_clause) || v_scope_suffix;
  v_where_counting := format('(%s)', v_counting_clause) || v_scope_suffix;

  v_cte_sql := case when cardinality(v_ctes) > 0
    then array_to_string(v_ctes, ', ') || ', ' else '' end;

  -- No LIMIT on the counting scan: the numbers are exact, which is the point,
  -- and is also what makes covered_count and prospect_total stable. When the
  -- caller already holds an answer for these versions the scan is skipped
  -- entirely and the three numbers come back null.
  v_sql := format($query$
    with %1$s page as (
      select c.id, c.name, c.domain, c.created_at,
        %2$s as prospect_count, %3$s as client_count
      from public.companies c%4$s
      where %5$s
      order by %2$s desc, lower(c.name), c.id
      offset %6$s limit %7$s
    ), counted as (
      select count(*)::integer as total_count,
        count(*) filter (where %2$s > 0)::integer as covered_count,
        coalesce(sum(%2$s), 0)::integer as prospect_total
      from public.companies c%4$s
      where %8$s and %9$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id)
        from page
      ), '[]'::jsonb),
      case when %9$s then counted.total_count end,
      case when %9$s then counted.covered_count end,
      case when %9$s then counted.prospect_total end,
      false,
      %10$L::jsonb
    from counted
  $query$, v_cte_sql, v_prospect_expr, v_client_expr, v_join, v_where,
       v_offset::text, v_limit::text, v_where_counting, v_want_total::text, v_versions::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer, jsonb) from public, anon, authenticated;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer, jsonb) to service_role;

commit;
