-- __list_ids: include or exclude whole lists in the People database, by id.
--
-- Modelled line for line on __client_ids (20260915130000), for the identical
-- reason that one existed: pi.list_ids is the identity array (list_names is
-- display text and can be edited without changing which rows a saved filter
-- returns), and an array-overlap include belongs on the GIN index while an
-- exclude cannot - a negated overlap is not a NECESSARY condition for the
-- pre-filter, only the complete predicate can express it.
--
-- WHAT THIS UNLOCKS. The List workspace (app/components/ListsPanel.tsx) is 27
-- lines with no bulk action of any kind - no selection, no export, nothing.
-- Rather than build a second, smaller copy of the People/Company database's
-- bulk actions on top of it, "See People" and "See Companies" pivot into the
-- REAL databases already filtered to this list, which is what this field is
-- for. It is also offered directly as a Lists filter chip in both.
--
-- pi.list_ids had no index at all before this - only list_names did
-- (idx_prospect_index_list_names) - so the include arm below is a full scan
-- until the GIN index is built.
-- ---------------------------------------------------------------------------

create index if not exists idx_prospect_index_list_ids
  on public.prospect_index using gin (list_ids);

do $patch_list_ids$
declare
  v_definition text;
  v_rewritten text;
  v_anchor text;
begin
  -- 1. The SQL builder.
  v_anchor := $anchor$    -- Include or exclude whole clients, by id. Names are display text and are
    -- editable; ids are what pi.client_ids holds and what the GIN index covers.
    if field_key = '__client_ids' then
      if cardinality(raw_values) = 0 then continue; end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || format('(not (pi.client_ids && %L::text[]))', raw_values);
      else
        conjuncts := conjuncts || format('(pi.client_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;$anchor$;
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if v_definition not like '%__list_ids%' then
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1 anchor appears % times, expected exactly 1',
        (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
    end if;
    v_rewritten := replace(v_definition, v_anchor, v_anchor || $new$

    -- Include or exclude whole lists, by id. Same shape as __client_ids and for
    -- the same reason: pi.list_ids is the identity array the GIN index covers.
    if field_key = '__list_ids' then
      if cardinality(raw_values) = 0 then continue; end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || format('(not (pi.list_ids && %L::text[]))', raw_values);
      else
        conjuncts := conjuncts || format('(pi.list_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;$new$);
    execute v_rewritten;
  end if;

  -- 2. The row matcher, which must agree with the builder exactly.
  v_anchor := $anchor$      when filter_item->>'field' = '__client_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> ((p_row).client_ids && array(select value from jsonb_array_elements_text(filter_item->'values'))::text[]))
      )$anchor$;
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  if v_definition not like '%__list_ids%' then
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_index_matches_v1 anchor appears % times, expected exactly 1',
        (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
    end if;
    v_rewritten := replace(v_definition, v_anchor, v_anchor || $new$
      when filter_item->>'field' = '__list_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> ((p_row).list_ids && array(select value from jsonb_array_elements_text(filter_item->'values'))::text[]))
      )$new$);
    execute v_rewritten;
  end if;

  -- 3. The pre-filter gets the INCLUDE half only, for the reason the header
  --    gives: a negated overlap is not a necessary condition for the complete
  --    predicate, so it cannot appear here.
  v_anchor := $anchor$    if field_key = '__client_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format('(pi.client_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;$anchor$;
  select pg_get_functiondef('public.prospect_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  if v_definition not like '%__list_ids%' then
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_prefilter_sql anchor appears % times, expected exactly 1',
        (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
    end if;
    v_rewritten := replace(v_definition, v_anchor, v_anchor || $new$

    if field_key = '__list_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format('(pi.list_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;$new$);
    execute v_rewritten;
  end if;
end $patch_list_ids$;

-- ---------------------------------------------------------------------------
-- Builder, row matcher and pre-filter all agree, over real production lists -
-- not a synthetic id no row can carry.
do $$
declare
  v_list text;
  v_filters jsonb;
  v_include bigint;
  v_exclude bigint;
  v_total bigint;
  v_member_count bigint;
  v_candidates text[];
  v_include_sampled bigint;
  v_matcher bigint;
  v_prefilter bigint;
begin
  select l.id into v_list
  from public.lists l
  where exists (select 1 from public.list_memberships lm where lm.list_id = l.id)
  order by (select count(*) from public.list_memberships lm where lm.list_id = l.id) desc
  limit 1;

  if v_list is null then
    raise notice 'no list has members; __list_ids is unproven';
    return;
  end if;
  v_filters := jsonb_build_array(jsonb_build_object('field', '__list_ids', 'operator', 'contains', 'values', jsonb_build_array(v_list)));

  select count(*) into v_total from public.prospect_index;
  select count(*) into v_member_count from public.list_memberships where list_id = v_list;

  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_filter_sql_v1('', v_filters)) into v_include;
  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object('field', '__list_ids', 'operator', 'not_contains', 'values', jsonb_build_array(v_list)))))
    into v_exclude;

  if v_include + v_exclude <> v_total then
    raise exception 'list %: include (%) + exclude (%) <> % prospects', v_list, v_include, v_exclude, v_total;
  end if;
  if v_include <> v_member_count then
    raise exception 'list %: filter matched %, list_memberships has %', v_list, v_include, v_member_count;
  end if;

  -- Builder and row matcher must select the same set over the same candidates,
  -- bounded to a sample for the reason __company_ids bounded its own check:
  -- the matcher is a per-row function call with a jsonb parse.
  select array_cat(
      coalesce((select array_agg(id) from (select id from public.prospect_index where v_list = any(list_ids) limit 500) x), array[]::text[]),
      coalesce((select array_agg(id) from (select id from public.prospect_index where not (v_list = any(list_ids)) limit 2000) y), array[]::text[])
    ) into v_candidates;

  execute format('select count(*) from public.prospect_index pi where pi.id = any (%L::text[]) and (%s)',
    v_candidates, public.prospect_filter_sql_v1('', v_filters)) into v_include_sampled;
  select count(*) into v_matcher
  from public.prospect_index pi
  where pi.id = any(v_candidates)
    and public.prospect_index_matches_v1(pi, '', v_filters);
  if v_matcher is distinct from v_include_sampled then
    raise exception 'list %: builder matched % of the sample, row matcher matched %', v_list, v_include_sampled, v_matcher;
  end if;

  -- And the pre-filter never drops a row the complete predicate keeps.
  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_prefilter_sql('', v_filters)) into v_prefilter;
  if v_prefilter < v_include then
    raise exception 'the pre-filter (%) drops rows the complete filter keeps (%)', v_prefilter, v_include;
  end if;

  raise notice '__list_ids: list % has % members of % prospects, matcher agrees, pre-filter keeps %',
    v_list, v_include, v_total, v_prefilter;
end $$;

-- An empty value list narrows nothing, not everything.
do $$
declare
  v_sql text;
begin
  v_sql := public.prospect_filter_sql_v1('', '[{"field":"__list_ids","operator":"contains","values":[]}]'::jsonb);
  if v_sql is not null and v_sql <> 'true' then
    raise exception 'an empty __list_ids compiled to %, not to a no-op', v_sql;
  end if;
end $$;
