-- Review an ICP check's result by hand.
--
-- The companies whose runs disagreed ("Split votes", ~5%) are the uncertain
-- ones. An operator can now set any company of a check to FIT or NON_FIT; the
-- rule's answer stays visible beside it and "Undo" puts it back.
--
--   * A reviewed result is final. settle_ only ever decides rows whose verdict
--     is still null, so a later vote never overwrites a review - even one made
--     before the company's votes were in.
--   * The review becomes the company's ICP check label (source
--     'strategy:<name>'), so the Company DB column and filter and "Mark FIT as
--     ICP verified" all use it.
--   * Undo recomputes the rule's outcome from the votes (null while they are
--     not decisive) and puts the label back to match.
-- It takes the check lock like settle_ does, and locks no run, so the lock
-- order (run, then check) still holds.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

alter table public.icp_strategy_results
  add column if not exists reviewed_by text not null default '',
  add column if not exists reviewed_at timestamptz;

create index if not exists idx_icp_strategy_results_reviewed
  on public.icp_strategy_results (check_id) where reviewed_at is not null;

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
           decided_at = coalesce(decided_at, now())
     where check_id = p_check_id and company_id = p_company_id;
    insert into public.client_company_icp_verdicts
      (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash, run_id, decided_at)
    values (v_check.client_id, v_check.icp_profile_id, 'strategy:' || v_check.strategy, p_company_id, v_verdict,
            v_reason, v_check.icp_hash, null, now())
    on conflict (client_id, icp_profile_id, source, company_id) do update
      set verdict = excluded.verdict, reason = excluded.reason, icp_hash = excluded.icp_hash,
          run_id = excluded.run_id, decided_at = excluded.decided_at;
  else
    -- Undo: back to what the votes decide.
    select i.reason into v_reason
      from public.icp_validation_runs r
      join public.icp_validation_items i on i.run_id = r.id and i.company_id = p_company_id
     where r.strategy_check_id = p_check_id and i.state = 'done' and i.verdict = v_rule
     order by r.pass_no
     limit 1;
    update public.icp_strategy_results
       set verdict = v_rule, reviewed_by = '', reviewed_at = null,
           reason = coalesce(v_reason, ''), decided_at = case when v_rule is null then null else coalesce(decided_at, now()) end
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
                                    'reviewed_by', s.reviewed_by, 'reviewed_at', s.reviewed_at, 'reason', s.reason)
            from public.icp_strategy_results s where s.check_id = p_check_id and s.company_id = p_company_id);
end;
$$;

revoke execute on function public.review_icp_check_company_v1(text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.review_icp_check_company_v1(text, uuid, text, text, text) to service_role;

-- Results page: plus the rule's own answer, who reviewed, and a Reviewed filter.
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

-- Checks list: the outcome also counts reviewed companies.
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
               'split_unreviewed', count(*) filter (where s.fit_votes > 0 and s.non_fit_votes > 0 and s.reviewed_at is null)) as value
        from public.icp_strategy_results s
       where s.check_id = c.id) outcome
$$;

revoke execute on function public.icp_strategy_checks_v1(text, integer) from public, anon, authenticated;
grant execute on function public.icp_strategy_checks_v1(text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: a Balanced check where a company is split 1-1 after two
-- runs. Reviewing it NON_FIT sticks when the third run says FIT; Undo brings
-- back the rule's FIT; the label follows each step.
do $$
declare
  v_client text;
  v_companies text[];
  v_profile text := 'icp-review-proof-' || gen_random_uuid();
  v_check jsonb;
  v_check_id uuid;
  v_run uuid;
  v_token uuid;
  v_pass integer;
  v_result jsonb;
  v_label text;
begin
  select cc.client_id into v_client
    from public.client_companies cc join public.companies c on c.id = cc.company_id
   where public.company_has_icp_text_v1(c.keywords, c.short_description)
   group by cc.client_id
  having count(*) >= 2
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP review proof skipped: no client with two checkable companies.';
    return;
  end if;

  begin
    select array_agg(company_id order by company_id) into v_companies
      from (select cc.company_id from public.client_companies cc join public.companies c on c.id = cc.company_id
             where cc.client_id = v_client and public.company_has_icp_text_v1(c.keywords, c.short_description)
             order by cc.company_id limit 2) picked;
    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');
    v_check := public.start_icp_strategy_check_v2(v_client, v_profile, 'balanced', 'selection', v_companies,
      '', '[]'::jsonb, null, null, true, 'cheapest', 'proof');
    v_check_id := (v_check->>'id')::uuid;

    -- Runs 1 and 2: company 1 FIT then NON_FIT (split, undecided).
    for v_pass in 1..2 loop
      select id into v_run from public.icp_validation_runs where strategy_check_id = v_check_id and pass_no = v_pass;
      v_token := gen_random_uuid();
      update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
      perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
        jsonb_build_object('company_id', v_companies[1], 'verdict', case v_pass when 1 then 'FIT' else 'NON_FIT' end, 'reason', 'pass ' || v_pass),
        jsonb_build_object('company_id', v_companies[2], 'verdict', 'FIT', 'reason', 'r')), '{}'::jsonb);
    end loop;

    v_result := public.review_icp_check_company_v1(v_client, v_check_id, v_companies[1], 'NON_FIT', 'reviewer@example.com');
    if v_result->>'verdict' <> 'NON_FIT' or v_result->>'rule_verdict' is not null then
      raise exception 'ICP review proof: review answered %', v_result;
    end if;

    -- Run 3 says FIT: the rule would decide FIT, the review stands.
    select id into v_run from public.icp_validation_runs where strategy_check_id = v_check_id and pass_no = 3;
    v_token := gen_random_uuid();
    update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
    perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
      jsonb_build_object('company_id', v_companies[1], 'verdict', 'FIT', 'reason', 'pass 3'),
      jsonb_build_object('company_id', v_companies[2], 'verdict', 'FIT', 'reason', 'r')), '{}'::jsonb);
    select verdict into v_label from public.client_company_icp_verdicts
     where client_id = v_client and icp_profile_id = v_profile and source = 'strategy:balanced' and company_id = v_companies[1];
    if (select verdict from public.icp_strategy_results where check_id = v_check_id and company_id = v_companies[1]) <> 'NON_FIT'
       or v_label <> 'NON_FIT' then
      raise exception 'ICP review proof: a later run overwrote the review';
    end if;
    if not exists (select 1 from jsonb_array_elements(public.icp_strategy_checks_v1(v_client, 100)) e
                    where (e->>'id')::uuid = v_check_id and (e->'outcome'->>'reviewed')::int = 1
                      and (e->'outcome'->>'split_unreviewed')::int = 0) then
      raise exception 'ICP review proof: the outcome does not count the review';
    end if;
    if (public.icp_strategy_results_v1(v_client, v_check_id, 'reviewed', '', 100, 0)->>'total')::int <> 1 then
      raise exception 'ICP review proof: the Reviewed filter is wrong';
    end if;

    -- Undo: back to the rule's FIT (2 of 3), with the first FIT run's reason.
    v_result := public.review_icp_check_company_v1(v_client, v_check_id, v_companies[1], '', 'reviewer@example.com');
    select verdict into v_label from public.client_company_icp_verdicts
     where client_id = v_client and icp_profile_id = v_profile and source = 'strategy:balanced' and company_id = v_companies[1];
    if v_result->>'verdict' <> 'FIT' or v_result->>'reason' <> 'pass 1' or v_label <> 'FIT'
       or (v_result->>'reviewed_at') is not null then
      raise exception 'ICP review proof: undo answered % (label %)', v_result, v_label;
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP review proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
