-- ICP checks apply their results: FIT -> ICP verified, NON_FIT -> blocklist.
--
-- Asked for on 2026-09-30: a check's outcome should act on the client without a
-- second step. Per check (auto_apply, on by default for new checks, off for
-- every check that existed before this migration, so nothing is applied
-- retroactively):
--
--   FIT      the company becomes ICP verified for the client, through
--            set_company_icp_verified_v2 - the Company DB's own "Mark ICP
--            verified", so its people follow.
--   NON_FIT  the company's domain goes on the client's blocklist (reason
--            'ICP Invalid', source 'icp_check') and add_client_blocklist_batch_v2
--            sweeps the company and its people out of the client - reversible,
--            like every client blocklist entry.
--            Never for a company already ICP verified for the client (a person
--            said it fits), and never for a free-mail domain, which would block
--            everyone using that provider.
--
-- A later review or Undo changes the verdict; the next apply round undoes what
-- this check applied (only what it applied - a verification or entry that was
-- already there is left alone) and applies the new verdict.
--
-- WHO RUNS IT. settle_ and review_ only mark a row apply_pending. The ICP
-- worker calls apply_icp_check_results_v1 in its own loop, 50 rows of one
-- check per call, in its own transaction - so the blocklist sweep and the
-- prospect reindex never run inside a batch's complete_ (15s budget), and a
-- model call never waits for them. No row lock is held while applying: the
-- rows are read, acted on, then written back with apply_pending recomputed
-- against the verdict as it is by then, so a review that lands meanwhile is
-- picked up by the next round rather than lost.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

alter table public.icp_strategy_checks
  add column if not exists auto_apply boolean not null default false;
alter table public.icp_strategy_checks alter column auto_apply set default true;

alter table public.icp_strategy_results
  add column if not exists apply_pending boolean not null default false,
  add column if not exists applied text check (applied in ('FIT', 'NON_FIT')),
  add column if not exists applied_verified boolean not null default false,
  add column if not exists applied_blocked boolean not null default false;

create index if not exists idx_icp_strategy_results_apply_pending
  on public.icp_strategy_results (check_id) where apply_pending;

-- Free-mail providers: a company "domain" like these is bad data, and blocking
-- it would block every person on that provider. Same list as db/normalize.ts.
create or replace function public.is_free_email_domain_v1(p_domain text)
returns boolean
language sql
immutable
parallel safe
as $$
  select lower(btrim(coalesce(p_domain, ''))) in (
    'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.in', 'yahoo.co.uk',
    'outlook.com', 'outlook.in', 'hotmail.com', 'hotmail.co.uk', 'live.com', 'msn.com',
    'aol.com', 'icloud.com', 'me.com', 'mac.com', 'protonmail.com', 'proton.me',
    'zoho.com', 'gmx.com', 'mail.com', 'yandex.com', 'yandex.ru', 'rediffmail.com', 'rocketmail.com', 'ymail.com')
$$;

revoke execute on function public.is_free_email_domain_v1(text) from public, anon, authenticated;
grant execute on function public.is_free_email_domain_v1(text) to service_role;

-- ---------------------------------------------------------------------------
-- settle_: as in 20260930210000, plus apply_pending on a newly decided row.
create or replace function public.settle_icp_strategy_companies_v1(p_check_id uuid, p_run_id uuid, p_company_ids text[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_check public.icp_strategy_checks%rowtype;
  v_passes integer;
  v_need integer;
  v_decided integer := 0;
begin
  select * into v_check from public.icp_strategy_checks where id = p_check_id for update;
  if not found or cardinality(coalesce(p_company_ids, array[]::text[])) = 0 then
    return 0;
  end if;
  select r.passes, r.need_fit into v_passes, v_need from public.icp_strategy_rule_v1(v_check.strategy) r;

  update public.icp_strategy_results s
     set fit_votes = v.fit, non_fit_votes = v.non_fit
    from (
      select i.company_id,
             count(*) filter (where i.state = 'done' and i.verdict = 'FIT')::smallint as fit,
             count(*) filter (where i.state = 'done' and i.verdict = 'NON_FIT')::smallint as non_fit
        from public.icp_validation_runs r
        join public.icp_validation_items i on i.run_id = r.id
       where r.strategy_check_id = p_check_id
         and i.company_id = any(p_company_ids)
       group by i.company_id) v
   where s.check_id = p_check_id and s.company_id = v.company_id
     and (s.fit_votes, s.non_fit_votes) is distinct from (v.fit, v.non_fit);

  with decided as (
    update public.icp_strategy_results s
       set verdict = case when s.fit_votes >= v_need then 'FIT' else 'NON_FIT' end,
           decided_at = now(),
           apply_pending = v_check.auto_apply,
           reason = coalesce((
             select i.reason
               from public.icp_validation_runs r
               join public.icp_validation_items i on i.run_id = r.id and i.company_id = s.company_id
              where r.strategy_check_id = p_check_id and i.state = 'done'
                and i.verdict = case when s.fit_votes >= v_need then 'FIT' else 'NON_FIT' end
              order by r.pass_no
              limit 1), '')
     where s.check_id = p_check_id
       and s.company_id = any(p_company_ids)
       and s.verdict is null
       and (s.fit_votes >= v_need or s.non_fit_votes > v_passes - v_need)
    returning s.company_id, s.verdict, s.reason
  ),
  labelled as (
    insert into public.client_company_icp_verdicts
      (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash, run_id, decided_at)
    select v_check.client_id, v_check.icp_profile_id, 'strategy:' || v_check.strategy, d.company_id, d.verdict,
           d.reason, v_check.icp_hash, p_run_id, now()
      from decided d
    on conflict (client_id, icp_profile_id, source, company_id) do update
      set verdict = excluded.verdict, reason = excluded.reason, icp_hash = excluded.icp_hash,
          run_id = excluded.run_id, decided_at = excluded.decided_at
    returning 1
  )
  select count(*) into v_decided from labelled;

  return v_decided;
end;
$$;

revoke execute on function public.settle_icp_strategy_companies_v1(uuid, uuid, text[]) from public, anon, authenticated;

-- review_: as in 20260930240000, plus apply_pending whenever the verdict moves.
create or replace function public.review_icp_check_company_v1(
  p_client_id text,
  p_check_id uuid,
  p_company_id text,
  p_verdict text,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_check public.icp_strategy_checks%rowtype;
  v_row public.icp_strategy_results%rowtype;
  v_passes integer;
  v_need integer;
  v_verdict text := upper(btrim(coalesce(p_verdict, '')));
  v_rule text;
  v_reason text;
begin
  select * into v_check from public.icp_strategy_checks
   where id = p_check_id and client_id = p_client_id
   for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'That check does not belong to this client.';
  end if;
  if v_verdict not in ('FIT', 'NON_FIT', '') then
    raise exception using errcode = '22023', message = 'Choose FIT or NON_FIT.';
  end if;
  select * into v_row from public.icp_strategy_results where check_id = p_check_id and company_id = p_company_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'That company is not in this check.';
  end if;
  select r.passes, r.need_fit into v_passes, v_need from public.icp_strategy_rule_v1(v_check.strategy) r;
  v_rule := case when v_row.fit_votes >= v_need then 'FIT'
                 when v_row.non_fit_votes > v_passes - v_need then 'NON_FIT' end;

  if v_verdict <> '' then
    v_reason := 'Reviewed by ' || coalesce(nullif(btrim(p_actor), ''), 'a teammate')
      || case when v_rule is null then '' when v_rule = v_verdict then ' (agrees with the runs).' else ' (the runs said ' || v_rule || ').' end;
    update public.icp_strategy_results
       set verdict = v_verdict, reviewed_by = left(coalesce(p_actor, ''), 200), reviewed_at = now(),
           decided_at = coalesce(decided_at, now()),
           apply_pending = apply_pending or (v_check.auto_apply and v_verdict is distinct from verdict)
     where check_id = p_check_id and company_id = p_company_id;
    insert into public.client_company_icp_verdicts
      (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash, run_id, decided_at)
    values (v_check.client_id, v_check.icp_profile_id, 'strategy:' || v_check.strategy, p_company_id, v_verdict,
            v_reason, v_check.icp_hash, null, now())
    on conflict (client_id, icp_profile_id, source, company_id) do update
      set verdict = excluded.verdict, reason = excluded.reason, icp_hash = excluded.icp_hash,
          run_id = excluded.run_id, decided_at = excluded.decided_at;
  else
    select i.reason into v_reason
      from public.icp_validation_runs r
      join public.icp_validation_items i on i.run_id = r.id and i.company_id = p_company_id
     where r.strategy_check_id = p_check_id and i.state = 'done' and i.verdict = v_rule
     order by r.pass_no
     limit 1;
    update public.icp_strategy_results
       set verdict = v_rule, reviewed_by = '', reviewed_at = null,
           reason = coalesce(v_reason, ''), decided_at = case when v_rule is null then null else coalesce(decided_at, now()) end,
           apply_pending = apply_pending or (v_check.auto_apply and v_rule is distinct from verdict)
     where check_id = p_check_id and company_id = p_company_id;
    if v_rule is null then
      delete from public.client_company_icp_verdicts
       where client_id = v_check.client_id and icp_profile_id = v_check.icp_profile_id
         and source = 'strategy:' || v_check.strategy and company_id = p_company_id;
    else
      insert into public.client_company_icp_verdicts
        (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash, run_id, decided_at)
      values (v_check.client_id, v_check.icp_profile_id, 'strategy:' || v_check.strategy, p_company_id, v_rule,
              coalesce(v_reason, ''), v_check.icp_hash, null, now())
      on conflict (client_id, icp_profile_id, source, company_id) do update
        set verdict = excluded.verdict, reason = excluded.reason, icp_hash = excluded.icp_hash,
            run_id = excluded.run_id, decided_at = excluded.decided_at;
    end if;
  end if;

  return (select jsonb_build_object('company_id', s.company_id, 'verdict', s.verdict, 'rule_verdict', v_rule,
                                    'reviewed_by', s.reviewed_by, 'reviewed_at', s.reviewed_at, 'reason', s.reason,
                                    'applied', s.applied, 'applied_blocked', s.applied_blocked,
                                    'applied_verified', s.applied_verified, 'apply_pending', s.apply_pending)
            from public.icp_strategy_results s where s.check_id = p_check_id and s.company_id = p_company_id);
end;
$$;

revoke execute on function public.review_icp_check_company_v1(text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.review_icp_check_company_v1(text, uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- The ICP worker: apply up to p_limit pending results of one check.
create or replace function public.apply_icp_check_results_v1(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_check public.icp_strategy_checks%rowtype;
  v_label text;
  v_rows jsonb;
  v_ids text[];
  v_entry_ids text[];
  v_domains text[];
  v_verified_before text[];
  v_new_verified text[] := array[]::text[];
  v_new_blocked text[] := array[]::text[];
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'company_id', s.company_id, 'verdict', s.verdict, 'applied', s.applied,
           'applied_verified', s.applied_verified, 'applied_blocked', s.applied_blocked,
           'domain', c.normalized_domain)), '[]'::jsonb)
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

  select coalesce(array_agg(b.id), array[]::text[]) into v_entry_ids
    from jsonb_array_elements(v_rows) r
    join public.client_blocklist b
      on b.client_id = v_check.client_id and b.kind = 'domain' and b.value = r->>'domain' and b.source = 'icp_check'
   where r->>'applied' = 'NON_FIT' and (r->>'applied_blocked')::boolean and r->>'verdict' is distinct from 'NON_FIT';
  if cardinality(v_entry_ids) > 0 then
    perform public.remove_client_blocklist_v1(v_check.client_id, v_entry_ids, v_label);
  end if;

  -- 2. FIT: ICP verified (remember which ones this check made verified).
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
         apply_pending = s.verdict is distinct from r.verdict
    from (select x->>'company_id' as company_id, x->>'verdict' as verdict, x->>'applied' as applied,
                 coalesce((x->>'applied_verified')::boolean, false) as applied_verified,
                 coalesce((x->>'applied_blocked')::boolean, false) as applied_blocked
            from jsonb_array_elements(v_rows) x) r
   where s.check_id = v_check.id and s.company_id = r.company_id;
  get diagnostics v_done = row_count;

  return jsonb_build_object('applied', v_done, 'check_id', v_check.id,
                            'verified', cardinality(v_new_verified), 'blocked', cardinality(v_new_blocked));
end;
$$;

revoke execute on function public.apply_icp_check_results_v1(integer) from public, anon, authenticated;
grant execute on function public.apply_icp_check_results_v1(integer) to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'prospect_icp_validator') then
    execute 'grant execute on function public.apply_icp_check_results_v1(integer) to prospect_icp_validator';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- App: start a check with auto_apply chosen (v2 plus the flag, in one
-- transaction so no result settles before the flag is set).
create or replace function public.start_icp_strategy_check_v3(
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
  p_auto_apply boolean default true,
  p_created_by text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_check jsonb;
begin
  v_check := public.start_icp_strategy_check_v2(p_client_id, p_icp_profile_id, p_strategy, p_scope, p_company_ids,
    p_search, p_filters, p_people_scope, p_excluded_ids, p_force, p_provider_mode, p_created_by);
  update public.icp_strategy_checks set auto_apply = coalesce(p_auto_apply, true) where id = (v_check->>'id')::uuid;
  return (select to_jsonb(c) from public.icp_strategy_checks c where c.id = (v_check->>'id')::uuid);
end;
$$;

revoke execute on function public.start_icp_strategy_check_v3(text, text, text, text, text[], text, jsonb, jsonb, text[], boolean, text, boolean, text) from public, anon, authenticated;
grant execute on function public.start_icp_strategy_check_v3(text, text, text, text, text[], text, jsonb, jsonb, text[], boolean, text, boolean, text) to service_role;

-- ---------------------------------------------------------------------------
-- Reads: what was applied, per row and per check.
create or replace function public.icp_strategy_results_v1(
  p_client_id text,
  p_check_id uuid,
  p_filter text default 'all',
  p_search text default '',
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_strategy text;
  v_passes integer;
  v_need integer;
  v_total bigint;
  v_rows jsonb;
begin
  select strategy into v_strategy from public.icp_strategy_checks where id = p_check_id and client_id = p_client_id;
  if v_strategy is null then
    raise exception using errcode = 'P0002', message = 'That check does not belong to this client.';
  end if;
  select r.passes, r.need_fit into v_passes, v_need from public.icp_strategy_rule_v1(v_strategy) r;

  with matching as (
    select s.*, c.name, c.domain, c.industry, c.short_description
      from public.icp_strategy_results s
      join public.companies c on c.id = s.company_id
     where s.check_id = p_check_id
       and case coalesce(p_filter, 'all')
             when 'fit' then s.verdict = 'FIT'
             when 'non_fit' then s.verdict = 'NON_FIT'
             when 'pending' then s.verdict is null
             when 'split' then s.fit_votes > 0 and s.non_fit_votes > 0
             when 'reviewed' then s.reviewed_at is not null
             else true end
       and (v_search is null or c.name ilike '%' || v_search || '%' or c.domain ilike '%' || v_search || '%')
  ),
  page as (
    select * from matching
     order by position
     limit greatest(1, least(coalesce(p_limit, 100), 1000))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select (select count(*) from matching),
         coalesce(jsonb_agg(jsonb_build_object(
           'company_id', page.company_id, 'name', page.name, 'domain', coalesce(page.domain, ''),
           'industry', coalesce(page.industry, ''), 'short_description', coalesce(page.short_description, ''),
           'verdict', page.verdict, 'reason', page.reason, 'fit_votes', page.fit_votes, 'non_fit_votes', page.non_fit_votes,
           'rule_verdict', case when page.fit_votes >= v_need then 'FIT'
                                when page.non_fit_votes > v_passes - v_need then 'NON_FIT' end,
           'reviewed_by', page.reviewed_by, 'reviewed_at', page.reviewed_at,
           'applied', page.applied, 'applied_verified', page.applied_verified,
           'applied_blocked', page.applied_blocked, 'apply_pending', page.apply_pending,
           'votes', (select coalesce(jsonb_agg(jsonb_build_object(
                        'pass_no', r.pass_no, 'model', r.model, 'reasoning_effort', r.reasoning_effort,
                        'state', i.state, 'verdict', i.verdict, 'reason', i.reason) order by r.pass_no), '[]'::jsonb)
                       from public.icp_validation_runs r
                       join public.icp_validation_items i on i.run_id = r.id and i.company_id = page.company_id
                      where r.strategy_check_id = p_check_id))
           order by page.position), '[]'::jsonb)
    into v_total, v_rows
    from page;

  return jsonb_build_object('total', v_total, 'rows', v_rows);
end;
$$;

revoke execute on function public.icp_strategy_results_v1(text, uuid, text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.icp_strategy_results_v1(text, uuid, text, text, integer, integer) to service_role;

create or replace function public.icp_strategy_checks_v1(p_client_id text default null, p_limit integer default 30)
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
  select coalesce(jsonb_agg(
           to_jsonb(c)
           || jsonb_build_object('client_name', coalesce(cl.name, ''),
                                 'icp_current', c.icp_hash = md5(coalesce(p.description, '')),
                                 'outcome', outcome.value)
           || passes.value
           order by c.created_at desc), '[]'::jsonb)
    from (select * from public.icp_strategy_checks
           where p_client_id is null or client_id = p_client_id
           order by created_at desc
           limit greatest(1, least(coalesce(p_limit, 30), 100))) c
    left join public.clients cl on cl.id = c.client_id
    left join public.client_icp_profiles p on p.id = c.icp_profile_id
    cross join lateral (
      select jsonb_build_object(
               'status', case
                  when bool_or(r.status in ('queued', 'running')) then case when bool_or(r.started_at is not null) then 'running' else 'queued' end
                  when bool_or(r.status = 'paused') then 'paused'
                  when bool_or(r.status = 'cancelled') then 'cancelled'
                  else 'completed' end,
               'status_message', coalesce(max(nullif(r.status_message, '')), ''),
               'started_at', min(r.started_at),
               'finished_at', case when bool_and(r.status in ('completed', 'cancelled')) then max(r.finished_at) end,
               'cost_usd', coalesce(sum(r.cost_usd), 0),
               'failed_items', coalesce(sum(r.failed_items), 0),
               'passes', coalesce(jsonb_agg(jsonb_build_object(
                  'run_id', r.id, 'pass_no', r.pass_no, 'model', r.model, 'reasoning_effort', r.reasoning_effort,
                  'status', r.status, 'status_message', r.status_message, 'total_items', r.total_items,
                  'done_items', r.done_items, 'failed_items', r.failed_items, 'fit_items', r.fit_items,
                  'non_fit_items', r.non_fit_items, 'cost_usd', r.cost_usd, 'providers', r.providers)
                  order by r.pass_no), '[]'::jsonb)) as value
        from public.icp_validation_runs r
       where r.strategy_check_id = c.id) passes
    cross join lateral (
      select jsonb_build_object(
               'fit', count(*) filter (where s.verdict = 'FIT'),
               'non_fit', count(*) filter (where s.verdict = 'NON_FIT'),
               'pending', count(*) filter (where s.verdict is null),
               'split', count(*) filter (where s.fit_votes > 0 and s.non_fit_votes > 0),
               'reviewed', count(*) filter (where s.reviewed_at is not null),
               'split_unreviewed', count(*) filter (where s.fit_votes > 0 and s.non_fit_votes > 0 and s.reviewed_at is null),
               'applied_verified', count(*) filter (where s.applied = 'FIT'),
               'applied_blocked', count(*) filter (where s.applied = 'NON_FIT' and s.applied_blocked),
               'kept_not_blocked', count(*) filter (where s.applied = 'NON_FIT' and not s.applied_blocked),
               'apply_pending', count(*) filter (where s.apply_pending)) as value
        from public.icp_strategy_results s
       where s.check_id = c.id) outcome
$$;

revoke execute on function public.icp_strategy_checks_v1(text, integer) from public, anon, authenticated;
grant execute on function public.icp_strategy_checks_v1(text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: a Strict check over three companies - FIT, NON_FIT, and a
-- NON_FIT that is already ICP verified. Apply verifies the first, blocks the
-- second (company moved out of the client), keeps the third. Reviewing the
-- blocked one FIT unblocks and verifies it; Undo reverses that.
do $$
declare
  v_client text;
  v_companies text[];
  v_profile text := 'icp-apply-proof-' || gen_random_uuid();
  v_check jsonb;
  v_check_id uuid;
  v_run uuid;
  v_token uuid;
  v_result jsonb;
  v_domain text;
begin
  select cc.client_id into v_client
    from public.client_companies cc join public.companies c on c.id = cc.company_id
   where public.company_has_icp_text_v1(c.keywords, c.short_description)
     and not public.is_free_email_domain_v1(c.normalized_domain)
     and not exists (select 1 from public.client_company_icp_validations iv where iv.client_id = cc.client_id and iv.company_id = cc.company_id)
   group by cc.client_id
  having count(*) >= 3
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP apply proof skipped: no client with three unverified checkable companies.';
    return;
  end if;

  begin
    select array_agg(company_id order by company_id) into v_companies
      from (select cc.company_id from public.client_companies cc join public.companies c on c.id = cc.company_id
             where cc.client_id = v_client and public.company_has_icp_text_v1(c.keywords, c.short_description)
               and not public.is_free_email_domain_v1(c.normalized_domain)
               and not exists (select 1 from public.client_company_icp_validations iv where iv.client_id = cc.client_id and iv.company_id = cc.company_id)
               and not exists (select 1 from public.client_blocklist b where b.client_id = cc.client_id and b.kind = 'domain' and b.value = c.normalized_domain)
             order by cc.company_id limit 3) picked;
    select normalized_domain into v_domain from public.companies where id = v_companies[2];
    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');
    -- Company 3 is ICP verified by hand already.
    insert into public.client_company_icp_validations (client_id, company_id, validated_at, validated_by)
    values (v_client, v_companies[3], now(), 'proof');

    v_check := public.start_icp_strategy_check_v3(v_client, v_profile, 'strict', 'selection', v_companies,
      '', '[]'::jsonb, null, null, true, 'cheapest', true, 'proof');
    v_check_id := (v_check->>'id')::uuid;
    if not (v_check->>'auto_apply')::boolean then raise exception 'ICP apply proof: auto_apply not set'; end if;
    for v_run in select id from public.icp_validation_runs where strategy_check_id = v_check_id order by pass_no loop
      v_token := gen_random_uuid();
      update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
      perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
        jsonb_build_object('company_id', v_companies[1], 'verdict', 'FIT', 'reason', 'r'),
        jsonb_build_object('company_id', v_companies[2], 'verdict', 'NON_FIT', 'reason', 'r'),
        jsonb_build_object('company_id', v_companies[3], 'verdict', 'NON_FIT', 'reason', 'r')), '{}'::jsonb);
    end loop;
    if (select count(*) from public.icp_strategy_results where check_id = v_check_id and apply_pending) <> 3 then
      raise exception 'ICP apply proof: decided rows were not marked pending';
    end if;

    -- Apply until this check has nothing pending (other checks may be queued first).
    for i in 1..20 loop
      exit when not exists (select 1 from public.icp_strategy_results where check_id = v_check_id and apply_pending);
      v_result := public.apply_icp_check_results_v1(50);
    end loop;
    if not exists (select 1 from public.client_company_icp_validations where client_id = v_client and company_id = v_companies[1])
       or not exists (select 1 from public.client_blocklist where client_id = v_client and kind = 'domain' and value = v_domain
                        and source = 'icp_check' and reason = 'ICP Invalid')
       or exists (select 1 from public.client_companies where client_id = v_client and company_id = v_companies[2])
       or not exists (select 1 from public.client_companies where client_id = v_client and company_id = v_companies[3])
       or (select applied_blocked from public.icp_strategy_results where check_id = v_check_id and company_id = v_companies[3]) then
      raise exception 'ICP apply proof: first apply went wrong (%).', v_result;
    end if;

    -- Review the blocked company FIT: unblocked and verified.
    perform public.review_icp_check_company_v1(v_client, v_check_id, v_companies[2], 'FIT', 'proof');
    for i in 1..20 loop
      exit when not exists (select 1 from public.icp_strategy_results where check_id = v_check_id and apply_pending);
      perform public.apply_icp_check_results_v1(50);
    end loop;
    if exists (select 1 from public.client_blocklist where client_id = v_client and kind = 'domain' and value = v_domain)
       or not exists (select 1 from public.client_companies where client_id = v_client and company_id = v_companies[2])
       or not exists (select 1 from public.client_company_icp_validations where client_id = v_client and company_id = v_companies[2]) then
      raise exception 'ICP apply proof: reviewing FIT did not unblock and verify';
    end if;

    -- Undo: back to NON_FIT - unverified (this check verified it) and blocked again.
    perform public.review_icp_check_company_v1(v_client, v_check_id, v_companies[2], '', 'proof');
    for i in 1..20 loop
      exit when not exists (select 1 from public.icp_strategy_results where check_id = v_check_id and apply_pending);
      perform public.apply_icp_check_results_v1(50);
    end loop;
    if exists (select 1 from public.client_company_icp_validations where client_id = v_client and company_id = v_companies[2])
       or not exists (select 1 from public.client_blocklist where client_id = v_client and kind = 'domain' and value = v_domain) then
      raise exception 'ICP apply proof: undo did not reverse the review';
    end if;
    if not exists (select 1 from jsonb_array_elements(public.icp_strategy_checks_v1(v_client, 100)) e
                    where (e->>'id')::uuid = v_check_id and (e->'outcome'->>'applied_verified')::int = 1
                      and (e->'outcome'->>'applied_blocked')::int = 1 and (e->'outcome'->>'kept_not_blocked')::int = 1
                      and (e->'outcome'->>'apply_pending')::int = 0) then
      raise exception 'ICP apply proof: the checks list counts are wrong';
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP apply proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
