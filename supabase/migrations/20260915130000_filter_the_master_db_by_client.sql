-- Include or exclude clients in the Master People DB, by id.
--
-- WHY NOT __clients, WHICH ALREADY EXISTS. It compares against
-- array_to_string(pi.client_names, ' | '), so for a prospect in two clients the
-- value under test is the string "Krishify | Unassigned". Excluding one client
-- then keeps that prospect, because the joined string is not equal to either
-- name on its own.
--
-- Measured on production 2026-09-15. 4,497 prospects belong to two or more
-- clients. Excluding "Krishify" the way __clients does it:
--
--   prospects still returned that ARE in Krishify, excluded by name   3,570
--   prospects still returned that ARE in Krishify, excluded by id         0
--
-- 3,570 rows the user asked not to see. And __clients with not_contains is
-- worse again: it is a substring test over mutable display names, so excluding
-- "Acme" also excludes "Acme Recruitment". __clients is left exactly as it is -
-- saved views depend on it - and this is a new field rather than a redefinition
-- of that one.
--
-- WHY IDS. pi.client_ids is the identity array and already carries a GIN index
-- (idx_prospect_index_client_ids). Names are for display and can be edited;
-- editing one must not silently change which rows a saved filter returns.
--
-- INCLUDE IS INDEXED, EXCLUDE IS NOT, AND THAT IS NOT AN OVERSIGHT.
--
--   include   pi.client_ids && array[...]        GIN index
--   exclude   not (pi.client_ids && array[...])  no index is possible
--
-- A GIN index answers "which rows contain this" and cannot answer "which rows
-- do not". So the include arm goes in prospect_prefilter_sql and the exclude
-- arm deliberately does not: a pre-filter has to be a NECESSARY condition for
-- the complete predicate, and a negation over GIN is not expressible as one.
-- Adding it there would not be slow, it would be wrong.
--
-- What exclude-only costs: a full scan of prospect_index. 20260902000260
-- measured a full index-only scan at 175-234ms and a filtered full scan at
-- 1.25s against 681,085 rows, and an array-overlap test per row is cheaper than
-- the ILIKE in that measurement. Combining an exclude with any positive filter
-- puts it back on the index via the pre-filter. If it ever does exceed the
-- ceiling, lib/api-errors.ts turns 57014 into the "took longer than the
-- database allows" message rather than a hang.
-- ---------------------------------------------------------------------------

do $patch_client_ids$
declare
  v_definition text;
  v_rewritten text;
begin
  -- 1. The SQL builder. Array overlap, so it is answered before the
  --    candidate_expr CASE, like the other non-column fields.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    lowered := array(select lower(value) from unnest(raw_values) value);$old$,
    $new$    lowered := array(select lower(value) from unnest(raw_values) value);

    -- Include or exclude whole clients, by id. Names are display text and are
    -- editable; ids are what pi.client_ids holds and what the GIN index covers.
    if field_key = '__client_ids' then
      if cardinality(raw_values) = 0 then continue; end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || format('(not (pi.client_ids && %L::text[]))', raw_values);
      else
        conjuncts := conjuncts || format('(pi.client_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_filter_sql_v1 for __client_ids'; end if;
  execute v_rewritten;

  -- 2. The row matcher, which must agree with the builder exactly. Anchored on
  --    the __lead arm that 20260915110000 put in, and inserted before it.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$      when filter_item->>'field' = '__lead' then ($old$,
    $new$      when filter_item->>'field' = '__client_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> ((p_row).client_ids && array(select value from jsonb_array_elements_text(filter_item->'values'))::text[]))
      )
      when filter_item->>'field' = '__lead' then ($new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_index_matches_v1 for __client_ids'; end if;
  execute v_rewritten;

  -- 3. The pre-filter gets the INCLUDE half only. See the header: a negated
  --    overlap is not a necessary condition and must not appear here.
  select pg_get_functiondef('public.prospect_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    field_key := filter_item->>'field';$old$,
    $new$    field_key := filter_item->>'field';
    -- Array overlap on the GIN index rather than a column comparison, so it is
    -- answered before the column CASE. Only reached for contains/equals: the
    -- loop has already skipped every other operator above.
    if field_key = '__client_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format('(pi.client_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_prefilter_sql for __client_ids'; end if;
  execute v_rewritten;
end $patch_client_ids$;

-- ---------------------------------------------------------------------------
do $$
declare
  v_client text;
  v_other text;
  v_include bigint;
  v_exclude bigint;
  v_matcher bigint;
  v_total bigint;
  v_wrong bigint;
  v_prefilter bigint;
begin
  select id into v_client from public.clients where id <> 'prospect-sync-no-client'
   order by (select count(*) from public.client_prospects cp where cp.client_id = clients.id) desc limit 1;
  select id into v_other from public.clients where id <> v_client order by id limit 1;
  if v_client is null then
    raise notice 'no clients to assert against';
    return;
  end if;

  select count(*) into v_total from public.prospect_index;

  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__client_ids', 'operator', 'contains', 'values', jsonb_build_array(v_client))))) into v_include;
  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__client_ids', 'operator', 'not_contains', 'values', jsonb_build_array(v_client))))) into v_exclude;

  -- Include and exclude must partition the index. This is what the name-based
  -- filter fails: a prospect in two clients satisfies neither half.
  if v_include + v_exclude <> v_total then
    raise exception 'include (%) + exclude (%) <> % rows', v_include, v_exclude, v_total;
  end if;

  -- And exclude must actually exclude. Counting rows that are in the client but
  -- survived the exclusion is precisely the 3,570-row bug being fixed.
  execute format($q$select count(*) from public.prospect_index pi
                   where (%s) and pi.client_ids @> array[%L]::text[]$q$,
    public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__client_ids', 'operator', 'not_contains', 'values', jsonb_build_array(v_client)))),
    v_client) into v_wrong;
  if v_wrong <> 0 then
    raise exception '% prospects in the client survived being excluded', v_wrong;
  end if;

  -- The builder and the row matcher must select the same set.
  execute format($q$select count(*) from public.prospect_index pi
                   where public.prospect_index_matches_v1(pi, '', %L::jsonb)$q$,
    jsonb_build_array(jsonb_build_object('field', '__client_ids', 'operator', 'contains',
      'values', jsonb_build_array(v_client)))) into v_matcher;
  if v_matcher is distinct from v_include then
    raise exception '__client_ids disagrees: builder % rows, row matcher % rows', v_include, v_matcher;
  end if;

  -- The pre-filter must be a NECESSARY condition: everything the complete
  -- predicate returns, it must also return. Never fewer.
  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_prefilter_sql('', jsonb_build_array(jsonb_build_object(
      'field', '__client_ids', 'operator', 'contains', 'values', jsonb_build_array(v_client))))) into v_prefilter;
  if v_prefilter < v_include then
    raise exception 'the pre-filter (% rows) drops rows the complete filter keeps (%)', v_prefilter, v_include;
  end if;

  raise notice '__client_ids: include %, exclude %, of % - matcher agrees, pre-filter keeps %',
    v_include, v_exclude, v_total, v_prefilter;

  -- Two clients at once is a union, not an intersection.
  if v_other is not null then
    execute format('select count(*) from public.prospect_index pi where %s',
      public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
        'field', '__client_ids', 'operator', 'contains',
        'values', jsonb_build_array(v_client, v_other))))) into v_matcher;
    if v_matcher < v_include then
      raise exception 'including a second client returned fewer rows (% vs %)', v_matcher, v_include;
    end if;
  end if;
end $$;
