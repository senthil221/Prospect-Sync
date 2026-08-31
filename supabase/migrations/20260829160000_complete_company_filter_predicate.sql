-- Exclude and Boolean searches stop calling the row function.
--
-- company_matches_filters_v1 exists for convenience, not necessity: every
-- operator it implements is ordinary SQL. What it costs is the call. It takes a
-- whole public.companies row and carries a SET clause, so the planner will not
-- inline it -- it also declines because p_row is referenced ~15 times, which
-- would rebuild the ROW() at each -- and it is invoked once per candidate row at
-- ~250us. Across 418,151 companies that is ~105s.
--
-- Include filters escaped this because company_prefilter_sql narrowed them to a
-- handful of rows first. Exclude and Boolean had nothing to narrow them -- a
-- negation matches nearly everything by definition -- so they paid the call on
-- every row and ran past the timeout every time:
--
--   keyword exclude ......... 104.5 s
--   Boolean search ..........  73.0 s
--
-- company_filter_sql_v2 emits the whole filter set as SQL, so there is no
-- per-row call left to pay and the planner can see the predicate. It returns
-- null for anything it cannot express, and both callers then fall back to the
-- old narrow-then-confirm shape: a wrong answer is far worse than a slow one.
--
-- Equivalence is not assumed. A differential test compared row counts against
-- prefilter + company_matches_filters_v1 across 33 filter shapes -- every
-- operator, every keyword scope, multi-value, multi-filter, and free-text search
-- -- over a fixed 20,000-company sample. 32 matched exactly.
--
-- The 33rd is a bug this fixes. For "__keywords equals", the old prefilter
-- emitted lower(array_to_string(c.keywords, ' | ')) = any (...), which is only
-- true when a company's ENTIRE keyword list equals the search value. It narrowed
-- to zero rows and the row function -- which does check array membership, and
-- returns 180 on that sample -- never got the chance. The Keywords filter set to
-- exact match has been silently returning nothing.

-- Both listing functions go from a 20s statement_timeout to 45s. Boolean search
-- is the one operator still without an index: to_tsvector over the scope
-- concatenation cannot be indexed because array_to_string is not IMMUTABLE, so a
-- maintained column would be needed and that is a 5-minute table rewrite. It now
-- runs in ~22s rather than ~73s, which a 20s cap would still fail every time. 45s
-- lets it complete while staying well inside the authenticator's 120s ceiling.
-- Every other operator finishes in under three seconds and never approaches it.

begin;

create or replace function public.company_filter_sql_v2(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $fn$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  selected_scopes jsonb;
  candidate_expr text;
  boolean_expr text;
  keyword_hit text;
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
    if cardinality(raw_values) = 0 and operator_key not in ('empty', 'not_empty') then
      continue;
    end if;

    keyword_hit := 'false';

    if field_key = '__company_keywords' then
      selected_scopes := case
        when jsonb_typeof(filter_item->'scopes') = 'array'
          then case when jsonb_array_length(filter_item->'scopes') > 0
            then filter_item->'scopes' else '["name","keywords"]'::jsonb end
        else '["name","keywords"]'::jsonb
      end;

      -- Substring scopes only; keywords are matched exactly, below.
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      candidate_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      -- Boolean search keeps spanning keywords as text.
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'keywords' then scope_parts := array_append(scope_parts, 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      boolean_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      if selected_scopes ? 'keywords' and cardinality(raw_values) > 0 then
        keyword_hit := format('c.keywords && %L::text[]', raw_values);
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
    end if;

    candidate_expr := 'coalesce(' || candidate_expr || ', ' || quote_literal('') || ')';
    boolean_expr := 'coalesce(' || boolean_expr || ', ' || quote_literal('') || ')';

    if operator_key = 'equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := array[format('lower(%s) = any (%L::text[])', candidate_expr, lowered)];
      if field_key = '__keywords' then
        value_parts := value_parts || format('c.keywords && %L::text[]', raw_values);
      elsif field_key = '__technologies' then
        value_parts := value_parts || format('c.technologies && %L::text[]', raw_values);
      end if;
      if keyword_hit <> 'false' then value_parts := value_parts || keyword_hit; end if;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'not_equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      conjuncts := conjuncts || format('(not (%s) and not (lower(%s) = any (%L::text[])))',
        keyword_hit, candidate_expr, lowered);

    elsif operator_key = 'not_contains' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', candidate_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));

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
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', candidate_expr, '%' || value_text || '%');
      end loop;
      if keyword_hit <> 'false' then value_parts := value_parts || keyword_hit; end if;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$fn$;

CREATE OR REPLACE FUNCTION public.filter_companies_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '45s'
AS $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_counts_cte text;
  v_agg_select text;
  v_complete text;
  v_sql text;
begin
  -- Prefer a complete SQL predicate: it lets the planner use indexes and, more
  -- importantly, removes the per-row company_matches_filters_v1 call entirely.
  -- v2 returns null only for a filter it cannot express, in which case fall back
  -- to the old narrow-then-confirm shape rather than risk a wrong answer.
  v_complete := public.company_filter_sql_v2(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  -- The counts used to come from a lateral evaluated once per company. On the
  -- master listing that is 418,151 index lookups to recompute numbers a trigger
  -- already maintains on companies.prospect_count / companies.client_count;
  -- measured over a 3,000-company sample the stored values matched the
  -- recomputed ones exactly, and reading them is ~276ms against ~4.7s.
  --
  -- A client-scoped listing genuinely needs a different number -- prospects of
  -- THIS client -- which the global columns cannot answer. There the lateral
  -- becomes one hash aggregate over the same index instead of one lookup per row.
  if p_client_id is null then
    v_counts_cte := '';
    v_agg_select := 'select b.id, b.name, b.domain, b.created_at, b.prospect_count, b.client_count from base b';
  else
    v_counts_cte := format($c$client_counts as (
        select pi.company_id,
          count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) cid on true
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), $c$, p_client_id);
    v_agg_select := 'select b.id, b.name, b.domain, b.created_at,'
      || ' coalesce(k.prospect_count, 0) as prospect_count,'
      || ' coalesce(k.client_count, 0) as client_count'
      || ' from base b left join client_counts k on k.company_id = b.id';
  end if;

  v_sql := format($q$
    with base as (
      select c.id, c.name, c.domain, c.created_at, c.prospect_count, c.client_count
      from public.companies c
      where (%1$s)
        and (%2$L is null or exists (select 1 from public.prospect_index scoped where scoped.company_id = c.id and scoped.client_ids @> array[%2$L]))
        and (%3$L::jsonb is null or c.id in (select company_id from public.people_scope_company_ids_v1(%2$L, %3$L::jsonb)))
    ), %6$s agg as (
      %7$s
    ), counted as (
      select count(*)::integer as total_count,
        count(*) filter (where prospect_count > 0)::integer as covered_count,
        coalesce(sum(prospect_count), 0)::integer as prospect_total
      from agg
    ), page as (
      select id, name, domain, created_at, prospect_count, client_count
      from agg order by prospect_count desc, lower(name), id
      offset %4$s limit %5$s
    )
    select coalesce((select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id) from page), '[]'::jsonb),
      counted.total_count, counted.covered_count, counted.prospect_total
    from counted
  $q$, v_match_clause, p_client_id,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_agg_select);

  return query execute v_sql;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '45s'
AS $function$
declare
  -- Two shapes, because the fast plan is the opposite one in each case.
  --
  -- Unfiltered, the whole client is in scope (150,352 companies here), and a
  -- lateral per row plans as one index lookup per company -- 0.016ms each but
  -- 2.4s in total. One hash aggregate over the same index does it in a pass.
  --
  -- Filtered, the page is small, so the aggregate would compute counts for the
  -- entire client to then throw nearly all of them away. There the lateral wins,
  -- provided the filter narrows the set first -- which is what the prefilter is
  -- for. Without it this function called company_matches_filters_v1 once per
  -- company, which is why a filtered client listing used to run past 90s.
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counts_cte text;
  v_counts_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_complete text;
  v_sql text;
begin
  -- Prefer a complete SQL predicate: it lets the planner use indexes and removes
  -- the per-row company_matches_filters_v1 call entirely. v2 returns null only for
  -- a filter it cannot express, where the old narrow-then-confirm shape is kept.
  -- The counts strategy below still keys off v_unfiltered, which is a separate
  -- question from how the rows are matched.
  v_complete := public.company_filter_sql_v2(p_search, coalesce(p_filters, '[]'::jsonb));

  if v_unfiltered then
    v_match_clause := coalesce(v_complete, 'true');
    v_counts_cte := format($c$client_counts as (
        select pi.company_id, count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), coverage_counts as (
        select cc.company_id, count(*)::integer as client_count
        from public.client_companies cc
        group by cc.company_id
      ), $c$, p_client_id);
    v_counts_join := 'left join client_counts counts on counts.company_id = c.id'
      || ' left join coverage_counts coverage on coverage.company_id = c.id';
  else
    v_match_clause := coalesce(v_complete,
      case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
        || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text));
    v_counts_cte := '';
    v_counts_join := format($j$left join lateral (
        select count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id = c.id and pi.client_ids @> array[%L]
      ) counts on true
      left join lateral (
        select count(*)::integer as client_count
        from public.client_companies all_memberships
        where all_memberships.company_id = c.id
      ) coverage on true$j$, p_client_id);
  end if;

  -- count(*) rather than count(distinct pi.id): prospect_index.id is unique, so
  -- the two are identical and the sort behind distinct is pure cost.
  v_sql := format($q$
    with %6$s matched as materialized (
      select c.id, c.name, c.domain, c.created_at,
        coalesce(counts.prospect_count, 0)::integer as prospect_count,
        coalesce(coverage.client_count, 0)::integer as client_count
      from public.client_companies membership
      join public.companies c on c.id = membership.company_id
      %7$s
      where membership.client_id = %1$L
        and (%2$s)
        and (%3$L::jsonb is null or c.id in (
          select company_id from public.people_scope_company_ids_v1(%1$L, %3$L::jsonb)
        ))
    ), page_rows as (
      select * from matched
      order by prospect_count desc, lower(name), id
      limit %5$s offset %4$s
    )
    select coalesce((select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id) from page_rows), '[]'::jsonb),
      (select count(*) from matched),
      (select count(*) from matched where matched.prospect_count > 0),
      (select coalesce(sum(matched.prospect_count), 0) from matched)
  $q$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join);

  return query execute v_sql;
end;
$function$
;

revoke execute on function public.company_filter_sql_v2(text, jsonb) from public, anon, authenticated;
revoke execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;

grant execute on function public.company_filter_sql_v2(text, jsonb) to service_role;
grant execute on function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer) to service_role;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;

commit;
