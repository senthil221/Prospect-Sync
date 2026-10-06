-- "ICP Unverified" leaves out companies an ICP check marked NON_FIT.
--
-- The client People and Company DBs' ICP Unverified switch meant "not marked
-- ICP verified", so it also listed every company the ICP check had already
-- judged NON_FIT - 492 on 2026-10-06 across six clients. A NON_FIT company is
-- normally blocklisted by the check (auto-apply, 20260930260000) and drops out
-- of the client; these had not been: 214 have no website domain, which the
-- domain blocklist cannot hold, and 282 came from Testing ICP's comparison
-- checks run before auto-apply existed.
--
-- New filter field __icp_unverified, value [client id]: not ICP verified for
-- the client AND the company's current ICP check result is not NON_FIT
-- (company_icp_check_matches_v1, the same rule the ICP check column shows).
-- People are judged by their company. Companies never checked, or checked
-- FIT and not yet verified, stay in the view.
--
-- Spliced into the two compilers and the two row matchers the way
-- __client_seg_policy was (20261003100000), with a rolled-back proof that
-- both paths agree.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

do $patch$
declare
  v_definition text;
  v_anchor text;
begin
  -- People, compiled SQL.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if position('__icp_unverified' in v_definition) = 0 then
    v_anchor := $old$    if field_key in ('__lead', '__contactable') then$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1: Lead/Contactable anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$    -- ICP Unverified: not verified for the client, and the person's company
    -- is not NON_FIT by the client's current ICP check (20261006090000).
    if field_key = '__icp_unverified' then
      if cardinality(raw_values) < 1 then continue; end if;
      conjuncts := conjuncts || format($iu$(not (%1$L = any (pi.icp_verified_client_ids)) and not (pi.company_id is not null and public.company_icp_check_matches_v1(pi.company_id, %1$L, 'NON_FIT')))$iu$, raw_values[1]);
      continue;
    end if;

    if field_key in ('__lead', '__contactable') then$new$);
  end if;

  -- People, row matcher.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  if position('__icp_unverified' in v_definition) = 0 then
    v_anchor := $old$      when filter_item->>'field' = '__lead' then ($old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_index_matches_v1: Lead anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__icp_unverified' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or (not ((filter_item->'values'->>0) = any ((p_row).icp_verified_client_ids))
            and not ((p_row).company_id is not null
                     and public.company_icp_check_matches_v1((p_row).company_id, filter_item->'values'->>0, 'NON_FIT')))
      )
      when filter_item->>'field' = '__lead' then ($new$);
  end if;

  -- Companies, compiled SQL.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  if position('__icp_unverified' in v_definition) = 0 then
    v_anchor := $old$      if field_key = '__company_tags' then$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_filter_sql_v3: company tags anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$      -- ICP Unverified (20261006090000).
      if field_key = '__icp_unverified' then
        if cardinality(raw_values) = 0 then continue; end if;
        conjuncts := conjuncts || format($iu$(not exists (select 1 from public.client_company_icp_validations iuv where iuv.client_id = %1$L and iuv.company_id = c.id) and not public.company_icp_check_matches_v1(c.id, %1$L, 'NON_FIT'))$iu$, raw_values[1]);
        continue;
      end if;
      if field_key = '__company_tags' then$new$);
  end if;

  -- Companies, row matcher.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  if position('__icp_unverified' in v_definition) = 0 then
    v_anchor := $old$      when filter_item->>'field' = '__company_tags' then ($old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_matches_filters_v1: company tags anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__icp_unverified' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or (not exists (select 1 from public.client_company_icp_validations iuv
                         where iuv.client_id = filter_item->'values'->>0 and iuv.company_id = (p_row).id)
            and not public.company_icp_check_matches_v1((p_row).id, filter_item->'values'->>0, 'NON_FIT'))
      )
      when filter_item->>'field' = '__company_tags' then ($new$);
  end if;
end;
$patch$;

-- Proof, read-only: on the client with the most unverified NON_FIT companies,
-- the compiled filter and the row matcher agree for companies and people, and
-- no NON_FIT company survives the filter.
do $proof$
declare
  v_client text;
  v_filters jsonb;
  v_compiled bigint;
  v_matched bigint;
  v_leaked bigint;
begin
  select cc.client_id into v_client
    from public.client_companies cc
   where public.company_icp_check_matches_v1(cc.company_id, cc.client_id, 'NON_FIT')
   group by cc.client_id order by count(*) desc limit 1;
  v_filters := jsonb_build_array(jsonb_build_object('field', '__icp_unverified', 'operator', 'equals', 'values', jsonb_build_array(coalesce(v_client, 'none'))));

  if public.prospect_filter_sql_v1('', v_filters) not like '%company_icp_check_matches_v1(pi.company_id%'
     or public.company_filter_sql_v3('', v_filters, false) not like '%company_icp_check_matches_v1(c.id%' then
    raise exception 'ICP Unverified proof: a compiler did not learn __icp_unverified';
  end if;
  if v_client is null then
    raise notice 'ICP Unverified proof: no client has a NON_FIT company - compile checks only.';
    return;
  end if;

  execute format('select count(*) from public.companies c join public.client_companies cc on cc.company_id = c.id and cc.client_id = %L where %s',
    v_client, public.company_filter_sql_v3('', v_filters, false)) into v_compiled;
  select count(*) into v_matched from public.companies c
    join public.client_companies cc on cc.company_id = c.id and cc.client_id = v_client
   where public.company_matches_filters_v1(c, '', v_filters);
  execute format('select count(*) from public.companies c join public.client_companies cc on cc.company_id = c.id and cc.client_id = %L where (%s) and public.company_icp_check_matches_v1(c.id, %L, ''NON_FIT'')',
    v_client, public.company_filter_sql_v3('', v_filters, false), v_client) into v_leaked;
  if v_compiled <> v_matched or v_leaked <> 0 then
    raise exception 'ICP Unverified proof (companies): compiled %, matcher %, NON_FIT leaked %', v_compiled, v_matched, v_leaked;
  end if;

  execute format('select count(*) from (select * from public.prospect_index pi where %L = any(pi.client_ids) limit 5000) pi where %s',
    v_client, public.prospect_filter_sql_v1('', v_filters)) into v_compiled;
  select count(*) into v_matched
    from (select * from public.prospect_index pi where v_client = any(pi.client_ids) limit 5000) pi
   where public.prospect_index_matches_v1(pi, '', v_filters);
  if v_compiled <> v_matched then
    raise exception 'ICP Unverified proof (people): compiled %, matcher %', v_compiled, v_matched;
  end if;
  raise notice 'ICP Unverified proof passed on client %.', v_client;
end;
$proof$;
