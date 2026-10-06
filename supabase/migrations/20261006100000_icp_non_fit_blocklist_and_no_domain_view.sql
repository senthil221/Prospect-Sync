-- NON_FIT companies leave ICP Unverified for good: blocklisted when they have
-- a domain, listed under "No domain unverified" when they do not.
--
-- Asked for on 2026-10-06, after 20261006090000 hid NON_FIT companies from ICP
-- Unverified. Of the 492 unverified NON_FIT companies then in client DBs:
--
--   280 have a domain but were never blocklisted - 279 from Testing ICP's
--   three comparison checks, which ran before auto-apply (20260930260000) and
--   so never applied anything, and 1 Kapable company whose domain arrived after
--   its check had been applied. Each one is queued on the ICP check result that
--   gave its current NON_FIT verdict (apply_pending), and the ICP worker's
--   apply_icp_check_results_v1 blocklists the domain the way every ICP check
--   does: reason 'ICP Invalid', source 'icp_check', the company and its people
--   swept out of the client, reversible from the blocklist, and undone by a
--   later review of that result. Those checks now apply their reviews like any
--   new check (auto_apply); none of their FIT results are applied by this.
--
--   212 have no domain, which the domain blocklist cannot hold. New filter
--   field __icp_no_domain_unverified, value [client id]: not ICP verified for
--   the client, the company's current ICP check result is NON_FIT, and the
--   company has no domain. The People and Company DBs show it as a fourth ICP
--   tab. People are judged by their company.
--
-- Spliced into the two compilers and the two row matchers the way
-- __icp_unverified was, with a rolled-back proof that both paths agree.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

-- 1. Queue the NON_FIT results that never reached the blocklist.
with wanted as (
  select distinct on (cc.client_id, cc.company_id) s.check_id, s.company_id
    from public.client_companies cc
    join public.companies c on c.id = cc.company_id
    join public.icp_strategy_checks k on k.client_id = cc.client_id
    join public.icp_strategy_results s on s.check_id = k.id and s.company_id = cc.company_id
   where coalesce(c.normalized_domain, '') <> ''
     and not public.is_free_email_domain_v1(c.normalized_domain)
     and s.verdict = 'NON_FIT'
     -- Blocked once and since taken off the blocklist by hand: leave it off.
     and not (s.applied = 'NON_FIT' and s.applied_blocked)
     and public.company_icp_check_matches_v1(cc.company_id, cc.client_id, 'NON_FIT')
     and not exists (select 1 from public.client_company_icp_validations iv
                      where iv.client_id = cc.client_id and iv.company_id = cc.company_id)
     and not exists (select 1 from public.client_blocklist b
                      where b.client_id = cc.client_id and b.kind = 'domain' and b.value = c.normalized_domain)
   order by cc.client_id, cc.company_id, s.decided_at desc nulls last
),
queued as (
  -- A result applied as NON_FIT while its company had no domain blocked
  -- nothing; clearing applied lets the applier try again with the domain.
  update public.icp_strategy_results s
     set apply_pending = true,
         applied = case when s.applied = 'NON_FIT' then null else s.applied end
    from wanted w
   where s.check_id = w.check_id and s.company_id = w.company_id
  returning s.check_id
)
update public.icp_strategy_checks k
   set auto_apply = true
 where k.id in (select check_id from queued) and not k.auto_apply;

-- 2. "No domain unverified".
do $patch$
declare
  v_definition text;
  v_anchor text;
begin
  -- People, compiled SQL.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if position('__icp_no_domain_unverified' in v_definition) = 0 then
    v_anchor := $old$    if field_key = '__icp_unverified' then$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1: ICP Unverified anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$    -- No domain unverified: the person's company has no domain, is not
    -- verified for the client, and is NON_FIT by its ICP check (20261006100000).
    if field_key = '__icp_no_domain_unverified' then
      if cardinality(raw_values) < 1 then continue; end if;
      conjuncts := conjuncts || format($nd$(pi.company_id is not null and not (%1$L = any (pi.icp_verified_client_ids)) and exists (select 1 from public.companies ndc where ndc.id = pi.company_id and coalesce(ndc.normalized_domain, '') = '') and public.company_icp_check_matches_v1(pi.company_id, %1$L, 'NON_FIT'))$nd$, raw_values[1]);
      continue;
    end if;

    if field_key = '__icp_unverified' then$new$);
  end if;

  -- People, row matcher.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  if position('__icp_no_domain_unverified' in v_definition) = 0 then
    v_anchor := $old$      when filter_item->>'field' = '__icp_unverified' then ($old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_index_matches_v1: ICP Unverified anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__icp_no_domain_unverified' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((p_row).company_id is not null
            and not ((filter_item->'values'->>0) = any ((p_row).icp_verified_client_ids))
            and exists (select 1 from public.companies ndc
                         where ndc.id = (p_row).company_id and coalesce(ndc.normalized_domain, '') = '')
            and public.company_icp_check_matches_v1((p_row).company_id, filter_item->'values'->>0, 'NON_FIT'))
      )
      when filter_item->>'field' = '__icp_unverified' then ($new$);
  end if;

  -- Companies, compiled SQL.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  if position('__icp_no_domain_unverified' in v_definition) = 0 then
    v_anchor := $old$      if field_key = '__icp_unverified' then$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_filter_sql_v3: ICP Unverified anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$      -- No domain unverified (20261006100000).
      if field_key = '__icp_no_domain_unverified' then
        if cardinality(raw_values) = 0 then continue; end if;
        conjuncts := conjuncts || format($nd$(coalesce(c.normalized_domain, '') = '' and not exists (select 1 from public.client_company_icp_validations ndv where ndv.client_id = %1$L and ndv.company_id = c.id) and public.company_icp_check_matches_v1(c.id, %1$L, 'NON_FIT'))$nd$, raw_values[1]);
        continue;
      end if;
      if field_key = '__icp_unverified' then$new$);
  end if;

  -- Companies, row matcher.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  if position('__icp_no_domain_unverified' in v_definition) = 0 then
    v_anchor := $old$      when filter_item->>'field' = '__icp_unverified' then ($old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_matches_filters_v1: ICP Unverified anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__icp_no_domain_unverified' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or (coalesce((p_row).normalized_domain, '') = ''
            and not exists (select 1 from public.client_company_icp_validations ndv
                             where ndv.client_id = filter_item->'values'->>0 and ndv.company_id = (p_row).id)
            and public.company_icp_check_matches_v1((p_row).id, filter_item->'values'->>0, 'NON_FIT'))
      )
      when filter_item->>'field' = '__icp_unverified' then ($new$);
  end if;
end;
$patch$;

-- Proof, read-only: on the client with the most domain-less NON_FIT companies,
-- the compiled filter and the row matcher agree for companies and people, and
-- every company the filter keeps is domain-less and NON_FIT.
do $proof$
declare
  v_client text;
  v_filters jsonb;
  v_compiled bigint;
  v_matched bigint;
  v_wrong bigint;
begin
  select cc.client_id into v_client
    from public.client_companies cc
    join public.companies c on c.id = cc.company_id
   where coalesce(c.normalized_domain, '') = ''
     and public.company_icp_check_matches_v1(cc.company_id, cc.client_id, 'NON_FIT')
     and not exists (select 1 from public.client_company_icp_validations iv
                      where iv.client_id = cc.client_id and iv.company_id = cc.company_id)
   group by cc.client_id order by count(*) desc limit 1;
  v_filters := jsonb_build_array(jsonb_build_object('field', '__icp_no_domain_unverified', 'operator', 'equals', 'values', jsonb_build_array(coalesce(v_client, 'none'))));

  if public.prospect_filter_sql_v1('', v_filters) not like '%ndc.normalized_domain%'
     or public.company_filter_sql_v3('', v_filters, false) not like '%c.normalized_domain%' then
    raise exception 'No domain unverified proof: a compiler did not learn __icp_no_domain_unverified';
  end if;
  if v_client is null then
    raise notice 'No domain unverified proof: no client has a domain-less NON_FIT company - compile checks only.';
    return;
  end if;

  execute format('select count(*) from public.companies c join public.client_companies cc on cc.company_id = c.id and cc.client_id = %L where %s',
    v_client, public.company_filter_sql_v3('', v_filters, false)) into v_compiled;
  select count(*) into v_matched from public.companies c
    join public.client_companies cc on cc.company_id = c.id and cc.client_id = v_client
   where public.company_matches_filters_v1(c, '', v_filters);
  execute format('select count(*) from public.companies c join public.client_companies cc on cc.company_id = c.id and cc.client_id = %L where (%s) and (coalesce(c.normalized_domain, '''') <> '''' or not public.company_icp_check_matches_v1(c.id, %L, ''NON_FIT''))',
    v_client, public.company_filter_sql_v3('', v_filters, false), v_client) into v_wrong;
  if v_compiled <> v_matched or v_wrong <> 0 or v_compiled = 0 then
    raise exception 'No domain unverified proof (companies): compiled %, matcher %, wrong %', v_compiled, v_matched, v_wrong;
  end if;

  -- One scan for both counts, so they judge the same 5,000 people.
  execute format('select count(*) filter (where %s), count(*) filter (where public.prospect_index_matches_v1(pi, '''', %L::jsonb))
                    from (select * from public.prospect_index pi where %L = any(pi.client_ids) limit 5000) pi',
    public.prospect_filter_sql_v1('', v_filters), v_filters, v_client) into v_compiled, v_matched;
  if v_compiled <> v_matched then
    raise exception 'No domain unverified proof (people): compiled %, matcher %', v_compiled, v_matched;
  end if;
  raise notice 'No domain unverified proof passed on client %.', v_client;
end;
$proof$;
