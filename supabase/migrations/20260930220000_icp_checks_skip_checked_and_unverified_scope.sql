-- ICP checks: "ICP unverified" companies, and skip what is already checked.
--
-- Two asks from running ICP checks inside a client (2026-09-30):
--
--   * Newly pushed companies land in the client as ICP unverified (no row in
--     client_company_icp_validations - the Company DB's ICP Verified /
--     Unverified switch). That is the set to check, so it is a scope of its own.
--   * Checking the same company again is the exception, not the rule. By
--     default a check now skips companies that already have a current ICP
--     check result for this ICP - from any of the three methods, judged
--     against the brief as it is now. "Force re-check" includes them. How many
--     were skipped is kept on the check.
--
-- start_icp_strategy_check_v2 and icp_strategy_scope_counts_v2 are new; the
-- v1 functions stay as they were for a slot still running the previous app.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

alter table public.icp_strategy_checks drop constraint if exists icp_strategy_checks_scope_check;
alter table public.icp_strategy_checks add constraint icp_strategy_checks_scope_check
  check (scope in ('all', 'unchecked', 'selection', 'unverified'));

alter table public.icp_strategy_checks
  add column if not exists forced boolean not null default false,
  add column if not exists skipped_items integer not null default 0;

-- App: start a strategy check.
--   all         the client's companies
--   unverified  those not marked ICP verified for this client
--   selection   a Company DB selection or a pasted list, resolved once
-- Companies with no text are never queued. Unless p_force, companies with a
-- current ICP check result for this ICP are skipped and counted.
create or replace function public.start_icp_strategy_check_v2(
  p_client_id text,
  p_icp_profile_id text,
  p_strategy text,
  p_scope text default 'unverified',
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_force boolean default false,
  p_provider_mode text default 'cheapest',
  p_created_by text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_profile public.client_icp_profiles%rowtype;
  v_hash text;
  v_check_id uuid := gen_random_uuid();
  v_ids text[];
  v_checkable integer;
  v_total integer;
  v_pass record;
  v_run jsonb;
  v_max constant integer := 100000;
begin
  select * into v_profile from public.client_icp_profiles
   where id = p_icp_profile_id and client_id = p_client_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;
  if btrim(v_profile.description) = '' then
    raise exception using errcode = '22023', message = 'This ICP has no brief to check companies against. Add one on the ICPs tab.';
  end if;
  if coalesce(p_strategy, '') not in ('strict', 'lenient', 'balanced') then
    raise exception using errcode = '22023', message = 'Choose Strict, Lenient or Balanced.';
  end if;
  if coalesce(p_scope, '') not in ('all', 'unverified', 'selection') then
    raise exception using errcode = '22023', message = 'Unknown scope.';
  end if;
  if coalesce(p_provider_mode, '') not in ('default', 'cheapest') then
    raise exception using errcode = '22023', message = 'Unknown provider mode.';
  end if;
  v_hash := md5(v_profile.description);

  if p_scope = 'selection' then
    select coalesce(array_agg(company_id), array[]::text[]) into v_ids
      from public.resolve_company_action_selection_v1(
        p_client_id, p_company_ids, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb),
        p_people_scope, p_excluded_ids, v_max * 2 + 1);
  else
    select coalesce(array_agg(cc.company_id order by cc.company_id), array[]::text[]) into v_ids
      from public.client_companies cc
     where cc.client_id = p_client_id
       and (p_scope = 'all' or not exists (
             select 1 from public.client_company_icp_validations iv
              where iv.client_id = p_client_id and iv.company_id = cc.company_id));
  end if;

  insert into public.icp_strategy_checks (id, client_id, icp_profile_id, icp_name, icp_hash, strategy, scope, provider_mode,
                                          forced, created_by)
  values (v_check_id, p_client_id, p_icp_profile_id, v_profile.name, v_hash, p_strategy, p_scope, p_provider_mode,
          coalesce(p_force, false), coalesce(p_created_by, ''));

  -- Checkable companies (with text), then drop the already-checked ones.
  with checkable as (
    select ids.company_id, min(ids.ord) as ord
      from unnest(v_ids) with ordinality as ids(company_id, ord)
      join public.companies c on c.id = ids.company_id
     where public.company_has_icp_text_v1(c.keywords, c.short_description)
     group by ids.company_id
  ),
  counted as (
    select count(*) as n from checkable
  ),
  kept as (
    insert into public.icp_strategy_results (check_id, company_id, position)
    select v_check_id, k.company_id, row_number() over (order by k.ord)
      from checkable k
     where coalesce(p_force, false) or not exists (
             select 1 from public.client_company_icp_verdicts v
              where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
                and v.company_id = k.company_id and v.source like 'strategy:%' and v.icp_hash = v_hash)
     order by k.ord
     limit v_max
    returning 1
  )
  select (select n from counted), (select count(*) from kept) into v_checkable, v_total;

  if v_total = 0 then
    raise exception using errcode = 'P0002', message = case
      when v_checkable > 0 then 'All ' || v_checkable || ' of these companies already have an ICP check result for this ICP. Turn on "Force re-check" to run them again.'
      when cardinality(v_ids) > 0 then 'None of these companies has a description or keywords to check.'
      else 'There are no companies to check.' end;
  end if;
  update public.icp_strategy_checks
     set total_items = v_total, skipped_items = greatest(0, v_checkable - v_total)
   where id = v_check_id;

  select coalesce(array_agg(company_id order by position), array[]::text[]) into v_ids
    from public.icp_strategy_results where check_id = v_check_id;

  for v_pass in select * from public.icp_strategy_passes_v1(p_strategy) loop
    v_run := public.enqueue_icp_validation_run_v1(
      p_client_id, p_icp_profile_id, v_pass.model, v_pass.reasoning_effort, 'selection',
      v_total::text, v_ids, false, v_check_id, p_created_by);
    update public.icp_validation_runs
       set strategy_check_id = v_check_id, pass_no = v_pass.pass_no, provider_mode = p_provider_mode
     where id = (v_run->>'id')::uuid;
  end loop;

  return (select to_jsonb(c) from public.icp_strategy_checks c where c.id = v_check_id);
end;
$$;

revoke execute on function public.start_icp_strategy_check_v2(text, text, text, text, text[], text, jsonb, jsonb, text[], boolean, text, text) from public, anon, authenticated;
grant execute on function public.start_icp_strategy_check_v2(text, text, text, text, text[], text, jsonb, jsonb, text[], boolean, text, text) to service_role;

-- App: how many checkable companies each scope holds, and how many of those
-- have no current ICP check result yet (what a check skips by default).
create or replace function public.icp_strategy_scope_counts_v2(p_client_id text, p_icp_profile_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_hash text;
begin
  select md5(description) into v_hash from public.client_icp_profiles
   where id = p_icp_profile_id and client_id = p_client_id;
  if v_hash is null then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;
  return (
    select jsonb_build_object(
             'all', count(*),
             'all_unchecked', count(*) filter (where not x.checked),
             'unverified', count(*) filter (where not x.verified),
             'unverified_unchecked', count(*) filter (where not x.verified and not x.checked))
      from (
        select exists (select 1 from public.client_company_icp_validations iv
                        where iv.client_id = p_client_id and iv.company_id = cc.company_id) as verified,
               exists (select 1 from public.client_company_icp_verdicts v
                        where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
                          and v.company_id = cc.company_id and v.source like 'strategy:%' and v.icp_hash = v_hash) as checked
          from public.client_companies cc
          join public.companies c on c.id = cc.company_id
         where cc.client_id = p_client_id
           and public.company_has_icp_text_v1(c.keywords, c.short_description)) x);
end;
$$;

revoke execute on function public.icp_strategy_scope_counts_v2(text, text) from public, anon, authenticated;
grant execute on function public.icp_strategy_scope_counts_v2(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: after two companies are decided, a second check skips
-- them unless forced; the counts agree; "unverified" leaves out a verified one.
do $$
declare
  v_client text;
  v_companies text[];
  v_profile text := 'icp-skip-proof-' || gen_random_uuid();
  v_check jsonb;
  v_check_id uuid;
  v_run uuid;
  v_token uuid;
  v_before jsonb;
  v_after jsonb;
  v_failed boolean := false;
begin
  select cc.client_id into v_client
    from public.client_companies cc join public.companies c on c.id = cc.company_id
   where public.company_has_icp_text_v1(c.keywords, c.short_description)
   group by cc.client_id
  having count(*) >= 3
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP skip proof skipped: no client with three checkable companies.';
    return;
  end if;

  begin
    select array_agg(company_id order by company_id) into v_companies
      from (select cc.company_id from public.client_companies cc join public.companies c on c.id = cc.company_id
             where cc.client_id = v_client and public.company_has_icp_text_v1(c.keywords, c.short_description)
             order by cc.company_id limit 3) picked;
    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');
    v_before := public.icp_strategy_scope_counts_v2(v_client, v_profile);

    -- Decide companies 1 and 2 with Lenient (one FIT decides).
    v_check := public.start_icp_strategy_check_v2(v_client, v_profile, 'lenient', 'selection', v_companies[1:2],
      '', '[]'::jsonb, null, null, false, 'cheapest', 'proof');
    v_check_id := (v_check->>'id')::uuid;
    select id into v_run from public.icp_validation_runs where strategy_check_id = v_check_id and pass_no = 1;
    v_token := gen_random_uuid();
    update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
    perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
      jsonb_build_object('company_id', v_companies[1], 'verdict', 'FIT', 'reason', 'r'),
      jsonb_build_object('company_id', v_companies[2], 'verdict', 'FIT', 'reason', 'r')), '{}'::jsonb);

    v_after := public.icp_strategy_scope_counts_v2(v_client, v_profile);
    if (v_after->>'all_unchecked')::int <> (v_before->>'all_unchecked')::int - 2
       or (v_after->>'all')::int <> (v_before->>'all')::int then
      raise exception 'ICP skip proof: counts before % after %', v_before, v_after;
    end if;

    -- Not forced: 1 and 2 are skipped, 3 runs.
    v_check := public.start_icp_strategy_check_v2(v_client, v_profile, 'strict', 'selection', v_companies,
      '', '[]'::jsonb, null, null, false, 'cheapest', 'proof');
    if (v_check->>'total_items')::int <> 1 or (v_check->>'skipped_items')::int <> 2 then
      raise exception 'ICP skip proof: unforced check answered %', v_check;
    end if;
    -- Forced: all three.
    v_check := public.start_icp_strategy_check_v2(v_client, v_profile, 'strict', 'selection', v_companies,
      '', '[]'::jsonb, null, null, true, 'cheapest', 'proof');
    if (v_check->>'total_items')::int <> 3 or (v_check->>'skipped_items')::int <> 0 or not (v_check->>'forced')::boolean then
      raise exception 'ICP skip proof: forced check answered %', v_check;
    end if;
    -- Nothing left unchecked among 1 and 2 -> a clear message.
    begin
      perform public.start_icp_strategy_check_v2(v_client, v_profile, 'balanced', 'selection', v_companies[1:2],
        '', '[]'::jsonb, null, null, false, 'cheapest', 'proof');
      v_failed := false;
    exception when others then
      v_failed := sqlerrm like 'All 2 of these companies already have an ICP check result%';
    end;
    if not v_failed then
      raise exception 'ICP skip proof: an all-checked selection did not say so';
    end if;

    if (v_after->>'unverified')::int > (v_after->>'all')::int
       or (v_after->>'unverified_unchecked')::int > (v_after->>'unverified')::int then
      raise exception 'ICP skip proof: unverified counts are inconsistent: %', v_after;
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP skip proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
