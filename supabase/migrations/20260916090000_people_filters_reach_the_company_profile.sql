-- The People database can now filter on the company profile: industry,
-- keywords, description, technologies, founded year and total funding.
--
-- WHY THIS DOES NOT WIDEN prospect_index, WHICH IS WHAT WAS FIRST PROPOSED.
-- The obvious move is seven more columns on prospect_index, populated by
-- reindex_prospects. 20260910090000 already argued against that for the export
-- path, and measuring it settles the question rather than leaving it to taste.
-- Projected across the 683,784 prospects, on production:
--
--   short_description   525 MB      technologies   370 MB
--   keywords            814 MB      industry        11 MB
--   total_funding      1545 kB      ------------------------
--                                   total       1,722 MB
--
-- prospect_index's heap is 1,332 MB today, so that is more than double, before
-- the GIN indexes those columns would need and before the bloat left by an
-- UPDATE of every row. It would also need a backfill too long for one
-- migration, and it would slow every read in the product - every search, every
-- listing, every count - to serve filters most queries never use.
--
-- WHAT IT DOES INSTEAD. The predicate is an EXISTS against public.companies,
-- correlated on pi.company_id, which every call site already has:
--
--   exists (select 1 from public.companies co
--            where co.id = pi.company_id and co.industry ilike '%fintech%')
--
-- Nothing is copied, nothing is backfilled, no index is created, and not one
-- call site changes - search_prospect_workspace_v12, both export functions,
-- both prospect_ids_matching_v1 overloads, delete_prospects_matching_v1 and
-- people_scope_company_ids_v1 all alias the index as pi and all keep working
-- untouched. The filters are served by the indexes companies already carries.
--
-- MEASURED ON PRODUCTION, 683,784 prospects against 418,151 companies:
--
--   company keywords && 'fintech'            Bitmap on idx_companies_keywords_gin
--                                            -> nested loop to pi          ~150 ms
--   description ilike '%supply chain%'       idx_companies_short_description_trgm
--                                                                           384 ms
--   funding 100M-500M, sorted page of 50     idx_companies_total_funding_amount
--                                                                         2,076 ms
--   industry ilike '%information technology%'  memoised pkey lookup per row
--                                                                           938 ms
--
-- The industry case is the slowest because the planner declines the semi-join
-- and walks prospect_index instead; 938 ms against the workspace's 10 s ceiling
-- is not worth an index for. The other three get exactly the plan the shape was
-- chosen for: find the companies by index, then follow company_id into the
-- people.
--
-- THE FIELD KEYS ARE NOT NEW. __company_industry, __company_keywords,
-- __company_description, __company_founded_year, __company_technologies and
-- __company_total_funding are the six the People EXPORT has offered since
-- 20260910090000 (lib/prospect-export.ts). Filtering and exporting now name the
-- same field the same way, which is already true of __title and __company.
--
-- __company_keywords is deliberately the plain keyword array here, not the
-- Companies panel's scoped name+keywords+description bundle that shares its
-- name. The People export has always meant the plain array by it, and a
-- Data Quality check for "no company keywords" needs a field that is empty when
-- the keywords are empty - which the bundle never is once a company has a name.
-- A People filter carrying scopes has them ignored.
--
-- AND A BUG FOUND WHILE READING THE COMPILER, WHICH IS FIXED HERE. Its Boolean
-- branch appends to value_parts without clearing it first, so a Boolean filter
-- inherits the value parts of whatever filter preceded it. Live on production
-- before this migration:
--
--   prospect_filter_sql_v1('', '[{"field":"__title","operator":"contains","values":["manager"]},
--                                {"field":"__company","operator":"boolean","values":["acme"]}]')
--   -> (pi.title ilike '%manager%')
--      and (pi.title ilike '%manager%' or to_tsvector(...) @@ to_tsquery('simple','acme'))
--
-- (A) and (A or B) is A, so the Boolean filter did nothing at all whenever any
-- contains filter came before it. prospect_index_matches_v1 has no such bug, so
-- the grid and a bulk action on the same filter set answered differently. One
-- added line clears the accumulator; the assertion battery at the foot of this
-- file includes that exact pair.
-- ---------------------------------------------------------------------------

-- Premises.
do $$
begin
  if to_regprocedure('public.prospect_filter_sql_v1(text,jsonb)') is null then
    raise exception 'prospect_filter_sql_v1 is missing; apply the filter compiler migrations first';
  end if;
  if to_regprocedure('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)') is null then
    raise exception 'prospect_index_matches_v1 is missing; apply the filter compiler migrations first';
  end if;
  if to_regprocedure('public.keyword_tag_variants_v1(text[])') is null then
    raise exception 'keyword_tag_variants_v1 is missing; apply 20260901000080 first';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'companies'
                    and column_name = 'total_funding_amount') then
    raise exception 'companies.total_funding_amount is missing; apply 20260915090000 first';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The SQL compiler.
--
-- Spliced rather than restated: this function has been redefined by later
-- migrations than the one that introduced it, and restating a body from any one
-- of them would silently undo the others. Each marker is asserted present, so a
-- miss raises here instead of shipping a filter nobody can use.

do $patch$
declare
  v_def text;
  v_out text;
  v_marker text;
  v_replacement text;
begin
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_def;
  v_out := v_def;

  -- 1a. The locals the company block needs.
  v_marker := '  bulk_or_threshold constant integer := 40;';
  v_replacement := $r$  company_expr text;
  company_inner text;
  company_negate boolean;
  company_unknown boolean;
  range_min text;
  range_max text;
  bulk_or_threshold constant integer := 40;$r$;
  if position(v_marker in v_out) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer declares bulk_or_threshold where expected; refusing to patch blindly';
  end if;
  v_out := replace(v_out, v_marker, v_replacement);

  -- 1b. The Boolean accumulator leak. One line, and the reason it matters is in
  -- the header.
  v_marker := $m$      foreach value_text in array raw_values loop
        value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)',
          'simple', candidate_expr, 'simple', value_text);
      end loop;$m$;
  v_replacement := $r$      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)',
          'simple', candidate_expr, 'simple', value_text);
      end loop;$r$;
  if position(v_marker in v_out) = 0 then
    raise exception 'prospect_filter_sql_v1 Boolean branch is not in the expected shape; refusing to patch blindly';
  end if;
  v_out := replace(v_out, v_marker, v_replacement);

  -- 1c. The company block, ahead of the column CASE. Same position and shape as
  -- the __client_tags / __client_ids / __lead blocks above it: resolve the field,
  -- emit a conjunct, continue.
  v_marker := '    candidate_expr := case field_key';
  v_replacement := $r$    -- The company profile. Not carried on prospect_index - read from
    -- public.companies through pi.company_id, which every caller has. See the
    -- header of 20260916090000 for why, and for the measured plans.
    --
    -- Every operator resolves to ONE predicate evaluated against a single
    -- company row, wrapped in exists or not exists. That wrapping is what makes
    -- a prospect with NO company behave exactly as a prospect whose company has
    -- a blank field, which is what prospect_index_matches_v1 does with
    -- coalesce(..., '') and what the two have to agree about.
    if field_key in ('__company_industry', '__company_keywords', '__company_description',
                     '__company_technologies', '__company_founded_year', '__company_total_funding') then
      company_expr := case field_key
        when '__company_industry' then 'co.industry'
        when '__company_keywords' then 'array_to_string(co.keywords, '' | '')'
        when '__company_description' then 'co.short_description'
        when '__company_technologies' then 'array_to_string(co.technologies, '' | '')'
        when '__company_founded_year' then 'co.founded_year::text'
        else 'co.total_funding'
      end;
      company_expr := format('coalesce(%s, %L)', company_expr, '');
      company_inner := null;
      company_negate := false;

      if operator_key = 'number_ranges' then
        -- Ranges read the typed column, not the text one. Funding parses bigint
        -- bounds: production's maximum is 178 billion, which overflows the
        -- ::integer casts the employee ranges share (20260915090000).
        value_parts := array[]::text[];
        company_unknown := false;
        foreach value_text in array raw_values loop
          if value_text = 'unknown' then company_unknown := true; continue; end if;
          if value_text !~ '^[0-9]+:[0-9]*$' then continue; end if;
          range_min := split_part(value_text, ':', 1);
          range_max := case when value_text ~ '^[0-9]+:[0-9]+$' then split_part(value_text, ':', 2) else null end;
          if field_key = '__company_founded_year' then
            value_parts := value_parts || format('(co.founded_year is not null and co.founded_year >= %s and (%s))',
              range_min, case when range_max is null then 'true' else format('co.founded_year <= %s', range_max) end);
          else
            value_parts := value_parts || format('(co.total_funding_amount is not null and co.total_funding_amount >= %s::bigint and (%s))',
              range_min, case when range_max is null then 'true' else format('co.total_funding_amount <= %s::bigint', range_max) end);
          end if;
        end loop;

        -- "Not known" has to hold for a prospect with no company at all, not
        -- only for a company with a null value - so it is a NOT EXISTS, and the
        -- two halves are OR-ed rather than folded into one subquery.
        company_inner := null;
        if cardinality(value_parts) > 0 then
          company_inner := format('exists (select 1 from public.companies co where co.id = pi.company_id and (%s))',
            array_to_string(value_parts, ' or '));
        end if;
        if company_unknown then
          company_expr := format('not exists (select 1 from public.companies co where co.id = pi.company_id and co.%s is not null)',
            case when field_key = '__company_founded_year' then 'founded_year' else 'total_funding_amount' end);
          company_inner := case when company_inner is null then company_expr
            else '(' || company_inner || ' or ' || company_expr || ')' end;
        end if;
        conjuncts := array_append(conjuncts, coalesce(company_inner, 'false'));
        continue;
      end if;

      if coalesce(filter_item->>'setId', '') <> '' then
        if operator_key <> 'equals' then
          raise exception 'A filter set supports the equals operator only, got %', operator_key
            using errcode = '22023';
        end if;
        company_inner := format(
          'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))',
          (filter_item->>'setId')::uuid, company_expr);
      elsif operator_key = 'empty' then
        company_inner := format('btrim(%s) <> %L', company_expr, '');
        company_negate := true;
      elsif operator_key = 'not_empty' then
        company_inner := format('btrim(%s) <> %L', company_expr, '');
      elsif cardinality(raw_values) = 0 then
        -- Same answer the generic path gives a value operator with no values.
        conjuncts := array_append(conjuncts, 'false');
        continue;
      elsif operator_key = 'boolean' then
        value_parts := array[]::text[];
        foreach value_text in array raw_values loop
          value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)',
            'simple', company_expr, 'simple', value_text);
        end loop;
        company_inner := '(' || array_to_string(value_parts, ' or ') || ')';
      elsif operator_key in ('equals', 'not_equals') then
        value_parts := array[format('lower(%s) = any (%L::text[])', company_expr, lowered)];
        -- A tag array is matched by membership, not by equalling the joined
        -- string, and && is what the GIN index serves. keyword_tag_variants_v1
        -- adds the lowercase spelling because the tag store is lowercase.
        if field_key = '__company_keywords' then
          value_parts := value_parts || format('co.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
        elsif field_key = '__company_technologies' then
          value_parts := value_parts || format('co.technologies && %L::text[]', public.keyword_tag_variants_v1(raw_values));
        end if;
        company_inner := '(' || array_to_string(value_parts, ' or ') || ')';
        company_negate := (operator_key = 'not_equals');
      else
        if cardinality(raw_values) > bulk_or_threshold then
          company_inner := format('exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')',
            raw_values, company_expr);
        else
          value_parts := array[]::text[];
          foreach value_text in array raw_values loop
            value_parts := value_parts || format('%s ilike %L', company_expr, '%' || value_text || '%');
          end loop;
          company_inner := '(' || array_to_string(value_parts, ' or ') || ')';
        end if;
        company_negate := (operator_key = 'not_contains');
      end if;

      conjuncts := conjuncts || format('%sexists (select 1 from public.companies co where co.id = pi.company_id and (%s))',
        case when company_negate then 'not ' else '' end, company_inner);
      continue;
    end if;

    candidate_expr := case field_key$r$;
  if position(v_marker in v_out) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer opens its column CASE where expected; refusing to patch blindly';
  end if;
  v_out := replace(v_out, v_marker, v_replacement);

  execute v_out;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 2. The row matcher, which must answer identically or the grid and a bulk
--    action on the same filter set act on different rows.
--
-- Four of the six fields need nothing but a candidate value: the generic
-- operator machinery below them already implements contains, not_contains,
-- empty, not_empty and boolean against coalesce(candidate, ''), which is
-- exactly what the exists/not exists wrapping above reproduces.

do $patch$
declare
  v_def text;
  v_out text;
  v_marker text;
  v_replacement text;
begin
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_def;
  v_out := v_def;

  -- 2a. The candidate value: a primary-key lookup per row, which is all this
  -- function ever does anyway - it exists to judge one row at a time.
  v_marker := '        when ''__company_country'' then (p_row).company_country';
  v_replacement := $r$        when '__company_country' then (p_row).company_country
        when '__company_industry' then (select co.industry from public.companies co where co.id = (p_row).company_id)
        when '__company_keywords' then (select array_to_string(co.keywords, ' | ') from public.companies co where co.id = (p_row).company_id)
        when '__company_description' then (select co.short_description from public.companies co where co.id = (p_row).company_id)
        when '__company_technologies' then (select array_to_string(co.technologies, ' | ') from public.companies co where co.id = (p_row).company_id)
        when '__company_founded_year' then (select co.founded_year::text from public.companies co where co.id = (p_row).company_id)
        when '__company_total_funding' then (select co.total_funding from public.companies co where co.id = (p_row).company_id)$r$;
  if position(v_marker in v_out) = 0 then
    raise exception 'prospect_index_matches_v1 no longer resolves __company_country where expected; refusing to patch blindly';
  end if;
  v_out := replace(v_out, v_marker, v_replacement);

  -- 2b. Equality on the two tag arrays. The compiler answers it with && over the
  -- GIN index and keyword_tag_variants_v1; lower(part) = lower(value) is NOT the
  -- same test - it also matches 'Fintech' against 'fintech', which && does not -
  -- so this mirrors the compiled form exactly rather than approximating it.
  v_marker := '      else case coalesce(filter_item->>''operator'', ''contains'')';
  v_replacement := $r$      when filter_item->>'field' in ('__company_keywords', '__company_technologies')
        and coalesce(filter_item->>'operator', 'contains') in ('equals', 'not_equals') then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) > 0
        and ((coalesce(filter_item->>'operator', 'contains') = 'not_equals')
          <> (exists (select 1 from public.companies co
                where co.id = (p_row).company_id
                  and (lower(coalesce(array_to_string(
                         case when filter_item->>'field' = '__company_keywords' then co.keywords else co.technologies end, ' | '), ''))
                       = any (array(select lower(value) from jsonb_array_elements_text(filter_item->'values') as picked(value)))
                    or (case when filter_item->>'field' = '__company_keywords' then co.keywords else co.technologies end)
                       && public.keyword_tag_variants_v1(
                            array(select value from jsonb_array_elements_text(filter_item->'values') as picked(value)))))))
      )
      else case coalesce(filter_item->>'operator', 'contains')$r$;
  if position(v_marker in v_out) = 0 then
    raise exception 'prospect_index_matches_v1 no longer opens its operator CASE where expected; refusing to patch blindly';
  end if;
  v_out := replace(v_out, v_marker, v_replacement);

  -- 2c. Ranges over founded year and funding, beside the employee ranges.
  --
  -- The bounds widen from integer to bigint in the same edit. Employee counts
  -- never reach 2,147,483,647 so nothing changes for them, but funding does -
  -- production's maximum is 178 billion - and the shared lateral would have
  -- raised 22003 for every row on a bound that large.
  v_marker := $m$          select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
        ) selected_range
        where filter_item->>'field' = '__employee_count'
          and ((selected.value = 'unknown' and (p_row).employee_count_min is null and (p_row).employee_count_max is null)
            or (selected.value <> 'unknown' and (p_row).employee_count_min is not null
              and (selected_range.maximum is null or (p_row).employee_count_min <= selected_range.maximum)
              and ((p_row).employee_count_max is null or (p_row).employee_count_max >= selected_range.minimum)))$m$;
  v_replacement := $r$          select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::bigint end as minimum,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::bigint end as maximum
        ) selected_range
        where (filter_item->>'field' = '__employee_count'
          and ((selected.value = 'unknown' and (p_row).employee_count_min is null and (p_row).employee_count_max is null)
            or (selected.value <> 'unknown' and (p_row).employee_count_min is not null
              and (selected_range.maximum is null or (p_row).employee_count_min <= selected_range.maximum)
              and ((p_row).employee_count_max is null or (p_row).employee_count_max >= selected_range.minimum))))
        or (filter_item->>'field' = '__company_founded_year'
          and ((selected.value = 'unknown' and not exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.founded_year is not null))
            or (selected.value <> 'unknown' and exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.founded_year is not null
                   and co.founded_year >= selected_range.minimum
                   and (selected_range.maximum is null or co.founded_year <= selected_range.maximum)))))
        or (filter_item->>'field' = '__company_total_funding'
          and ((selected.value = 'unknown' and not exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.total_funding_amount is not null))
            or (selected.value <> 'unknown' and exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.total_funding_amount is not null
                   and co.total_funding_amount >= selected_range.minimum
                   and (selected_range.maximum is null or co.total_funding_amount <= selected_range.maximum)))))$r$;
  if position(v_marker in v_out) = 0 then
    raise exception 'prospect_index_matches_v1 number_ranges branch is not in the expected shape; refusing to patch blindly';
  end if;
  v_out := replace(v_out, v_marker, v_replacement);

  execute v_out;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 3. Autocomplete. The People panel asks the COMPANY value endpoint for these
--    fields - prospect_filter_values_v3 has no case for them and would scan
--    prospect_index to return nothing, which is the exact mistake the Companies
--    panel already made once. Teaching company_filter_values_v1 the People
--    spelling of three fields it already answers is the whole change.

do $patch$
declare
  v_def text;
  v_out text;
begin
  select pg_get_functiondef('public.company_filter_values_v1(text,text,integer)'::regprocedure) into v_def;
  v_out := v_def;

  if position($m$    when p_field = '__technologies' then 'technologies'$m$ in v_out) = 0 then
    raise exception 'company_filter_values_v1 no longer classifies __technologies where expected; refusing to patch blindly';
  end if;
  v_out := replace(v_out,
    $m$    when p_field = '__technologies' then 'technologies'$m$,
    $r$    when p_field in ('__technologies', '__company_technologies') then 'technologies'$r$);

  if position($m$        when '__industry' then c.industry$m$ in v_out) = 0 then
    raise exception 'company_filter_values_v1 no longer projects __industry where expected; refusing to patch blindly';
  end if;
  v_out := replace(v_out,
    $m$        when '__industry' then c.industry$m$,
    $r$        when '__industry' then c.industry
        when '__company_industry' then c.industry$r$);

  if position($m$        when '__total_funding' then c.total_funding$m$ in v_out) = 0 then
    raise exception 'company_filter_values_v1 no longer projects __total_funding where expected; refusing to patch blindly';
  end if;
  v_out := replace(v_out,
    $m$        when '__total_funding' then c.total_funding$m$,
    $r$        when '__total_funding' then c.total_funding
        when '__company_total_funding' then c.total_funding$r$);

  -- A field with no case fell through to `else ''`, which GROUPED 418,151
  -- companies to return nothing - 15 s of scan per keystroke on a box that can
  -- never suggest anything. prospect_filter_values_v3 already returns early for
  -- an unmapped field (its own comment says so); this makes the company side
  -- behave the same, which is what lets the People panel point every company
  -- field here, description included.
  if position($m$  return query
    select picked.val, count(*)::bigint$m$ in v_out) = 0 then
    raise exception 'company_filter_values_v1 no longer ends with the projected-value query; refusing to patch blindly';
  end if;
  v_out := replace(v_out,
    $m$  return query
    select picked.val, count(*)::bigint$m$,
    $r$  if p_field not in ('__industry', '__company_industry', '__company_city', '__company_state',
                     '__company_country', '__company_location', '__total_funding',
                     '__company_total_funding', '__company', '__website') then
    return;
  end if;

  return query
    select picked.val, count(*)::bigint$r$);

  execute v_out;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 4. The two functions answer the same question. Asserted, not assumed.
--
-- WHY A SAMPLE AND NOT THE WHOLE TABLE. prospect_index_matches_v1 is a per-row
-- function call with a correlated lookup inside it; over all 683,784 rows one
-- count runs past two minutes, and there are twenty-two cases here. The sample
-- is built to CONTAIN the shapes that could disagree rather than to be large -
-- prospects with no company at all, companies with the field null, blank and
-- populated, and both ends of every range - because a random 10,000 rows would
-- mostly be prospects whose company has an industry, and would prove little.
do $$
declare
  v_ids text[];
  v_case jsonb;
  v_sql text;
  v_compiled bigint;
  v_matched bigint;
  v_cases jsonb := $c$[
    [{"field":"__company_industry","operator":"contains","values":["information technology"]}],
    [{"field":"__company_industry","operator":"not_contains","values":["information technology"]}],
    [{"field":"__company_industry","operator":"equals","values":["Information Technology & Services"]}],
    [{"field":"__company_industry","operator":"not_equals","values":["Information Technology & Services"]}],
    [{"field":"__company_industry","operator":"empty","values":[]}],
    [{"field":"__company_industry","operator":"not_empty","values":[]}],
    [{"field":"__company_keywords","operator":"contains","values":["saas"]}],
    [{"field":"__company_keywords","operator":"equals","values":["fintech","saas"]}],
    [{"field":"__company_keywords","operator":"not_equals","values":["fintech"]}],
    [{"field":"__company_keywords","operator":"empty","values":[]}],
    [{"field":"__company_description","operator":"contains","values":["supply chain"]}],
    [{"field":"__company_description","operator":"not_contains","values":["supply chain"]}],
    [{"field":"__company_description","operator":"boolean","values":["software"]}],
    [{"field":"__company_description","operator":"empty","values":[]}],
    [{"field":"__company_technologies","operator":"contains","values":["wordpress"]}],
    [{"field":"__company_technologies","operator":"equals","values":["WordPress","Google Analytics"]}],
    [{"field":"__company_founded_year","operator":"number_ranges","values":["2010:2019"]}],
    [{"field":"__company_founded_year","operator":"number_ranges","values":["unknown"]}],
    [{"field":"__company_founded_year","operator":"number_ranges","values":["unknown","2020:"]}],
    [{"field":"__company_total_funding","operator":"number_ranges","values":["100000001:500000000"]}],
    [{"field":"__company_total_funding","operator":"number_ranges","values":["unknown","500000001:"]}],
    [{"field":"__employee_count","operator":"number_ranges","values":["unknown","51:100"]}]
  ]$c$::jsonb;
begin
  select array_agg(distinct picked.id) into v_ids from (
    (select pi.id from public.prospect_index pi where pi.company_id is null limit 1200)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where btrim(coalesce(c.industry, '')) = '' limit 1200)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where btrim(coalesce(c.industry, '')) <> '' limit 1200)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where coalesce(array_length(c.keywords, 1), 0) > 0 limit 1000)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where coalesce(array_length(c.keywords, 1), 0) = 0 limit 1000)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where btrim(coalesce(c.short_description, '')) <> '' limit 1000)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where coalesce(array_length(c.technologies, 1), 0) > 0 limit 1000)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where c.founded_year is not null limit 800)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where c.founded_year is null limit 800)
    union all
    (select pi.id from public.prospect_index pi join public.companies c on c.id = pi.company_id
      where c.total_funding_amount is not null limit 800)
  ) picked;

  if coalesce(cardinality(v_ids), 0) < 5000 then
    raise exception 'the equivalence sample is only % rows; it would prove too little', coalesce(cardinality(v_ids), 0);
  end if;

  for v_case in select value from jsonb_array_elements(v_cases) loop
    v_sql := public.prospect_filter_sql_v1('', v_case);
    if v_sql is null then
      raise exception 'the compiler refused to express %', v_case::text;
    end if;
    execute format('select count(*) from public.prospect_index pi where pi.id = any(%L::text[]) and (%s)', v_ids, v_sql)
      into v_compiled;
    execute format('select count(*) from public.prospect_index pi where pi.id = any(%L::text[]) and public.prospect_index_matches_v1(pi, %L, %L::jsonb)',
      v_ids, '', v_case::text) into v_matched;
    if v_compiled <> v_matched then
      raise exception 'compiled SQL and the row matcher disagree on %: % vs %', v_case::text, v_compiled, v_matched;
    end if;
    -- A predicate that matches everything or nothing proves nothing about
    -- agreement, so a case that degenerates on this sample is a broken case.
    if v_compiled = 0 or v_compiled = cardinality(v_ids) then
      raise exception 'case % selected % of % sampled rows and so tests nothing',
        v_case::text, v_compiled, cardinality(v_ids);
    end if;
  end loop;

  raise notice 'company profile filters: % cases agree across % sampled prospects',
    jsonb_array_length(v_cases), cardinality(v_ids);
end $$;

-- The Boolean leak, checked on its own so a future edit that reintroduces it
-- fails here with the reason rather than inside a count.
do $$
declare
  v_sql text;
begin
  v_sql := public.prospect_filter_sql_v1('', $f$[
    {"field":"__title","operator":"contains","values":["manager"]},
    {"field":"__company","operator":"boolean","values":["acme"]}
  ]$f$::jsonb);
  if v_sql like '%manager%or to_tsvector%' then
    raise exception 'the Boolean branch is still inheriting the previous filter''s value parts: %', v_sql;
  end if;
end $$;

-- Autocomplete answers the People spelling, and answers nothing - fast - for a
-- field it cannot suggest for.
do $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.company_filter_values_v1('__company_industry', '', 5);
  if v_count = 0 then
    raise exception 'company_filter_values_v1 suggests nothing for __company_industry';
  end if;
  select count(*) into v_count from public.company_filter_values_v1('__company_technologies', '', 5);
  if v_count = 0 then
    raise exception 'company_filter_values_v1 suggests nothing for __company_technologies';
  end if;
  select count(*) into v_count from public.company_filter_values_v1('__company_description', '', 5);
  if v_count <> 0 then
    raise exception 'company_filter_values_v1 returned % suggestions for a description field', v_count;
  end if;
end $$;

-- Both functions keep their pinned settings. CREATE OR REPLACE rewrites
-- proconfig wholesale, and a splice that dropped a search_path would be a
-- silent security change.
do $$
declare
  v_cfg text[];
  v_name text;
begin
  foreach v_name in array array['prospect_filter_sql_v1', 'prospect_index_matches_v1', 'company_filter_values_v1'] loop
    select p.proconfig into v_cfg from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;
    if not (array_to_string(v_cfg, ',') like '%search_path=%') then
      raise exception '% lost its pinned search_path: %', v_name, v_cfg;
    end if;
  end loop;
end $$;
