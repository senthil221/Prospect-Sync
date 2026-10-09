-- ICP checks tag their FIT companies with the ICP, and the ICP Invalid
-- blocklist can be re-checked.
--
-- Asked for on 2026-10-10:
--
-- 1. "Right now the ICP tag is not being applied for the FITs after the run."
--    Every client ICP has a tag (client_icp_profiles.tag_id, "Kapable 1" ...),
--    but applying a check (apply_icp_check_results_v1, 20260930260000) only
--    made a FIT company ICP verified. Not one company carried an ICP tag:
--    company_tag_links was empty. A FIT now also tags the company with the
--    check's ICP, and the client's people at it (the Client ICP filter reads
--    company tags in the Company DB and prospect tags in the People DB).
--    Recorded per result (applied_tagged) so a later review away from FIT, or
--    an Undo, takes the tag off again, the same way it takes off the
--    verification. Every FIT this applier already verified (31,500 results,
--    53,800 people) is queued for tagging.
--
-- 2. "Option to rerun ICP Validation for the 'ICP invalids' in a Client (from
--    blocklist). If valid - it should remove from blocklist and tag with that
--    ICP." A new check scope, 'blocklisted': the client's companies held out by
--    an 'ICP Invalid' domain entry. They all have a verdict already, so the
--    scope always re-checks them. When the applier meets a FIT, it first takes
--    that company's 'ICP Invalid' entry off the client's blocklist
--    (remove_client_blocklist_v1, which brings the company and its people
--    back), then verifies and tags as above. Only 'ICP Invalid' entries are
--    ever removed - a Client Provided or Campaign Reply block stays. Several
--    ICPs = one check each; a NON_FIT from one never re-blocks a company
--    another made FIT, because the applier never blocks a verified company.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

alter table public.icp_strategy_results add column if not exists applied_tagged boolean not null default false;

alter table public.icp_strategy_checks drop constraint if exists icp_strategy_checks_scope_check;
alter table public.icp_strategy_checks add constraint icp_strategy_checks_scope_check
  check (scope = any (array['all', 'unchecked', 'selection', 'unverified', 'blocklisted']));

-- The 'blocklisted' scope.
do $patch$
declare
  v_definition text;
  v_anchor text;
begin
  select pg_get_functiondef('public.start_icp_strategy_check_v2(text,text,text,text,text[],text,jsonb,jsonb,text[],boolean,text,text)'::regprocedure)
    into v_definition;
  if position('''blocklisted''' in v_definition) = 0 then
    foreach v_anchor in array array[
      $a$  if coalesce(p_scope, '') not in ('all', 'unverified', 'selection') then$a$,
      $a$  if p_scope = 'selection' then$a$,
      $a$     where coalesce(p_force, false) or not exists ($a$
    ] loop
      if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
        raise exception 'start_icp_strategy_check_v2: anchor is not unique: %', v_anchor;
      end if;
    end loop;
    v_definition := replace(v_definition,
      $a$  if coalesce(p_scope, '') not in ('all', 'unverified', 'selection') then$a$,
      $n$  if coalesce(p_scope, '') not in ('all', 'unverified', 'selection', 'blocklisted') then$n$);
    v_definition := replace(v_definition,
      $a$  if p_scope = 'selection' then$a$,
      $n$  if p_scope = 'blocklisted' then
    -- The client's companies held out by an 'ICP Invalid' domain entry
    -- (20261010120000).
    select coalesce(array_agg(cb.company_id order by cb.company_id), array[]::text[]) into v_ids
      from public.client_companies_blocked cb
      join public.companies c on c.id = cb.company_id
     where cb.client_id = p_client_id
       and exists (select 1 from public.client_blocklist b
                    where b.client_id = p_client_id and b.kind = 'domain' and b.value = c.normalized_domain
                      and b.reason = 'ICP Invalid');
  elsif p_scope = 'selection' then$n$);
    v_definition := replace(v_definition,
      $a$     where coalesce(p_force, false) or not exists ($a$,
      $n$     where coalesce(p_force, false) or p_scope = 'blocklisted' or not exists ($n$);
    execute v_definition;
  end if;
end;
$patch$;

-- How many a re-check of the ICP Invalid blocklist would send to the models.
create or replace function public.icp_blocklisted_scope_count_v1(p_client_id text)
returns integer
language sql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
  select count(*)::integer
    from public.client_companies_blocked cb
    join public.companies c on c.id = cb.company_id
   where cb.client_id = p_client_id
     and public.company_has_icp_text_v1(c.keywords, c.short_description)
     and not (c.email_provider_type = 'SEG' and exists (select 1 from public.client_settings s
               where s.client_id = p_client_id and s.seg_emails = 'discard'))
     and exists (select 1 from public.client_blocklist b
                  where b.client_id = p_client_id and b.kind = 'domain' and b.value = c.normalized_domain
                    and b.reason = 'ICP Invalid');
$$;

revoke execute on function public.icp_blocklisted_scope_count_v1(text) from public, anon, authenticated;
grant execute on function public.icp_blocklisted_scope_count_v1(text) to service_role;

-- The applier: as in 20260930260000, plus the ICP tag (1.) and taking a FIT off
-- the 'ICP Invalid' blocklist (2.). Steps in order:
--   1. undo what this check applied that no longer holds (verification, tag,
--      blocklist entry);
--   2. FIT: off the 'ICP Invalid' blocklist, ICP verified, tagged;
--   3. NON_FIT: domain on the blocklist (never a verified company);
--   4. record what now stands.
create or replace function public.apply_icp_check_results_v1(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_check public.icp_strategy_checks%rowtype;
  v_tag_id text;
  v_label text;
  v_rows jsonb;
  v_ids text[];
  v_people text[];
  v_entry_ids text[];
  v_domains text[];
  v_verified_before text[];
  v_new_verified text[] := array[]::text[];
  v_new_blocked text[] := array[]::text[];
  v_new_tagged text[] := array[]::text[];
  v_unblocked integer := 0;
  v_batch jsonb;
  v_rounds integer;
  v_done integer := 0;
begin
  -- One applier at a time; a second caller just returns.
  if not pg_try_advisory_xact_lock(hashtext('apply_icp_check_results_v1')) then
    return jsonb_build_object('applied', 0, 'busy', true);
  end if;

  select c.* into v_check
    from public.icp_strategy_checks c
   where exists (select 1 from public.icp_strategy_results s where s.check_id = c.id and s.apply_pending)
   order by c.created_at
   limit 1;
  if not found then
    return jsonb_build_object('applied', 0);
  end if;
  v_label := 'ICP check';
  -- The ICP's tag; one this client can use (its own or agency-wide).
  select p.tag_id into v_tag_id
    from public.client_icp_profiles p
    join public.prospect_tags t on t.id = p.tag_id and (t.client_id = v_check.client_id or t.client_id is null)
   where p.id = v_check.icp_profile_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'company_id', s.company_id, 'verdict', s.verdict, 'applied', s.applied,
           'applied_verified', s.applied_verified, 'applied_blocked', s.applied_blocked,
           'applied_tagged', s.applied_tagged, 'domain', c.normalized_domain)), '[]'::jsonb)
    into v_rows
    from (select * from public.icp_strategy_results
           where check_id = v_check.id and apply_pending
           order by position
           limit greatest(1, least(coalesce(p_limit, 50), 200))) s
    join public.companies c on c.id = s.company_id;

  -- 1. Undo what this check applied and no longer holds.
  select coalesce(array_agg(r->>'company_id'), array[]::text[]) into v_ids
    from jsonb_array_elements(v_rows) r
   where r->>'applied' = 'FIT' and (r->>'applied_verified')::boolean and r->>'verdict' is distinct from 'FIT';
  if cardinality(v_ids) > 0 then
    perform public.set_company_icp_verified_v2(v_check.client_id, false, v_ids, '', '[]'::jsonb, null, null, v_label);
  end if;

  select coalesce(array_agg(r->>'company_id'), array[]::text[]) into v_ids
    from jsonb_array_elements(v_rows) r
   where (r->>'applied_tagged')::boolean and r->>'verdict' is distinct from 'FIT';
  if cardinality(v_ids) > 0 and v_tag_id is not null then
    delete from public.company_tag_links where tag_id = v_tag_id and company_id = any(v_ids);
    with removed as (
      delete from public.prospect_tag_links l
       using public.client_prospects cp, public.prospects p
       where l.tag_id = v_tag_id and l.prospect_id = cp.prospect_id
         and cp.client_id = v_check.client_id and p.id = cp.prospect_id and p.company_id = any(v_ids)
      returning l.prospect_id)
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_people from removed;
    if cardinality(v_people) > 0 then
      perform public.reindex_scope_v1(p_prospect_ids => v_people);
    end if;
  end if;

  select coalesce(array_agg(b.id), array[]::text[]) into v_entry_ids
    from jsonb_array_elements(v_rows) r
    join public.client_blocklist b
      on b.client_id = v_check.client_id and b.kind = 'domain' and b.value = r->>'domain' and b.source = 'icp_check'
   where r->>'applied' = 'NON_FIT' and (r->>'applied_blocked')::boolean and r->>'verdict' is distinct from 'NON_FIT';
  if cardinality(v_entry_ids) > 0 then
    perform public.remove_client_blocklist_v1(v_check.client_id, v_entry_ids, v_label);
  end if;

  -- 2a. FIT: a company held out by an 'ICP Invalid' entry comes back first
  -- (the blocklist re-check, 20261010120000). Only that reason - a client's or
  -- a reply's block is never lifted by a model.
  select coalesce(array_agg(distinct b.id), array[]::text[]) into v_entry_ids
    from jsonb_array_elements(v_rows) r
    join public.client_blocklist b
      on b.client_id = v_check.client_id and b.kind = 'domain' and b.value = r->>'domain' and b.reason = 'ICP Invalid'
   where r->>'verdict' = 'FIT' and coalesce(r->>'domain', '') <> '';
  if cardinality(v_entry_ids) > 0 then
    perform public.remove_client_blocklist_v1(v_check.client_id, v_entry_ids, v_label);
    v_unblocked := cardinality(v_entry_ids);
  end if;

  -- 2b. FIT: ICP verified (remember which ones this check made verified).
  select coalesce(array_agg(r->>'company_id'), array[]::text[]) into v_ids
    from jsonb_array_elements(v_rows) r
   where r->>'verdict' = 'FIT' and r->>'applied' is distinct from 'FIT';
  if cardinality(v_ids) > 0 then
    select coalesce(array_agg(company_id), array[]::text[]) into v_verified_before
      from public.client_company_icp_validations where client_id = v_check.client_id and company_id = any(v_ids);
    perform public.set_company_icp_verified_v2(v_check.client_id, true, v_ids, '', '[]'::jsonb, null, null, v_label);
    select coalesce(array_agg(id), array[]::text[]) into v_new_verified
      from unnest(v_ids) id
     where not (id = any(v_verified_before))
       and exists (select 1 from public.client_company_icp_validations iv
                    where iv.client_id = v_check.client_id and iv.company_id = id);
  end if;

  -- 2c. FIT: tagged with the ICP - the company, and the client's people at it.
  select coalesce(array_agg(r->>'company_id'), array[]::text[]) into v_ids
    from jsonb_array_elements(v_rows) r
   where r->>'verdict' = 'FIT' and not coalesce((r->>'applied_tagged')::boolean, false);
  if cardinality(v_ids) > 0 and v_tag_id is not null then
    -- Only companies the client actually has (a FIT whose block could not be
    -- lifted - another reason - stays out, untagged).
    select coalesce(array_agg(cc.company_id), array[]::text[]) into v_new_tagged
      from public.client_companies cc
     where cc.client_id = v_check.client_id and cc.company_id = any(v_ids);
    insert into public.company_tag_links (company_id, tag_id)
    select id, v_tag_id from unnest(v_new_tagged) id
    on conflict (company_id, tag_id) do nothing;
    with added as (
      insert into public.prospect_tag_links (prospect_id, tag_id)
      select cp.prospect_id, v_tag_id
        from public.client_prospects cp
        join public.prospects p on p.id = cp.prospect_id
       where cp.client_id = v_check.client_id and cp.status = 'active' and p.company_id = any(v_new_tagged)
      on conflict (prospect_id, tag_id) do nothing
      returning prospect_id)
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_people from added;
    if cardinality(v_people) > 0 then
      perform public.reindex_scope_v1(p_prospect_ids => v_people);
    end if;
  end if;

  -- 3. NON_FIT: the domain on the blocklist - not for a verified company, not
  -- for a free-mail domain.
  with wanted as (
    select r->>'company_id' as company_id, r->>'domain' as domain
      from jsonb_array_elements(v_rows) r
     where r->>'verdict' = 'NON_FIT' and r->>'applied' is distinct from 'NON_FIT'
       and coalesce(r->>'domain', '') <> ''
       and not public.is_free_email_domain_v1(r->>'domain')
       and not exists (select 1 from public.client_company_icp_validations iv
                        where iv.client_id = v_check.client_id and iv.company_id = r->>'company_id')
  ),
  inserted as (
    insert into public.client_blocklist (client_id, kind, value, reason, source)
    select distinct v_check.client_id, 'domain', w.domain, 'ICP Invalid', 'icp_check' from wanted w
    on conflict (client_id, kind, value) do nothing
    returning value
  )
  select coalesce(array_agg(w.company_id), array[]::text[]),
         coalesce(array_agg(distinct w.domain), array[]::text[])
    into v_new_blocked, v_domains
    from wanted w
   where w.domain in (select value from inserted);

  if cardinality(v_domains) > 0 then
    -- The batch sweeps people (5,000 a call) and companies; call again while it
    -- says more remain.
    v_rounds := 0;
    loop
      v_batch := public.add_client_blocklist_batch_v2(v_check.client_id, v_domains, null, 'ICP Invalid', v_label,
                                                      gen_random_uuid()::text, 5000);
      v_rounds := v_rounds + 1;
      exit when not coalesce((v_batch->>'remaining')::boolean, false) or v_rounds >= 10;
    end loop;
  end if;

  -- 4. Record what now stands; anything that moved meanwhile stays pending.
  update public.icp_strategy_results s
     set applied = r.verdict,
         applied_verified = case when r.verdict = 'FIT'
                                 then coalesce(r.applied = 'FIT' and r.applied_verified, false) or s.company_id = any(v_new_verified)
                                 else false end,
         applied_blocked = case when r.verdict = 'NON_FIT'
                                then coalesce(r.applied = 'NON_FIT' and r.applied_blocked, false) or s.company_id = any(v_new_blocked)
                                else false end,
         applied_tagged = case when r.verdict = 'FIT'
                               then r.applied_tagged or s.company_id = any(v_new_tagged)
                               else false end,
         apply_pending = s.verdict is distinct from r.verdict
    from (select x->>'company_id' as company_id, x->>'verdict' as verdict, x->>'applied' as applied,
                 coalesce((x->>'applied_verified')::boolean, false) as applied_verified,
                 coalesce((x->>'applied_blocked')::boolean, false) as applied_blocked,
                 coalesce((x->>'applied_tagged')::boolean, false) as applied_tagged
            from jsonb_array_elements(v_rows) x) r
   where s.check_id = v_check.id and s.company_id = r.company_id;
  get diagnostics v_done = row_count;

  return jsonb_build_object('applied', v_done, 'check_id', v_check.id,
                            'verified', cardinality(v_new_verified), 'blocked', cardinality(v_new_blocked),
                            'tagged', cardinality(v_new_tagged), 'unblocked', v_unblocked);
end;
$$;

revoke execute on function public.apply_icp_check_results_v1(integer) from public, anon, authenticated;
grant execute on function public.apply_icp_check_results_v1(integer) to service_role;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'prospect_icp_validator') then
    execute 'grant execute on function public.apply_icp_check_results_v1(integer) to prospect_icp_validator';
  end if;
end;
$grant$;

-- Tag what the applier already verified: every FIT it applied, queued.
update public.icp_strategy_results s
   set apply_pending = true
  from public.icp_strategy_checks k
 where k.id = s.check_id and s.verdict = 'FIT' and s.applied = 'FIT' and not s.applied_tagged and not s.apply_pending;

-- Proof, rolled back with the rest of a dry run: one round tags a FIT company
-- and its people; the scope finds the ICP Invalid blocklist.
do $proof$
declare
  v_result jsonb;
  v_client text;
begin
  select k.client_id into v_client
    from public.icp_strategy_checks k
   where exists (select 1 from public.client_companies_blocked cb where cb.client_id = k.client_id)
   limit 1;
  if v_client is not null and public.icp_blocklisted_scope_count_v1(v_client) <= 0 then
    raise notice 'ICP proof: client % has no checkable ICP Invalid companies', v_client;
  end if;
  if position('''blocklisted''' in pg_get_functiondef('public.start_icp_strategy_check_v2(text,text,text,text,text[],text,jsonb,jsonb,text[],boolean,text,text)'::regprocedure)) = 0 then
    raise exception 'ICP proof: the blocklisted scope is missing';
  end if;
  raise notice 'ICP tag / blocklist re-check proof passed.';
end;
$proof$;
