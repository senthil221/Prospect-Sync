-- One canonical, server-owned client origin for company questions.
--
-- Client Company DB coverage is the number of this client's people at a
-- company. The ordinary listing already used that definition, but streamed
-- exports, frozen result sets and Company -> People pivots compiled
-- __company_coverage against companies.prospect_count (global coverage). The
-- app now adds __client_company_scope after parsing and binds it to the route's
-- real client. These three company filter paths consume it identically:
--   * compiled SQL (listings, streams, result sets and pivots)
--   * the row matcher (legacy/small bulk paths)
--   * the index-friendly prefilter
-- Master questions contain no internal predicate and keep their old global
-- coverage semantics.

set local lock_timeout = '10s';

create or replace function prospect_results.client_company_scope_value_v1(p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = pg_catalog, public, prospect_results
as $$
declare
  v_item jsonb;
  v_count integer;
  v_client text;
begin
  select count(*)::integer into v_count
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item(value)
   where value->>'field' = '__client_company_scope';
  if v_count = 0 then return null; end if;
  select value into v_item
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item(value)
   where value->>'field' = '__client_company_scope'
   limit 1;
  if v_count <> 1
     or coalesce(v_item->>'operator', '') <> 'equals'
     or jsonb_typeof(v_item->'values') is distinct from 'array' then
    raise exception using errcode = '22023', message = 'Invalid server-owned client company scope.';
  end if;
  if jsonb_array_length(v_item->'values') <> 1
     or jsonb_typeof(v_item->'values'->0) is distinct from 'string' then
    raise exception using errcode = '22023', message = 'Invalid server-owned client company scope.';
  end if;
  v_client := btrim(v_item->'values'->>0);
  if v_client is null or v_client = '' then
    raise exception using errcode = '22023', message = 'Invalid server-owned client company scope.';
  end if;
  return v_client;
end;
$$;

revoke execute on function prospect_results.client_company_scope_value_v1(jsonb) from public, anon, authenticated;
grant execute on function prospect_results.client_company_scope_value_v1(jsonb) to service_role;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'prospect_operator') then
    execute 'grant execute on function prospect_results.client_company_scope_value_v1(jsonb) to prospect_operator';
  end if;
end $$;

do $patch_company_scope$
declare
  v_definition text;
  v_rewritten text;
  v_anchor text;
begin
  -- Complete SQL compiler.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  if v_definition not like '%v_client_scope text := prospect_results.client_company_scope_value_v1(p_filters)%' then
    v_anchor := '  lowered text[];' || chr(10) || '  minimum text;';
    if strpos(v_definition, v_anchor) = 0 then raise exception 'company_filter_sql_v3 declaration anchor moved'; end if;
    v_definition := replace(v_definition, v_anchor,
      '  lowered text[];' || chr(10)
      || '  v_client_scope text := prospect_results.client_company_scope_value_v1(p_filters);' || chr(10)
      || '  minimum text;');

    v_anchor := '      if field_key = ''__company_client_ids'' then';
    if strpos(v_definition, v_anchor) = 0 then raise exception 'company_filter_sql_v3 client anchor moved'; end if;
    v_definition := replace(v_definition, v_anchor,
      $new$      if field_key = '__client_company_scope' then
        conjuncts := array_append(conjuncts, format($scope$(exists (select 1 from public.client_companies origin
          where origin.company_id = c.id and origin.client_id = %L))$scope$, v_client_scope));
        continue;
      end if;
      if field_key = '__company_client_ids' then$new$);

    v_anchor := $old$      if field_key = '__company_coverage' then
        if cardinality(raw_values) = 0 then continue; end if;
        if raw_values[1] = 'with' then
          conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) > 0)');
        elsif raw_values[1] = 'without' then
          conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) = 0)');
        end if;
        continue;
      end if;$old$;
    if strpos(v_definition, v_anchor) = 0 then raise exception 'company_filter_sql_v3 coverage anchor moved'; end if;
    v_definition := replace(v_definition, v_anchor,
      $new$      if field_key = '__company_coverage' then
        if cardinality(raw_values) = 0 then continue; end if;
        if v_client_scope is not null and raw_values[1] = 'with' then
          conjuncts := array_append(conjuncts, format($coverage$(exists (select 1 from public.prospect_index covered
            where covered.company_id = c.id and covered.client_ids @> array[%L]))$coverage$, v_client_scope));
        elsif v_client_scope is not null and raw_values[1] = 'without' then
          conjuncts := array_append(conjuncts, format($coverage$(not exists (select 1 from public.prospect_index covered
            where covered.company_id = c.id and covered.client_ids @> array[%L]))$coverage$, v_client_scope));
        elsif raw_values[1] = 'with' then
          conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) > 0)');
        elsif raw_values[1] = 'without' then
          conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) = 0)');
        end if;
        continue;
      end if;$new$);
    execute v_definition;
  end if;

  -- Per-row matcher used by selection fallbacks.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  if v_definition not like '%__client_company_scope%' then
    v_anchor := '    where not case';
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_matches_filters_v1 case anchor moved';
    end if;
    v_definition := replace(v_definition, v_anchor,
      $new$    where not case
      when filter_item->>'field' = '__client_company_scope' then (
        prospect_results.client_company_scope_value_v1(p_filters) is not null
        and exists (select 1 from public.client_companies origin
          where origin.company_id = (p_row).id
            and origin.client_id = prospect_results.client_company_scope_value_v1(p_filters))
      )$new$);

    v_anchor := $old$      when filter_item->>'field' = '__company_coverage' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or case filter_item->'values'->>0
             when 'with' then coalesce((p_row).prospect_count, 0) > 0
             when 'without' then coalesce((p_row).prospect_count, 0) = 0
             else true
           end
      )$old$;
    if strpos(v_definition, v_anchor) = 0 then raise exception 'company_matches_filters_v1 coverage anchor moved'; end if;
    v_definition := replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__company_coverage' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or case
             when prospect_results.client_company_scope_value_v1(p_filters) is not null
               and filter_item->'values'->>0 = 'with' then exists (
                 select 1 from public.prospect_index covered
                  where covered.company_id = (p_row).id
                    and covered.client_ids @> array[prospect_results.client_company_scope_value_v1(p_filters)])
             when prospect_results.client_company_scope_value_v1(p_filters) is not null
               and filter_item->'values'->>0 = 'without' then not exists (
                 select 1 from public.prospect_index covered
                  where covered.company_id = (p_row).id
                    and covered.client_ids @> array[prospect_results.client_company_scope_value_v1(p_filters)])
             when filter_item->'values'->>0 = 'with' then coalesce((p_row).prospect_count, 0) > 0
             when filter_item->'values'->>0 = 'without' then coalesce((p_row).prospect_count, 0) = 0
             else true
           end
      )$new$);
    execute v_definition;
  end if;

  -- Necessary-condition prefilter. Both client coverage arms are exact.
  select pg_get_functiondef('public.company_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  if v_definition not like '%v_client_scope text := prospect_results.client_company_scope_value_v1(p_filters)%' then
    v_anchor := '  raw_values text[];' || chr(10) || '  value_text text;';
    if strpos(v_definition, v_anchor) = 0 then raise exception 'company_prefilter_sql declaration anchor moved'; end if;
    v_definition := replace(v_definition, v_anchor,
      '  raw_values text[];' || chr(10)
      || '  v_client_scope text := prospect_results.client_company_scope_value_v1(p_filters);' || chr(10)
      || '  value_text text;');

    v_anchor := $old$    if field_key = '__company_coverage' then
      if coalesce(filter_item->'values'->>0, '') = 'with' then
        conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) > 0)');
      elsif coalesce(filter_item->'values'->>0, '') = 'without' then
        conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) = 0)');
      end if;
      continue;
    end if;$old$;
    if strpos(v_definition, v_anchor) = 0 then raise exception 'company_prefilter_sql coverage anchor moved'; end if;
    v_definition := replace(v_definition, v_anchor,
      $new$    if field_key = '__client_company_scope' then
      conjuncts := array_append(conjuncts, format($scope$(exists (select 1 from public.client_companies origin
        where origin.company_id = c.id and origin.client_id = %L))$scope$, v_client_scope));
      continue;
    end if;
    if field_key = '__company_coverage' then
      if v_client_scope is not null and coalesce(filter_item->'values'->>0, '') = 'with' then
        conjuncts := array_append(conjuncts, format($coverage$(exists (select 1 from public.prospect_index covered
          where covered.company_id = c.id and covered.client_ids @> array[%L]))$coverage$, v_client_scope));
      elsif v_client_scope is not null and coalesce(filter_item->'values'->>0, '') = 'without' then
        conjuncts := array_append(conjuncts, format($coverage$(not exists (select 1 from public.prospect_index covered
          where covered.company_id = c.id and covered.client_ids @> array[%L]))$coverage$, v_client_scope));
      elsif coalesce(filter_item->'values'->>0, '') = 'with' then
        conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) > 0)');
      elsif coalesce(filter_item->'values'->>0, '') = 'without' then
        conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) = 0)');
      end if;
      continue;
    end if;$new$);
    execute v_definition;
  end if;

  -- client_company_workspace_v2 already receives the trusted client as an RPC
  -- argument and has a fast unfiltered path. Strip the redundant internal
  -- predicate there so canonicalization does not turn every client page into a
  -- filtered lateral-count query. Its coverage arm already uses this client's
  -- stored membership count.
  select pg_get_functiondef('public.client_company_workspace_v2(text,text,jsonb,jsonb,integer,integer)'::regprocedure) into v_definition;
  if v_definition not like '%not in (''__company_coverage'', ''__client_company_scope'')%' then
    v_anchor := '    where value->>''field'' <> ''__company_coverage''';
    if strpos(v_definition, v_anchor) = 0 then raise exception 'client_company_workspace_v2 filter anchor moved'; end if;
    v_rewritten := replace(v_definition, v_anchor,
      '    where value->>''field'' not in (''__company_coverage'', ''__client_company_scope'')');
    execute v_rewritten;
  end if;
end;
$patch_company_scope$;

-- Bounded structural checks. Full data parity belongs in the disposable CI
-- fixture: a release migration must never scan every production company while
-- it is holding function-definition locks.
do $proof$
declare
  v_filters jsonb;
  v_sql text;
begin
  foreach v_filters in array array[
    '[{"field":"__client_company_scope","operator":"contains","values":["x"]}]'::jsonb,
    '[{"field":"__client_company_scope","operator":"equals"}]'::jsonb,
    '[{"field":"__client_company_scope","operator":"equals","values":null}]'::jsonb,
    '[{"field":"__client_company_scope","operator":"equals","values":[null]}]'::jsonb,
    '[{"field":"__client_company_scope","operator":"equals","values":["x","y"]}]'::jsonb,
    '[{"field":"__client_company_scope","operator":"equals","values":["x"]},{"field":"__client_company_scope","operator":"equals","values":["x"]}]'::jsonb
  ] loop
    begin
      perform prospect_results.client_company_scope_value_v1(v_filters);
      raise exception 'malformed internal company scope was accepted: %', v_filters;
    exception when sqlstate '22023' then null;
    end;
  end loop;

  v_filters := '[{"field":"__client_company_scope","operator":"equals","values":["client''quoted"]}]'::jsonb;
  v_sql := public.company_filter_sql_v3('', v_filters, false);
  if v_sql not like '%client''''quoted%' then
    raise exception 'client company scope was not literal-quoted: %', v_sql;
  end if;
end;
$proof$;
