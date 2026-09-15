-- __company_ids: narrow the Company database to an exact, named set of rows.
--
-- WHAT NEEDS IT. The coverage checker takes a company list, matches it against
-- the database and reports how many are known and how many of those already
-- carry prospects. Those are three numbers with nothing behind them - there was
-- no way to go and look at the companies they describe. This is the filter the
-- "See the N companies" buttons apply.
--
-- WHY NOT FILTER BY NAME, WHICH NEEDS NO MIGRATION. Because it is not exact,
-- and measured on production it is not close. 19,823 of 419,448 companies share
-- a normalized_name with at least one other company - 4.7% - so "open the 431
-- known companies" by name would open something else, silently, and usually a
-- bigger something. lib/quality-issues.ts states the rule this obeys: a button
-- that opens onto more rows than the number beside it is worse than no button,
-- because it teaches you not to trust the number.
--
-- WHY NOT FILTER BY DOMAIN, WHICH IS UNIQUE. Because coverage matches on domain
-- OR name - a row whose file gave only a company name still matches a real
-- company - and filters are ANDed, so "domain in (...) or name in (...)" is not
-- expressible as two filters. The id is the one key every matched row has.
--
-- THE SHAPE IS THE PRIMARY KEY. c.id = any(array[...]) against companies_pkey,
-- for up to the 5,000 rows one coverage check can carry (lib/coverage-file.ts).
-- No new index, and nothing cheaper exists.
--
-- Modelled line for line on 20260915140000, which added __company_client_ids:
-- builder, row matcher and pre-filter, each spliced with a raise if its anchor
-- moved. The exclude arm stays out of the pre-filter for the reason recorded
-- there - a pre-filter must be a NECESSARY condition, and "not in this set" is
-- not implied by any positive index probe.
-- ---------------------------------------------------------------------------

do $patch_company_ids$
declare
  v_definition text;
  v_rewritten text;
begin
  -- 1. The SQL builder. company_filter_sql_v2 is a one-line delegate to v3, so
  --    patching v3 reaches every caller.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$      candidate_expr := case field_key$old$,
    $new$      if field_key = '__company_ids' then
        if cardinality(raw_values) = 0 then continue; end if;
        if operator_key in ('not_contains', 'not_equals') then
          conjuncts := conjuncts || format('(not (c.id = any (%L::text[])))', raw_values);
        else
          conjuncts := conjuncts || format('(c.id = any (%L::text[]))', raw_values);
        end if;
        continue;
      end if;
      candidate_expr := case field_key$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_filter_sql_v3 for __company_ids'; end if;
  execute v_rewritten;

  -- 2. The row matcher. Its operator CASE was already wrapped in a field CASE by
  --    20260915140000, so this adds an arm and closes nothing.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$      else case coalesce(filter_item->>'operator', 'contains')$old$,
    $new$      when filter_item->>'field' = '__company_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> ((p_row).id = any (select value from jsonb_array_elements_text(filter_item->'values'))))
      )
      else case coalesce(filter_item->>'operator', 'contains')$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_matches_filters_v1 for __company_ids'; end if;
  execute v_rewritten;

  -- 3. The pre-filter gets the INCLUDE half. This is the most selective
  --    predicate the Company DB can be given, and without it the set test would
  --    be evaluated after whatever else the filter says.
  select pg_get_functiondef('public.company_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    field_key := filter_item->>'field';$old$,
    $new$    field_key := filter_item->>'field';
    -- companies_pkey. Only reached for contains/equals; the loop skipped every
    -- other operator above.
    if field_key = '__company_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format('(c.id = any (%L::text[]))', raw_values);
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_prefilter_sql for __company_ids'; end if;
  execute v_rewritten;
end $patch_company_ids$;

-- ---------------------------------------------------------------------------
-- Exact means exact: the filter returns the set it was given and nothing else.
do $$
declare
  v_ids text[];
  v_candidates text[];
  v_include_sampled bigint;
  v_include bigint;
  v_exclude bigint;
  v_matcher bigint;
  v_prefilter bigint;
  v_outside bigint;
  v_total bigint;
  v_filters jsonb;
begin
  select coalesce(array_agg(picked.id), array[]::text[]) into v_ids
    from (select id from public.companies order by id limit 500) picked;
  if cardinality(v_ids) < 500 then
    raise notice 'only % companies exist; skipping the behavioural checks', cardinality(v_ids);
    return;
  end if;
  select count(*) into v_total from public.companies;

  v_filters := jsonb_build_array(jsonb_build_object('field', '__company_ids',
    'operator', 'equals', 'values', to_jsonb(v_ids)));

  execute format('select count(*) from public.companies c where %s',
    public.company_filter_sql_v3('', v_filters)) into v_include;
  -- The number beside the button and the rows it opens onto are the same
  -- number. This is the whole reason the filter is by id.
  if v_include <> 500 then
    raise exception 'a 500-id filter opened onto % companies', v_include;
  end if;

  execute format('select count(*) from public.companies c where %s and not (c.id = any (%L::text[]))',
    public.company_filter_sql_v3('', v_filters), v_ids) into v_outside;
  if v_outside <> 0 then
    raise exception '% companies outside the set survived the filter', v_outside;
  end if;

  execute format('select count(*) from public.companies c where %s',
    public.company_filter_sql_v3('', jsonb_build_array(jsonb_build_object('field', '__company_ids',
      'operator', 'not_equals', 'values', to_jsonb(v_ids))))) into v_exclude;
  if v_include + v_exclude <> v_total then
    raise exception 'include (%) + exclude (%) <> % companies', v_include, v_exclude, v_total;
  end if;

  -- Builder and row matcher must select the same set, or the grid and a bulk
  -- action on the same filter act on different companies.
  --
  -- Bounded to 2,500 candidates - the 500 in the set and 2,000 that are not -
  -- rather than run across all 419,521. company_matches_filters_v1 is a per-row
  -- function call with a jsonb parse inside it; over the whole table this one
  -- check measured about three minutes, against migrate.sh's five-minute
  -- ceiling for the whole file. The rows it can disagree about are in the
  -- sample by construction: every member of the set, and members of neither.
  select array_cat(v_ids, coalesce(array_agg(other.id), array[]::text[])) into v_candidates
    from (select id from public.companies where not (id = any (v_ids)) order by id limit 2000) other;

  execute format('select count(*) from public.companies c where c.id = any (%L::text[]) and (%s)',
    v_candidates, public.company_filter_sql_v3('', v_filters)) into v_include_sampled;
  execute format('select count(*) from public.companies c where c.id = any (%L::text[]) and public.company_matches_filters_v1(c, %L, %L::jsonb)',
    v_candidates, '', v_filters::text) into v_matcher;
  if v_matcher is distinct from v_include_sampled then
    raise exception '__company_ids disagrees: builder % rows, row matcher % rows', v_include_sampled, v_matcher;
  end if;
  if v_include_sampled <> 500 then
    raise exception 'the sampled builder count is % rather than the 500 in the set', v_include_sampled;
  end if;

  -- And the pre-filter never drops a row the complete predicate keeps.
  execute format('select count(*) from public.companies c where %s',
    public.company_prefilter_sql('', v_filters)) into v_prefilter;
  if v_prefilter < v_include then
    raise exception 'the pre-filter (% rows) drops companies the complete filter keeps (%)', v_prefilter, v_include;
  end if;

  raise notice '__company_ids: % of % companies, matcher agrees, pre-filter keeps %, exclude %',
    v_include, v_total, v_prefilter, v_exclude;
end $$;

-- An empty set narrows nothing rather than matching everything by accident, and
-- an id that does not exist simply is not there. Both are reachable: a coverage
-- check can match nothing, and a company can be deleted between the check and
-- the click.
do $$
declare
  v_sql text;
  v_count bigint;
begin
  v_sql := public.company_filter_sql_v3('', '[{"field":"__company_ids","operator":"equals","values":[]}]'::jsonb);
  if v_sql <> 'true' then
    raise exception 'an empty __company_ids compiled to %, not to a no-op', v_sql;
  end if;

  execute format('select count(*) from public.companies c where %s',
    public.company_filter_sql_v3('', '[{"field":"__company_ids","operator":"equals","values":["no-such-company-id"]}]'::jsonb))
    into v_count;
  if v_count <> 0 then
    raise exception 'an unknown company id matched % rows', v_count;
  end if;
end $$;
