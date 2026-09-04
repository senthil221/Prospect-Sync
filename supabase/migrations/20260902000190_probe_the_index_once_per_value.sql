-- Give the company count a second plan shape, and let the estimate choose.
--
-- THE REPORT. "Company keywords" with the description scope and 50 pasted
-- keywords returned "This filter combination took longer than the database
-- allows." pg_stat_statements agrees it is not a one-off: the PostgREST call
-- carrying filter_companies_v4 shows 69 calls, 5.6s mean, 25.7s max.
--
-- WHY. The predicate is a row filter. 50 values across the name and description
-- scopes emit 100 ILIKEs, each re-tested per row, over 419,214 companies whose
-- short_description averages 531 characters. A trigram index answers "which rows
-- contain this needle"; the query asks "does this row contain any needle",
-- 419,214 separate times, so neither idx_companies_name_trgm nor
-- idx_companies_short_description_trgm can help and the cost is values x rows.
--
-- The alternative is a semi-join driven by the value list, where the needle is
-- the driver and the index is what gets read, so the cost is values x matches:
--
--   c.id in (
--     select p.id from public.companies p where p.keywords && ARRAY[...]
--     union
--     select p.id from unnest(ARRAY[...]) needle
--       join public.companies p on p.name ilike '%' || needle || '%'
--     union
--     select p.id from unnest(ARRAY[...]) needle
--       join public.companies p on p.short_description ilike '%' || needle || '%'
--   )
--
-- WHICH IS WHY THIS IS NOT A REPLACEMENT. Measured on the live table, the two
-- shapes are complementary and neither wins outright -- page is the top-50 scan,
-- count is the scan capped at 50,001, and filter_companies_v4 runs both:
--
--                      page + count, OR chain      page + count, probe
--   selective terms      0.25s + 19.2s = 19.5s      2.3s + 2.3s =  4.6s
--   broad terms          0.07s +  4.1s =  4.2s     12.5s + 12.1s = 24.6s
--
-- Broad needles make the index useless: each one matches about a quarter of the
-- table, so probing reads more than scanning does. Selective needles make the
-- scan useless: nothing matches early, so every row pays all 100 ILIKEs.
-- Swapping one shape for the other would have traded the reported timeout for a
-- different one, on a filter that works today.
--
-- END TO END through filter_companies_v4, before and after, same inputs, with
-- the shape each one was given. Every case returned the same total_count:
--
--   case                        shape     sampled   before    after
--   sel120 name+kw+desc         probe        9.5%   73.0 s    5.8 s
--   sel60 short_description     probe        5.8%   64.2 s    2.6 s
--   sel60 not_contains          probe        5.8%   20.2 s    3.0 s
--   sel60 name+kw+desc, page 3  probe        5.8%   19.6 s    3.1 s
--   sel60 name+kw+desc          probe        5.8%   19.4 s    2.6 s
--   sel60 description only      probe        5.8%   16.9 s    2.3 s
--   sel30 name+kw+desc          probe        5.8%    9.8 s    1.6 s
--   mid50 name+kw+desc          chain       58.2%   13.3 s   13.5 s
--   broad120 name+kw+desc       chain       81.0%    6.7 s    6.6 s
--   broad50 name+kw+desc        chain       79.9%    3.7 s    4.4 s
--
-- THE LIMIT OF THIS FIX, stated rather than implied: mid-frequency sets stay at
-- 13s. Neither shape helps there -- the terms are common enough that probing
-- reads most of the index, selective enough that scanning still checks every
-- row. That wants the side table the revert in 20260831230000 sketched out
-- (company_id plus tsvector, joined only when a keyword filter is present, so
-- the vector never sits in the heap every other query scans). Separate work.
--
-- WHAT THIS DOES INSTEAD. Two decisions, taken separately:
--
--   * page keeps the OR chain unconditionally. It is fast in BOTH cases (0.07s
--     and 0.25s) because it walks idx_companies_prospect_ranking in
--     prospect_count order and stops at fifty. There is nothing to fix there,
--     and the probe shape is 10x to 180x worse at it.
--
--   * the capped count picks its shape from the planner's own estimate of the OR
--     chain -- one EXPLAIN, 1-3ms, nothing executed.
--
-- THE ESTIMATE IS USED FOR THE ONE THING IT IS GOOD AT. It is a poor absolute
-- predictor: it guessed 53,221 rows for a selective set that really matched
-- 21,989, because it assumes independence across a hundred OR'd conditions and
-- inflates the union. So the rule is NOT "will this reach the 50,001 cap", which
-- that error would get wrong in exactly the case that matters. It is "does this
-- match a large FRACTION of the table", where the same saturation that causes
-- the error makes the two classes unmistakable: a broad set estimates at 99.7%
-- of the table, a selective one at 12.7%.
--
-- A wrong guess costs speed, never correctness: both shapes are the same
-- predicate, and the differential test over 18 filter cases -- every scope
-- combination, contains/not_contains/equals, above and below the threshold, plus
-- the unindexed-column and wildcard-value fallbacks -- returned identical match
-- sets for all of them.
--
-- WHAT IS DELIBERATELY UNTOUCHED. company_prefilter_sql keeps its current
-- behaviour exactly. An earlier cut of this migration had it stand down for
-- many-valued filters, which cost __company_location its prefilter for nothing
-- -- it has no index matching the coalesce over city/state/country that it
-- tests, so it never gained a probe to compensate: 73ms to 1790ms. The probe
-- predicate simply does not include the prefilter, because the complete
-- predicate is authoritative on its own; the OR-chain path is byte-for-byte what
-- it is today.

begin;

-- ONE definition of which filters can be probed, so the builder and anything
-- that reasons about it cannot drift apart.
create or replace function public.company_probe_columns_v1(p_field text, p_scopes jsonb)
returns text[]
language sql
immutable
security invoker
set search_path = public
as $function$
  select case
    when p_field = '__company_keywords' then
      -- Substring scopes only. The keywords scope is an array overlap and is
      -- carried as its own branch.
      (case when coalesce(p_scopes, '["name","keywords"]'::jsonb) ? 'name' then array['name'] else array[]::text[] end)
      || (case when coalesce(p_scopes, '["name","keywords"]'::jsonb) ? 'description' then array['short_description'] else array[]::text[] end)
    -- Only columns carrying a trigram index of their own. __company_location is
    -- deliberately absent: idx_companies_location covers c.location, not the
    -- coalesce over city/state/country that the filter actually tests. So are
    -- __keywords and __technologies, whose filters test array_to_string(...).
    -- Probing an unindexed column turns one sequential scan into several.
    when p_field = '__company' then array['name']
    when p_field = '__website' then array['domain']
    when p_field = '__industry' then array['industry']
    when p_field = '__company_city' then array['city']
    when p_field = '__company_state' then array['state']
    when p_field = '__company_country' then array['country']
    when p_field = '__short_description' then array['short_description']
    when p_field = '__total_funding' then array['total_funding']
    else array[]::text[]
  end;
$function$;

create or replace function public.company_filter_is_probed_v1(
  p_field text, p_scopes jsonb, p_operator text, p_values text[]
)
returns boolean
language sql
immutable
security invoker
set search_path = public
as $function$
  select p_operator in ('contains', 'not_contains')
    -- Below this many values the planner can still BitmapOr the trigram indexes
    -- from an OR chain, and the chain plans faster than a semi-join.
    and cardinality(coalesce(p_values, array[]::text[])) >= 8
    -- The row form tests coalesce(col, '') ilike '%v%', so a NULL column behaves
    -- as ''. The probe form lets NULL fail the join. Those agree for every value
    -- except one made entirely of '%', which matches the empty string. Such a
    -- value keeps the OR chain rather than being quietly redefined.
    and not exists (select 1 from unnest(coalesce(p_values, array[]::text[])) v where v ~ '^%+$')
    and cardinality(public.company_probe_columns_v1(p_field, p_scopes)) > 0;
$function$;

-- Builds the semi-join for a set of columns and values. Returns null when there
-- is nothing to probe, so the caller falls back to the OR chain.
--
-- union, not union all: the branches overlap heavily, and de-duplicating before
-- the semi-join measured better than handing the duplicates to it.
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
    branches := array_append(branches, format(
      'select p.id from public.companies p where p.keywords && %L::text[]', p_keyword_values));
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

-- The filter translator, now able to emit either shape. p_probe false reproduces
-- company_filter_sql_v2 exactly, which is what every existing caller keeps
-- getting.
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
      -- concatenation of them. Two reasons. It agrees with company_prefilter_sql,
      -- which emits per-column predicates so the trigram indexes apply -- and the
      -- two are ANDed, so a row matching only across the ' | ' join was accepted
      -- here and then dropped there. And it is what the filter means: "description
      -- contains X" should be about the description, not about a string that
      -- happens to span the end of the name and the start of it.
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
      -- matches. Rather than encode that, refuse and let the caller fall back:
      -- a silently empty listing is a worse failure than a slow one.
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

    -- Only contains and not_contains grew with values x rows. equals is already
    -- an indexed array-membership test and the rest are per-row by nature.
    probe_sql := null;
    if coalesce(p_probe, false)
       and public.company_filter_is_probed_v1(field_key, selected_scopes, operator_key, raw_values) then
      probe_sql := public.company_substring_probe_sql_v1(
        public.company_probe_columns_v1(field_key, selected_scopes), raw_values, keyword_values);
    end if;

    if operator_key = 'equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      if field_key = '__keywords' then
        value_parts := value_parts || format('c.keywords && %L::text[]', raw_values);
      elsif field_key = '__technologies' then
        value_parts := value_parts || format('c.technologies && %L::text[]', raw_values);
      end if;
      if keyword_hit <> 'false' then value_parts := value_parts || keyword_hit; end if;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'not_equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));

    elsif operator_key = 'not_contains' then
      if probe_sql is not null then
        -- The probe already carries the keyword branch, and c.id is the primary
        -- key, so it is never null and this is an anti-join rather than NOT IN's
        -- three-valued trap.
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
        value_parts := array[]::text[];
        foreach value_text in array raw_values loop
          value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(match_cols) col);
        end loop;
        if keyword_hit <> 'false' then value_parts := value_parts || keyword_hit; end if;
        conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      end if;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$;

-- Unchanged for every existing caller: the OR chain, exactly as before.
create or replace function public.company_filter_sql_v2(p_search text, p_filters jsonb)
returns text
language sql
stable
security invoker
set search_path = public
as $function$
  select public.company_filter_sql_v3(p_search, p_filters, false);
$function$;

-- The probe-shaped predicate, or null when no filter in the set can be probed
-- and there is therefore no second shape to choose between.
--
-- It deliberately does NOT carry company_prefilter_sql. The complete predicate
-- is authoritative on its own, and the prefilter's OR chain is the very scan
-- this shape exists to avoid.
create or replace function public.company_probe_filter_sql_v1(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $function$
declare
  filter_item jsonb;
  raw_values text[];
  value_text text;
  scopes jsonb;
  probeable boolean := false;
begin
  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    scopes := case
      when filter_item->>'field' <> '__company_keywords' then null
      when jsonb_typeof(filter_item->'scopes') = 'array'
        then case when jsonb_array_length(filter_item->'scopes') > 0
          then filter_item->'scopes' else '["name","keywords"]'::jsonb end
      else '["name","keywords"]'::jsonb
    end;
    if public.company_filter_is_probed_v1(filter_item->>'field', scopes,
         coalesce(filter_item->>'operator', 'contains'), raw_values) then
      probeable := true;
      exit;
    end if;
  end loop;

  if not probeable then return null; end if;
  return public.company_filter_sql_v3(p_search, p_filters, true);
end;
$function$;

-- The listing, now choosing a shape per scan instead of using one for both.
--
-- page and capped were built from the same v_where. They no longer are: page
-- keeps the OR chain because the ranking index makes it fast whatever the
-- selectivity, and only capped -- the scan that has to look at everything when
-- little matches -- is allowed the probe shape.
CREATE OR REPLACE FUNCTION public.filter_companies_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer, total_capped boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_capped_clause text;
  v_probe text;
  v_fraction numeric;
  v_value_count integer;
  v_sample_rows integer;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_count_cap text;
  v_ctes text[] := array[]::text[];
  v_cte_sql text;
  v_join text;
  v_prospect_expr text;
  v_client_expr text;
  v_where text;
  v_where_capped text;
  v_scope_suffix text := '';
  v_complete text;
  v_sql text;
  -- Above this share of the table the OR chain wins: enough rows match that its
  -- scan exits early, while the probe has to read most of the index to find
  -- them. Below it the chain has to look at every row and the probe does not.
  -- Measured match fractions were 5.8-9.5% for selective keyword sets and
  -- 58.2-81.0% for mid and broad ones, so the boundary sits in an empty gap
  -- rather than on a slope.
  v_broad_fraction constant numeric := 0.40;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  -- The second shape, taken only for the capped count and only when the
  -- estimate says few rows match. Both shapes are the same predicate, so a
  -- wrong guess costs time and never rows. Skipped entirely when the row
  -- function is in play, because then there is no translated chain to cost.
  v_capped_clause := v_match_clause;
  if v_complete is not null then
    v_probe := public.company_probe_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
    if v_probe is not null then
      -- Measure the match fraction on a small sample rather than ask the planner
      -- to estimate it. Two reasons, both learned the hard way here:
      --
      --   * EXPLAIN raises 0A000 "not allowed in a non-volatile function", and
      --     this function is STABLE. An earlier version called it inside an
      --     exception handler, so it failed silently on every request and the
      --     probe shape was never once chosen -- invisible except end to end.
      --
      --   * the estimate was not trustworthy anyway: it guessed 53,221 rows for
      --     a set that really matched 21,989, because it assumes independence
      --     across a hundred OR'd substring tests.
      --
      -- The sample answers the same question from data. 0.05% of the table is
      -- ~210 rows and measured 21-111ms, with selective sets landing at 5.8-9.5%
      -- and everything else at 58.2% and up. repeatable(1) fixes the seed so one
      -- filter always picks the same shape: predictable beats marginally better.
      select coalesce(max(cardinality(v)), 0) into v_value_count
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) f
      cross join lateral (select array(select jsonb_array_elements_text(f.value->'values'))) s(v);

      -- Per-row cost grows with the value list, so shrink the sample to keep the
      -- decision cheap: the product, not the row count, is what is bounded.
      v_sample_rows := greatest(120, least(400, 60000 / greatest(v_value_count, 1)));

      begin
        execute format(
          'select coalesce(avg(case when %s then 1.0 else 0.0 end), 1.0) from '
          || '(select * from public.companies tablesample system (0.05) repeatable (1) limit %s) c',
          v_match_clause, v_sample_rows) into v_fraction;
        if v_fraction < v_broad_fraction then
          v_capped_clause := v_probe;
        end if;
      exception when others then
        -- Choosing a shape is an optimisation, never a correctness input. If the
        -- sample cannot run, keep the shape that is in production today.
        v_capped_clause := v_match_clause;
      end;
    end if;
  end if;

  -- Per-client counts are an aggregate, not a match set: computing it once and
  -- joining it from both scans is exactly what a shared CTE is for.
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

  -- Everything after the match clause applies to both scans identically, so it
  -- is built once and appended to each.
  if p_client_id is not null then
    v_scope_suffix := v_scope_suffix || format($e$ and exists (
      select 1 from public.prospect_index scoped
      where scoped.company_id = c.id and scoped.client_ids @> array[%L]
    )$e$, p_client_id);
  end if;
  if p_people_scope is not null then
    -- Only the ids are materialised, so the scope function runs once for both
    -- scans without carrying any of the match set with it.
    v_ctes := array_append(v_ctes, format($s$scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(%L, %L::jsonb)
      )$s$, p_client_id, p_people_scope::text));
    v_scope_suffix := v_scope_suffix || ' and c.id in (select company_id from scope_ids)';
  end if;

  v_where := format('(%s)', v_match_clause) || v_scope_suffix;
  v_where_capped := format('(%s)', v_capped_clause) || v_scope_suffix;

  -- Cap only when something narrows the set. An unfiltered listing is the
  -- headline 'how many companies do I have' number, it has to stay exact, and it
  -- is cheap anyway because nothing has to be re-checked per row.
  v_count_cap := case when v_match_clause = 'true' and p_people_scope is null then 'all' else '50001' end;

  v_cte_sql := case when cardinality(v_ctes) > 0
    then array_to_string(v_ctes, ', ') || ', ' else '' end;

  -- page and capped each read public.companies directly and carry their own
  -- LIMIT, so neither is referenced twice and neither forces the other to build
  -- the whole match set first.
  v_sql := format($query$
    with %1$s page as (
      select c.id, c.name, c.domain, c.created_at,
        %2$s as prospect_count, %3$s as client_count
      from public.companies c%4$s
      where %5$s
      order by %2$s desc, lower(c.name), c.id
      offset %6$s limit %7$s
    ), capped as (
      select %2$s as prospect_count
      from public.companies c%4$s
      where %9$s
      limit %8$s
    ), counted as (
      select case when %8$L = 'all' then count(*) else least(count(*), 50000) end::integer as total_count,
        (count(*) > 50000 and %8$L <> 'all') as total_capped,
        count(*) filter (where prospect_count > 0)::integer as covered_count,
        coalesce(sum(prospect_count), 0)::integer as prospect_total
      from capped
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id)
        from page
      ), '[]'::jsonb),
      counted.total_count, counted.covered_count, counted.prospect_total, counted.total_capped
    from counted
  $query$, v_cte_sql, v_prospect_expr, v_client_expr, v_join, v_where,
       v_offset::text, v_limit::text, v_count_cap, v_where_capped);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;

revoke execute on function public.company_probe_columns_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_filter_is_probed_v1(text, jsonb, text, text[]) from public, anon, authenticated;
revoke execute on function public.company_substring_probe_sql_v1(text[], text[], text[]) from public, anon, authenticated;
revoke execute on function public.company_filter_sql_v3(text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.company_probe_filter_sql_v1(text, jsonb) from public, anon, authenticated;
grant execute on function public.company_probe_columns_v1(text, jsonb) to service_role;
grant execute on function public.company_filter_is_probed_v1(text, jsonb, text, text[]) to service_role;
grant execute on function public.company_substring_probe_sql_v1(text[], text[], text[]) to service_role;
grant execute on function public.company_filter_sql_v3(text, jsonb, boolean) to service_role;
grant execute on function public.company_probe_filter_sql_v1(text, jsonb) to service_role;

commit;
