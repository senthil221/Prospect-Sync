-- The same client include/exclude, for the Master Company DB.
--
-- 20260915130000 did the People half against pi.client_ids, a denormalized
-- array with a GIN index. Companies have no such array: membership lives in
-- public.client_companies, so this is a semi-join rather than an overlap.
--
--   include   exists (select 1 from client_companies cc where cc.company_id = c.id and cc.client_id = any(...))
--   exclude   not exists (...)
--
-- WHY NOT companies.client_count. It is a stored count maintained by a trigger
-- on prospect_index (see 20260911120000 and the company_summaries contract) and
-- it says how many clients a company touches, not which. "Exclude Krishify"
-- cannot be answered by a number.
--
-- THE INDEX. idx_client_companies_company is (company_id, client_id), which is
-- exactly the direction this reads: company first, then the client test. The
-- include arm goes into company_prefilter_sql; the exclude arm does not, for
-- the same reason as the People half - a pre-filter has to be a NECESSARY
-- condition, and "not exists" is not implied by any positive index probe.
--
-- The prefilter arm matters more here than it did for People. The client
-- People workspace already narrows by pi.client_ids before any filter runs, but
-- the Master Company DB has no such scope: without a prefilter arm the exists()
-- would be evaluated across all 419,521 companies.
-- ---------------------------------------------------------------------------

do $patch_company_client_ids$
declare
  v_definition text;
  v_rewritten text;
begin
  -- 1. The SQL builder.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  -- Anchored on the single line that opens the CASE, not on that line plus its
  -- first arm. The obvious two-line anchor does not match: 20260908141654
  -- spliced __company_icp_verified in between them, which is precisely what a
  -- splice does to the next person's anchor. One stable line, or a raise.
  v_rewritten := replace(v_definition,
    $old$      candidate_expr := case field_key$old$,
    $new$      if field_key = '__company_client_ids' then
        if cardinality(raw_values) = 0 then continue; end if;
        if operator_key in ('not_contains', 'not_equals') then
          conjuncts := conjuncts || format($cc$(not exists (select 1 from public.client_companies cc
            where cc.company_id = c.id and cc.client_id = any (%L::text[])))$cc$, raw_values);
        else
          conjuncts := conjuncts || format($cc$(exists (select 1 from public.client_companies cc
            where cc.company_id = c.id and cc.client_id = any (%L::text[])))$cc$, raw_values);
        end if;
        continue;
      end if;
      candidate_expr := case field_key$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_filter_sql_v3 for __company_client_ids'; end if;
  execute v_rewritten;

  -- 2. The row matcher. Unlike its People twin this one has not been wrapped
  --    before, so the operator CASE gets a field CASE around it and the extra
  --    end is closed below.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    where not case coalesce(filter_item->>'operator', 'contains')$old$,
    $new$    where not case
      when filter_item->>'field' = '__company_client_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.client_companies cc
                  where cc.company_id = (p_row).id
                    and cc.client_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      else case coalesce(filter_item->>'operator', 'contains')$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_matches_filters_v1 for __company_client_ids'; end if;
  v_definition := v_rewritten;

  v_rewritten := replace(v_definition,
    $old$    end
  );
$old$,
    $new$    end end
  );
$new$);
  if v_rewritten = v_definition then raise exception 'Could not close the wrapped CASE in company_matches_filters_v1'; end if;
  execute v_rewritten;

  -- 3. The pre-filter gets the INCLUDE half only.
  select pg_get_functiondef('public.company_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    field_key := filter_item->>'field';$old$,
    $new$    field_key := filter_item->>'field';
    -- Served by idx_client_companies_company (company_id, client_id). Only
    -- reached for contains/equals; the loop skipped every other operator above.
    if field_key = '__company_client_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format($cc$(exists (select 1 from public.client_companies cc
          where cc.company_id = c.id and cc.client_id = any (%L::text[])))$cc$, raw_values);
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_prefilter_sql for __company_client_ids'; end if;
  execute v_rewritten;
end $patch_company_client_ids$;

-- ---------------------------------------------------------------------------
do $$
declare
  v_client text;
  v_include bigint;
  v_exclude bigint;
  v_matcher bigint;
  v_total bigint;
  v_wrong bigint;
  v_prefilter bigint;
begin
  select cc.client_id into v_client from public.client_companies cc
   group by cc.client_id order by count(*) desc limit 1;
  if v_client is null then
    raise notice 'no client has any company membership; skipping the behavioural checks';
    return;
  end if;

  select count(*) into v_total from public.companies;

  execute format('select count(*) from public.companies c where %s',
    public.company_filter_sql_v3('', jsonb_build_array(jsonb_build_object(
      'field', '__company_client_ids', 'operator', 'contains', 'values', jsonb_build_array(v_client))))) into v_include;
  execute format('select count(*) from public.companies c where %s',
    public.company_filter_sql_v3('', jsonb_build_array(jsonb_build_object(
      'field', '__company_client_ids', 'operator', 'not_contains', 'values', jsonb_build_array(v_client))))) into v_exclude;

  if v_include + v_exclude <> v_total then
    raise exception 'include (%) + exclude (%) <> % companies', v_include, v_exclude, v_total;
  end if;

  execute format($q$select count(*) from public.companies c
                   where (%s) and exists (select 1 from public.client_companies cc
                     where cc.company_id = c.id and cc.client_id = %L)$q$,
    public.company_filter_sql_v3('', jsonb_build_array(jsonb_build_object(
      'field', '__company_client_ids', 'operator', 'not_contains', 'values', jsonb_build_array(v_client)))),
    v_client) into v_wrong;
  if v_wrong <> 0 then
    raise exception '% companies in the client survived being excluded', v_wrong;
  end if;

  -- Builder and row matcher must select the same set.
  execute format($q$select count(*) from public.companies c
                   where public.company_matches_filters_v1(c, '', %L::jsonb)$q$,
    jsonb_build_array(jsonb_build_object('field', '__company_client_ids', 'operator', 'contains',
      'values', jsonb_build_array(v_client)))) into v_matcher;
  if v_matcher is distinct from v_include then
    raise exception '__company_client_ids disagrees: builder % rows, row matcher % rows', v_include, v_matcher;
  end if;

  -- The pre-filter must never drop a row the complete predicate keeps.
  execute format('select count(*) from public.companies c where %s',
    public.company_prefilter_sql('', jsonb_build_array(jsonb_build_object(
      'field', '__company_client_ids', 'operator', 'contains', 'values', jsonb_build_array(v_client))))) into v_prefilter;
  if v_prefilter < v_include then
    raise exception 'the pre-filter (% rows) drops companies the complete filter keeps (%)', v_prefilter, v_include;
  end if;

  raise notice '__company_client_ids: include %, exclude %, of % - matcher agrees, pre-filter keeps %',
    v_include, v_exclude, v_total, v_prefilter;
end $$;
