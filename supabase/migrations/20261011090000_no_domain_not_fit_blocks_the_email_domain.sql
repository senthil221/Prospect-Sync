-- A not-fit company with no website is blocklisted by its people's email
-- domain.
--
-- Asked for on 2026-10-11 ("No domain not fit - why cant we take the domain
-- from people email"). 216 companies sat in "No domain not fit" because the
-- blocklist holds domains and they had none; 183 of them have people whose work
-- emails name one business domain (154 of those domains belong to another,
-- duplicate, company record).
--
-- company_block_domain_v1 is the domain a company is blocked or unblocked by:
-- its own domain, or else the one business email domain its people share
-- (free mail never counts; two different domains are ambiguous and give none).
-- The ICP check applier now uses it, so:
--   * NON_FIT puts that domain on the client blocklist as 'ICP Invalid'. A
--     blocked domain blocks matching email domains (20261010110000), so the
--     company's people leave the client, as does any company holding the domain;
--   * FIT and the undo steps lift it the same way;
--   * not when a company that holds the domain is ICP verified for the client.
-- "No domain not fit" keeps only the companies that still have nothing to
-- block. The existing results are queued again so the applier blocks them.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

create or replace function public.company_block_domain_v1(p_company_id text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select coalesce(nullif(c.normalized_domain, ''), (
             select min(e.domain)
               from (select distinct public.email_domain_v1(p.work_email) as domain
                       from public.prospects p
                      where p.company_id = c.id and coalesce(p.work_email, '') like '%@%') e
              where e.domain <> '' and not public.is_free_email_domain_v1(e.domain)
             having count(*) = 1))
      from public.companies c
     where c.id = p_company_id), '');
$$;

revoke execute on function public.company_block_domain_v1(text) from public, anon, authenticated;
grant execute on function public.company_block_domain_v1(text) to service_role;

do $patch$
declare
  v_definition text;
  v_anchor text;
  v_new text;
  v_function regprocedure;
begin
  -- 1. The applier reads the block domain, and never blocks a domain a
  -- verified company holds.
  v_function := 'public.apply_icp_check_results_v1(integer)'::regprocedure;
  v_definition := pg_get_functiondef(v_function);
  if position('company_block_domain_v1' in v_definition) = 0 then
    v_anchor := $o$'applied_tagged', s.applied_tagged, 'domain', c.normalized_domain)$o$;
    v_new := $n$'applied_tagged', s.applied_tagged, 'domain', public.company_block_domain_v1(c.id))$n$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'apply_icp_check_results_v1: domain anchor is not unique';
    end if;
    v_definition := replace(v_definition, v_anchor, v_new);
    v_anchor := $o$       and not public.is_free_email_domain_v1(r->>'domain')$o$;
    v_new := $n$       and not public.is_free_email_domain_v1(r->>'domain')
       and not exists (select 1 from public.companies vc
                         join public.client_company_icp_validations viv
                           on viv.client_id = v_check.client_id and viv.company_id = vc.id
                        where vc.normalized_domain = r->>'domain')$n$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'apply_icp_check_results_v1: free-mail anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor, v_new);
  end if;

  -- 2. "No domain not fit": only companies with nothing to block, in the two
  -- compilers and the two row matchers.
  v_function := 'public.prospect_filter_sql_v1(text,jsonb)'::regprocedure;
  v_definition := pg_get_functiondef(v_function);
  if position('company_block_domain_v1' in v_definition) = 0 then
    v_anchor := $o$where ndc.id = pi.company_id and coalesce(ndc.normalized_domain, '') = '')$o$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1: no-domain anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor, v_anchor || $n$ and public.company_block_domain_v1(pi.company_id) = ''$n$);
  end if;

  v_function := 'public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure;
  v_definition := pg_get_functiondef(v_function);
  if position('company_block_domain_v1' in v_definition) = 0 then
    v_anchor := $o$where ndc.id = (p_row).company_id and coalesce(ndc.normalized_domain, '') = '')$o$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_index_matches_v1: no-domain anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor, v_anchor || $n$
            and public.company_block_domain_v1((p_row).company_id) = ''$n$);
  end if;

  v_function := 'public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure;
  v_definition := pg_get_functiondef(v_function);
  if position('company_block_domain_v1' in v_definition) = 0 then
    v_anchor := $o$public.company_icp_check_matches_v1(c.id, %1$L, 'NON_FIT'))$nd$, raw_values[1]);$o$;
    v_new := $n$public.company_icp_check_matches_v1(c.id, %1$L, 'NON_FIT') and public.company_block_domain_v1(c.id) = '')$nd$, raw_values[1]);$n$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_filter_sql_v3: no-domain anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor, v_new);
  end if;

  v_function := 'public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure;
  v_definition := pg_get_functiondef(v_function);
  if position('company_block_domain_v1' in v_definition) = 0 then
    v_anchor := $o$where ndv.client_id = filter_item->'values'->>0 and ndv.company_id = (p_row).id)$o$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_matches_filters_v1: no-domain anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor, v_anchor || $n$
            and public.company_block_domain_v1((p_row).id) = ''$n$);
  end if;
end;
$patch$;

-- 3. Queue the not-fit companies that had no domain and now have one to block:
-- the latest result per client and company, still NON_FIT, not verified, and
-- not blocked before (one blocked and lifted by hand stays lifted).
with wanted as (
  select distinct on (cc.client_id, cc.company_id) s.check_id, s.company_id
    from public.client_companies cc
    join public.companies c on c.id = cc.company_id
    join public.icp_strategy_checks k on k.client_id = cc.client_id
    join public.icp_strategy_results s on s.check_id = k.id and s.company_id = cc.company_id
   where coalesce(c.normalized_domain, '') = ''
     and s.verdict = 'NON_FIT'
     and not (s.applied = 'NON_FIT' and s.applied_blocked)
     and public.company_icp_check_matches_v1(cc.company_id, cc.client_id, 'NON_FIT')
     and not exists (select 1 from public.client_company_icp_validations iv
                      where iv.client_id = cc.client_id and iv.company_id = cc.company_id)
     and public.company_block_domain_v1(cc.company_id) <> ''
   order by cc.client_id, cc.company_id, s.decided_at desc nulls last
),
queued as (
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

-- Proof, read-only: the compiled filter and the row matcher agree on the
-- client with the most domain-less NON_FIT companies, and none they keep has a
-- domain to block.
do $proof$
declare
  v_client text;
  v_filters jsonb;
  v_compiled bigint;
  v_matched bigint;
  v_wrong bigint;
begin
  if public.company_block_domain_v1('no such company') <> '' then
    raise exception 'No domain proof: a missing company has a block domain';
  end if;
  select cc.client_id into v_client
    from public.client_companies cc
    join public.companies c on c.id = cc.company_id
   where coalesce(c.normalized_domain, '') = ''
     and public.company_icp_check_matches_v1(cc.company_id, cc.client_id, 'NON_FIT')
   group by cc.client_id order by count(*) desc limit 1;
  v_filters := jsonb_build_array(jsonb_build_object('field', '__icp_no_domain_unverified', 'operator', 'equals', 'values', jsonb_build_array(coalesce(v_client, 'none'))));
  if public.prospect_filter_sql_v1('', v_filters) not like '%company_block_domain_v1%'
     or public.company_filter_sql_v3('', v_filters, false) not like '%company_block_domain_v1%' then
    raise exception 'No domain proof: a compiler did not learn the block domain';
  end if;
  if v_client is null then
    raise notice 'No domain proof: nothing domain-less and NON_FIT - compile checks only.';
    return;
  end if;

  execute format('select count(*) from public.companies c join public.client_companies cc on cc.company_id = c.id and cc.client_id = %L where %s',
    v_client, public.company_filter_sql_v3('', v_filters, false)) into v_compiled;
  select count(*), count(*) filter (where public.company_block_domain_v1(c.id) <> '') into v_matched, v_wrong
    from public.companies c
    join public.client_companies cc on cc.company_id = c.id and cc.client_id = v_client
   where public.company_matches_filters_v1(c, '', v_filters);
  if v_compiled <> v_matched or v_wrong <> 0 then
    raise exception 'No domain proof (companies): compiled %, matcher %, with a block domain %', v_compiled, v_matched, v_wrong;
  end if;

  execute format('select count(*) filter (where %s), count(*) filter (where public.prospect_index_matches_v1(pi, '''', %L::jsonb))
                    from (select * from public.prospect_index pi where %L = any(pi.client_ids) limit 5000) pi',
    public.prospect_filter_sql_v1('', v_filters), v_filters, v_client) into v_compiled, v_matched;
  if v_compiled <> v_matched then
    raise exception 'No domain proof (people): compiled %, matcher %', v_compiled, v_matched;
  end if;
  raise notice 'No domain proof passed on client %.', v_client;
end;
$proof$;
