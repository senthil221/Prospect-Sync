-- ICP checks by strategy: Strict, Lenient and Balanced.
--
-- The ICP Validator compares models side by side, for choosing models. For
-- production the operator picks one of three fixed strategies, each a set of
-- model passes over the same companies and a rule that turns their votes into
-- one label:
--
--   strict    DeepSeek V4.1 Flash (high) + GPT-6 Luna (low)
--             FIT only if both say FIT.
--   lenient   DeepSeek V4.1 Flash (high) twice
--             FIT if either says FIT.
--   balanced  DeepSeek V4.1 Flash (high) twice + GPT-6 Luna (low)
--             FIT if at least two of three say FIT.
--
-- Chosen on 2026-09-30 from repeated runs of the same 443 companies: two
-- identical high-effort DeepSeek passes disagree on ~5% of companies - the
-- borderline ones - which is what Lenient's union recovers.
--
-- THE SHAPE.
--   icp_strategy_checks   one "check these companies with this strategy".
--   icp_strategy_results  one row per company: the votes so far and, once the
--                         votes decide it, the final verdict.
--   icp_validation_runs   each pass is an ordinary run (strategy_check_id,
--                         pass_no), so the worker, leasing, retries, pause and
--                         cost accounting are the ones already in use.
--
-- INDEPENDENT PASSES. A pass never reuses an earlier verdict and never writes
-- the per-model label: two DeepSeek passes must be two real calls, or Lenient
-- and Balanced collapse into one run. Only the final verdict becomes a label,
-- under the source 'strategy:<name>', so the Company DB's ICP check column
-- shows it.
--
-- SETTLED AS SOON AS IT IS DECIDED. A company is decided the moment its votes
-- make the outcome certain - one NON_FIT under Strict, one FIT under Lenient,
-- two alike under Balanced - and never changes after that. The remaining
-- passes still run, so every vote is visible.
--
-- CHEAPEST PROVIDER. provider_mode 'cheapest' asks OpenRouter for the lowest-
-- priced provider that honours JSON mode and reasoning, excluding 4-bit
-- quantized hosts. DeepSeek V4.1 Flash is sold by ~30 providers at up to 15x
-- different prices. providers counts which ones actually answered.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create table if not exists public.icp_strategy_checks (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references public.clients(id) on delete cascade,
  icp_profile_id text not null references public.client_icp_profiles(id) on delete cascade,
  icp_name text not null default '',
  icp_hash text not null,
  strategy text not null check (strategy in ('strict', 'lenient', 'balanced')),
  scope text not null check (scope in ('all', 'unchecked', 'selection')),
  provider_mode text not null default 'cheapest' check (provider_mode in ('default', 'cheapest')),
  total_items integer not null default 0,
  created_by text not null default '',
  created_at timestamptz not null default now()
);

comment on table public.icp_strategy_checks is
  'One ICP check by strategy (strict, lenient, balanced): the model passes are icp_validation_runs with strategy_check_id set; the per-company outcome is in icp_strategy_results.';

create index if not exists idx_icp_strategy_checks_client
  on public.icp_strategy_checks (client_id, created_at desc);
create index if not exists idx_icp_strategy_checks_recent
  on public.icp_strategy_checks (created_at desc);

create table if not exists public.icp_strategy_results (
  check_id uuid not null references public.icp_strategy_checks(id) on delete cascade,
  company_id text not null references public.companies(id) on delete cascade,
  position integer not null,
  fit_votes smallint not null default 0,
  non_fit_votes smallint not null default 0,
  verdict text check (verdict in ('FIT', 'NON_FIT')),
  reason text not null default '',
  decided_at timestamptz,
  primary key (check_id, company_id)
);

comment on table public.icp_strategy_results is
  'Per company of an ICP strategy check: votes so far, and the final verdict once the votes decide it (null until then).';

create index if not exists idx_icp_strategy_results_position
  on public.icp_strategy_results (check_id, position);

alter table public.icp_validation_runs
  add column if not exists strategy_check_id uuid references public.icp_strategy_checks(id) on delete cascade,
  add column if not exists pass_no smallint,
  add column if not exists provider_mode text not null default 'default',
  add column if not exists providers jsonb not null default '{}'::jsonb;

alter table public.icp_validation_runs drop constraint if exists icp_validation_runs_provider_mode_check;
alter table public.icp_validation_runs add constraint icp_validation_runs_provider_mode_check
  check (provider_mode in ('default', 'cheapest'));

create index if not exists idx_icp_validation_runs_strategy
  on public.icp_validation_runs (strategy_check_id, pass_no) where strategy_check_id is not null;

do $$
declare
  v_table text;
begin
  foreach v_table in array array['icp_strategy_checks', 'icp_strategy_results'] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('revoke all on public.%I from public, anon, authenticated', v_table);
    execute format('grant select, insert, update, delete on public.%I to service_role', v_table);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- The strategies. The one place the passes and the rule are defined; the app
-- shows them from worker/icp-validator-core.mjs (ICP_STRATEGIES), which a unit
-- test keeps identical to this.
create or replace function public.icp_strategy_passes_v1(p_strategy text)
returns table (pass_no smallint, model text, reasoning_effort text)
language sql
immutable
as $$
  select p.pass_no::smallint, p.model, p.effort
    from (values
      ('strict',   1, 'deepseek/deepseek-v4.1-flash', 'high'),
      ('strict',   2, 'openai/gpt-6-luna',            'low'),
      ('lenient',  1, 'deepseek/deepseek-v4.1-flash', 'high'),
      ('lenient',  2, 'deepseek/deepseek-v4.1-flash', 'high'),
      ('balanced', 1, 'deepseek/deepseek-v4.1-flash', 'high'),
      ('balanced', 2, 'deepseek/deepseek-v4.1-flash', 'high'),
      ('balanced', 3, 'openai/gpt-6-luna',            'low')
    ) as p(strategy, pass_no, model, effort)
   where p.strategy = p_strategy
   order by p.pass_no
$$;

-- FIT needs at least need_fit FIT votes out of passes; NON_FIT is decided once
-- more than passes - need_fit passes say NON_FIT.
create or replace function public.icp_strategy_rule_v1(p_strategy text)
returns table (passes integer, need_fit integer)
language sql
immutable
as $$
  select case p_strategy when 'balanced' then 3 else 2 end,
         case p_strategy when 'strict' then 2 when 'lenient' then 1 else 2 end
$$;

revoke execute on function public.icp_strategy_passes_v1(text) from public, anon, authenticated;
grant execute on function public.icp_strategy_passes_v1(text) to service_role;
revoke execute on function public.icp_strategy_rule_v1(text) from public, anon, authenticated;
grant execute on function public.icp_strategy_rule_v1(text) to service_role;

-- ---------------------------------------------------------------------------
-- Internal: record the votes of some of a check's companies and decide the
-- ones whose outcome is now certain. Called by complete_ for every batch of a
-- strategy pass.
--
-- The check row is locked first. Two passes finishing the same companies at
-- once then take turns, and the second one - each statement below takes a
-- fresh snapshot - sees the first one's committed votes. Lock order is always
-- run (complete_ holds it) then check; nothing locks a check before its runs.
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
           -- The first pass that voted for the outcome explains it.
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

-- ---------------------------------------------------------------------------
-- Worker: save a batch's verdicts. As before, plus: a strategy pass keeps its
-- votes on its items (no per-model label) and settles its companies; and the
-- provider that answered is counted.
create or replace function public.complete_icp_validation_batch_v1(
  p_run_id uuid,
  p_token uuid,
  p_results jsonb,
  p_usage jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_run public.icp_validation_runs%rowtype;
  v_saved integer := 0;
  v_fit integer := 0;
  v_non_fit integer := 0;
  v_failed integer := 0;
  v_done_ids text[];
  v_provider text := left(btrim(coalesce(p_usage->>'provider', '')), 60);
begin
  select * into v_run from public.icp_validation_runs where id = p_run_id for update;
  if not found then
    return jsonb_build_object('saved', 0, 'failed', 0);
  end if;

  with results as (
    select distinct on (r->>'company_id')
           r->>'company_id' as company_id,
           upper(r->>'verdict') as verdict,
           left(btrim(coalesce(r->>'reason', '')), 1000) as reason
      from jsonb_array_elements(case when jsonb_typeof(p_results) = 'array' then p_results else '[]'::jsonb end) r
     where upper(r->>'verdict') in ('FIT', 'NON_FIT')
  ),
  done as (
    update public.icp_validation_items i
       set state = 'done', verdict = results.verdict, reason = results.reason,
           lease_token = null, lease_until = null, finished_at = now(), last_error = ''
      from results
     where i.run_id = p_run_id and i.company_id = results.company_id
       and i.state = 'leased' and i.lease_token = p_token
    returning i.company_id, i.verdict, i.reason
  ),
  saved as (
    insert into public.client_company_icp_verdicts
      (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash, run_id, decided_at)
    select v_run.client_id, v_run.icp_profile_id, v_run.model, done.company_id, done.verdict, done.reason,
           v_run.icp_hash, p_run_id, now()
      from done
     where v_run.strategy_check_id is null
    on conflict (client_id, icp_profile_id, source, company_id) do update
      set verdict = excluded.verdict, reason = excluded.reason, icp_hash = excluded.icp_hash,
          run_id = excluded.run_id, decided_at = excluded.decided_at
    returning 1
  )
  select count(*), count(*) filter (where verdict = 'FIT'), count(*) filter (where verdict = 'NON_FIT'),
         coalesce(array_agg(company_id), array[]::text[])
    into v_saved, v_fit, v_non_fit, v_done_ids
    from done;

  with released as (
    update public.icp_validation_items
       set state = case when attempts >= 4 then 'failed' else 'pending' end,
           lease_token = null, lease_until = null,
           last_error = 'The model did not return a verdict for this company.'
     where run_id = p_run_id and lease_token = p_token and state = 'leased'
    returning state)
  select count(*) filter (where state = 'failed') into v_failed from released;

  update public.icp_validation_runs
     set done_items = done_items + v_saved,
         fit_items = fit_items + v_fit,
         non_fit_items = non_fit_items + v_non_fit,
         failed_items = failed_items + v_failed,
         cost_usd = cost_usd + coalesce((p_usage->>'cost')::numeric, 0),
         prompt_tokens = prompt_tokens + coalesce((p_usage->>'prompt_tokens')::bigint, 0),
         cached_prompt_tokens = cached_prompt_tokens + coalesce((p_usage->>'cached_tokens')::bigint, 0),
         completion_tokens = completion_tokens + coalesce((p_usage->>'completion_tokens')::bigint, 0),
         reasoning_tokens = reasoning_tokens + coalesce((p_usage->>'reasoning_tokens')::bigint, 0),
         request_count = request_count + 1,
         request_ms = request_ms + coalesce((p_usage->>'ms')::bigint, 0),
         providers = case when v_provider = '' then providers
                          else jsonb_set(providers, array[v_provider],
                                         to_jsonb(coalesce((providers->>v_provider)::integer, 0) + 1)) end
   where id = p_run_id;

  if v_run.strategy_check_id is not null and v_saved > 0 then
    perform public.settle_icp_strategy_companies_v1(v_run.strategy_check_id, p_run_id, v_done_ids);
  end if;

  perform public.finish_icp_validation_run_if_drained_v1(p_run_id);
  return jsonb_build_object('saved', v_saved, 'failed', v_failed);
end;
$$;

revoke execute on function public.complete_icp_validation_batch_v1(uuid, uuid, jsonb, jsonb) from public, anon, authenticated;

-- Worker: lease the next batch. As before, plus the run's provider_mode.
create or replace function public.claim_icp_validation_batch_v1(p_worker text, p_lease_seconds integer default 180)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_run public.icp_validation_runs%rowtype;
  v_token uuid := gen_random_uuid();
  v_rows jsonb;
begin
  -- A worker that died mid-call leaves its lease; the rows go back in line.
  -- attempts was counted at claim, so a row that kills the worker every time
  -- still runs out of attempts.
  update public.icp_validation_items
     set state = case when attempts >= 4 then 'failed' else 'pending' end,
         lease_token = null, lease_until = null, last_error = 'The worker stopped before this row was saved.'
   where state = 'leased' and lease_until < now();

  select r.* into v_run
    from public.icp_validation_runs r
   where r.status in ('queued', 'running')
     and exists (select 1 from public.icp_validation_items i where i.run_id = r.id and i.state = 'pending')
   order by r.last_claimed_at nulls first, r.created_at
   limit 1
   for update skip locked;
  if not found then
    return null;
  end if;

  with picked as (
    select i.company_id
      from public.icp_validation_items i
     where i.run_id = v_run.id and i.state = 'pending'
     order by i.position
     limit v_run.batch_size
     for update skip locked
  )
  update public.icp_validation_items i
     set state = 'leased', lease_token = v_token,
         lease_until = now() + make_interval(secs => greatest(30, least(coalesce(p_lease_seconds, 180), 900))),
         attempts = i.attempts + 1
    from picked
   where i.run_id = v_run.id and i.company_id = picked.company_id;

  select jsonb_agg(jsonb_build_object(
           'company_id', c.id, 'name', c.name, 'industry', c.industry,
           'short_description', c.short_description, 'keywords', to_jsonb(c.keywords))
         order by i.position)
    into v_rows
    from public.icp_validation_items i
    join public.companies c on c.id = i.company_id
   where i.lease_token = v_token;

  update public.icp_validation_runs
     set status = 'running', started_at = coalesce(started_at, now()), last_claimed_at = now()
   where id = v_run.id;

  return jsonb_build_object(
    'run_id', v_run.id, 'token', v_token, 'model', v_run.model,
    'reasoning_effort', v_run.reasoning_effort, 'provider_mode', v_run.provider_mode,
    'icp_text', v_run.icp_text, 'rows', coalesce(v_rows, '[]'::jsonb));
end;
$$;

revoke execute on function public.claim_icp_validation_batch_v1(text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- App: start a strategy check.
--   all        the client's companies that have text to read
--   unchecked  those without a current label from this strategy
--   selection  a Company DB selection (ticked ids, pasted and resolved ids, or
--              all matching a search and filters), resolved once
create or replace function public.start_icp_strategy_check_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_strategy text,
  p_scope text default 'all',
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
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
  if coalesce(p_scope, '') not in ('all', 'unchecked', 'selection') then
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
        p_people_scope, p_excluded_ids, v_max + 1);
  else
    select coalesce(array_agg(cc.company_id order by cc.company_id), array[]::text[]) into v_ids
      from public.client_companies cc
     where cc.client_id = p_client_id
       and (p_scope = 'all' or not exists (
             select 1 from public.client_company_icp_verdicts v
              where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
                and v.source = 'strategy:' || p_strategy and v.company_id = cc.company_id
                and v.icp_hash = v_hash));
  end if;
  if cardinality(v_ids) > v_max then
    raise exception using errcode = '22023', message = 'Check at most 100,000 companies at a time. Narrow the selection with a filter.';
  end if;

  insert into public.icp_strategy_checks (id, client_id, icp_profile_id, icp_name, icp_hash, strategy, scope, provider_mode, created_by)
  values (v_check_id, p_client_id, p_icp_profile_id, v_profile.name, v_hash, p_strategy, p_scope, p_provider_mode,
          coalesce(p_created_by, ''));

  -- Only companies with text: the passes' queue drops the rest
  -- (skip_icp_item_without_text), so results must too.
  insert into public.icp_strategy_results (check_id, company_id, position)
  select v_check_id, ids.company_id, min(ids.ord)
    from unnest(v_ids) with ordinality as ids(company_id, ord)
    join public.companies c on c.id = ids.company_id
   where public.company_has_icp_text_v1(c.keywords, c.short_description)
   group by ids.company_id;
  get diagnostics v_total = row_count;
  if v_total = 0 then
    raise exception using errcode = 'P0002', message = case
      when p_scope = 'unchecked' then 'Every company already has a current result from this strategy.'
      when cardinality(v_ids) > 0 then 'None of these companies has a description or keywords to check.'
      else 'There are no companies to check.' end;
  end if;
  update public.icp_strategy_checks set total_items = v_total where id = v_check_id;

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

revoke execute on function public.start_icp_strategy_check_v1(text, text, text, text, text[], text, jsonb, jsonb, text[], text, text) from public, anon, authenticated;
grant execute on function public.start_icp_strategy_check_v1(text, text, text, text, text[], text, jsonb, jsonb, text[], text, text) to service_role;

-- App: pause, resume, cancel or retry the failed companies of every pass of a
-- check. Passes a step does not apply to are left alone (a finished pass is
-- not "resumed"), and nothing locks the check itself - see settle_.
create or replace function public.set_icp_strategy_check_state_v1(
  p_client_id text,
  p_check_id uuid,
  p_action text,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  v_run public.icp_validation_runs%rowtype;
  v_changed integer := 0;
  v_count integer;
  v_by text := case when coalesce(p_actor, '') <> '' then ' by ' || p_actor else '' end;
begin
  if not exists (select 1 from public.icp_strategy_checks where id = p_check_id and client_id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'That check does not belong to this client.';
  end if;
  if p_action not in ('pause', 'resume', 'cancel', 'retry_failed') then
    raise exception using errcode = '22023', message = 'Unknown action.';
  end if;

  for v_run in
    select * from public.icp_validation_runs
     where strategy_check_id = p_check_id
     order by id
     for update
  loop
    if p_action = 'pause' and v_run.status in ('queued', 'running') then
      update public.icp_validation_runs set status = 'paused', status_message = 'Paused' || v_by || '.' where id = v_run.id;
      v_changed := v_changed + 1;
    elsif p_action = 'resume' and v_run.status = 'paused' then
      update public.icp_validation_runs set status = 'queued', status_message = '' where id = v_run.id;
      perform public.finish_icp_validation_run_if_drained_v1(v_run.id);
      v_changed := v_changed + 1;
    elsif p_action = 'cancel' and v_run.status not in ('completed', 'cancelled') then
      update public.icp_validation_items set state = 'skipped' where run_id = v_run.id and state = 'pending';
      update public.icp_validation_runs
         set status = 'cancelled', finished_at = now(), status_message = 'Cancelled' || v_by || '.'
       where id = v_run.id;
      v_changed := v_changed + 1;
    elsif p_action = 'retry_failed' then
      update public.icp_validation_items set state = 'pending', attempts = 0, last_error = ''
       where run_id = v_run.id and state = 'failed';
      get diagnostics v_count = row_count;
      if v_count > 0 then
        update public.icp_validation_runs
           set status = 'queued', status_message = '', finished_at = null,
               failed_items = greatest(0, failed_items - v_count)
         where id = v_run.id;
        v_changed := v_changed + 1;
      end if;
    end if;
  end loop;

  if v_changed = 0 then
    raise exception using errcode = '22023', message = case p_action
      when 'pause' then 'Nothing in this check is running.'
      when 'resume' then 'Nothing in this check is paused.'
      when 'cancel' then 'This check has already finished.'
      else 'This check has no failed companies to retry.' end;
  end if;
  return jsonb_build_object('changed', v_changed);
end;
$$;

revoke execute on function public.set_icp_strategy_check_state_v1(text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.set_icp_strategy_check_state_v1(text, uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- App: recent checks (one client, or every client), each with its passes and
-- the outcome so far. The status is the passes' combined state.
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
               'split', count(*) filter (where s.fit_votes > 0 and s.non_fit_votes > 0)) as value
        from public.icp_strategy_results s
       where s.check_id = c.id) outcome
$$;

revoke execute on function public.icp_strategy_checks_v1(text, integer) from public, anon, authenticated;
grant execute on function public.icp_strategy_checks_v1(text, integer) to service_role;

-- App: one page of a check's companies with the final verdict and every vote.
--   p_filter  all | fit | non_fit | pending | split (the passes disagreed)
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
  v_total bigint;
  v_rows jsonb;
begin
  if not exists (select 1 from public.icp_strategy_checks where id = p_check_id and client_id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'That check does not belong to this client.';
  end if;

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

-- App: how many of a client's companies each scope would check.
create or replace function public.icp_strategy_scope_counts_v1(p_client_id text, p_icp_profile_id text)
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
             'unchecked', jsonb_build_object(
               'strict', count(*) filter (where not coalesce(labels.strict, false)),
               'lenient', count(*) filter (where not coalesce(labels.lenient, false)),
               'balanced', count(*) filter (where not coalesce(labels.balanced, false))))
      from public.client_companies cc
      join public.companies c on c.id = cc.company_id
      left join lateral (
        select bool_or(v.source = 'strategy:strict') as strict,
               bool_or(v.source = 'strategy:lenient') as lenient,
               bool_or(v.source = 'strategy:balanced') as balanced
          from public.client_company_icp_verdicts v
         where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
           and v.company_id = cc.company_id and v.source like 'strategy:%' and v.icp_hash = v_hash) labels on true
     where cc.client_id = p_client_id
       and public.company_has_icp_text_v1(c.keywords, c.short_description));
end;
$$;

revoke execute on function public.icp_strategy_scope_counts_v1(text, text) from public, anon, authenticated;
grant execute on function public.icp_strategy_scope_counts_v1(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- The ICP Validator tab stays the model-comparison bench: strategy passes and
-- strategy labels are this feature's, not models to score.
create or replace function public.icp_validator_overview_v1(p_client_id text, p_icp_profile_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_profile public.client_icp_profiles%rowtype;
  v_hash text;
begin
  select * into v_profile from public.client_icp_profiles
   where id = p_icp_profile_id and client_id = p_client_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;
  v_hash := md5(v_profile.description);

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'id', v_profile.id, 'name', v_profile.name, 'icp_hash', v_hash,
      'description_length', length(v_profile.description),
      -- Only companies a check can judge: Incomplete Info ones are never queued.
      'company_count', (select count(*) from public.client_companies cc
                          join public.companies c on c.id = cc.company_id
                         where cc.client_id = p_client_id and public.company_has_icp_text_v1(c.keywords, c.short_description))),
    'sources', coalesce((
      select jsonb_agg(s order by s.kind desc, s.source)
        from (
          select v.source,
                 case when v.source like 'reference:%' then 'reference' else 'model' end as kind,
                 count(*) as total,
                 count(*) filter (where v.verdict = 'FIT') as fit,
                 count(*) filter (where v.verdict = 'NON_FIT') as non_fit,
                 count(*) filter (where v.source not like 'reference:%' and v.icp_hash <> v_hash) as stale,
                 max(v.decided_at) as last_decided_at
            from public.client_company_icp_verdicts v
           where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
             and v.source not like 'strategy:%'
           group by v.source) s), '[]'::jsonb),
    'runs', coalesce((
      select jsonb_agg(to_jsonb(r) - 'icp_text' || jsonb_build_object('icp_current', r.icp_hash = v_hash) order by r.created_at desc)
        from (select * from public.icp_validation_runs
               where client_id = p_client_id and icp_profile_id = p_icp_profile_id
                 and strategy_check_id is null
               order by created_at desc limit 30) r), '[]'::jsonb),
    'worker', coalesce((
      select jsonb_build_object('configured', h.configured, 'seen_at', h.seen_at,
                                'alive', h.seen_at > now() - interval '2 minutes')
        from public.icp_worker_heartbeat h), jsonb_build_object('configured', false, 'seen_at', null, 'alive', false))
  );
end;
$$;

revoke execute on function public.icp_validator_overview_v1(text, text) from public, anon, authenticated;
grant execute on function public.icp_validator_overview_v1(text, text) to service_role;

-- The worker's grants are unchanged (same four signatures); settle_ runs as
-- the definer of complete_.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'prospect_icp_validator') then
    execute 'grant execute on function public.claim_icp_validation_batch_v1(text, integer) to prospect_icp_validator';
    execute 'grant execute on function public.complete_icp_validation_batch_v1(uuid, uuid, jsonb, jsonb) to prospect_icp_validator';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: each strategy over two real companies. Votes are fed in
-- the way the worker would (lease, then complete_), pass by pass, and the
-- outcome is checked at every step - including that a decided company is
-- labelled before its last pass lands, and that passes write no model label.
do $$
declare
  v_client text;
  v_companies text[];
  v_profile text := 'icp-strategy-proof-' || gen_random_uuid();
  v_check jsonb;
  v_check_id uuid;
  v_list jsonb;

  -- Feeds one pass's votes for both companies.
  v_run uuid;
  v_token uuid;
begin
  select cc.client_id into v_client
    from public.client_companies cc join public.companies c on c.id = cc.company_id
   where public.company_has_icp_text_v1(c.keywords, c.short_description)
   group by cc.client_id
  having count(*) >= 2
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP strategy proof skipped: no client with two checkable companies.';
    return;
  end if;

  begin
    select array_agg(company_id order by company_id) into v_companies
      from (select cc.company_id from public.client_companies cc join public.companies c on c.id = cc.company_id
             where cc.client_id = v_client and public.company_has_icp_text_v1(c.keywords, c.short_description)
             order by cc.company_id limit 2) picked;
    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');

    -- STRICT: company 1 gets FIT then FIT; company 2 gets NON_FIT on pass 1,
    -- which decides it before pass 2.
    v_check := public.start_icp_strategy_check_v1(v_client, v_profile, 'strict', 'selection', v_companies,
      '', '[]'::jsonb, null, null, 'cheapest', 'proof');
    v_check_id := (v_check->>'id')::uuid;
    if (v_check->>'total_items')::int <> 2
       or (select count(*) from public.icp_validation_runs where strategy_check_id = v_check_id) <> 2
       or (select count(*) from public.icp_validation_items i join public.icp_validation_runs r on r.id = i.run_id
            where r.strategy_check_id = v_check_id and i.state = 'pending') <> 4
       or exists (select 1 from public.icp_validation_runs where strategy_check_id = v_check_id and provider_mode <> 'cheapest') then
      raise exception 'ICP strategy proof: strict check queued wrong: %', v_check;
    end if;

    select id into v_run from public.icp_validation_runs where strategy_check_id = v_check_id and pass_no = 1;
    v_token := gen_random_uuid();
    update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
    perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
      jsonb_build_object('company_id', v_companies[1], 'verdict', 'FIT', 'reason', 'makes fertilizer'),
      jsonb_build_object('company_id', v_companies[2], 'verdict', 'NON_FIT', 'reason', 'a software vendor')),
      '{"cost": 0.001, "provider": "Proof Cloud"}'::jsonb);

    if (select verdict from public.icp_strategy_results where check_id = v_check_id and company_id = v_companies[2]) is distinct from 'NON_FIT'
       or (select verdict from public.icp_strategy_results where check_id = v_check_id and company_id = v_companies[1]) is not null then
      raise exception 'ICP strategy proof: strict did not decide NON_FIT early / waited for FIT';
    end if;
    if exists (select 1 from public.client_company_icp_verdicts where icp_profile_id = v_profile and source not like 'strategy:%') then
      raise exception 'ICP strategy proof: a pass wrote a per-model label';
    end if;
    if (select (providers->>'Proof Cloud')::int from public.icp_validation_runs where id = v_run) is distinct from 1 then
      raise exception 'ICP strategy proof: the provider was not counted';
    end if;

    select id into v_run from public.icp_validation_runs where strategy_check_id = v_check_id and pass_no = 2;
    v_token := gen_random_uuid();
    update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
    perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
      jsonb_build_object('company_id', v_companies[1], 'verdict', 'FIT', 'reason', 'fertilizer maker'),
      jsonb_build_object('company_id', v_companies[2], 'verdict', 'FIT', 'reason', 'unclear')), '{}'::jsonb);

    if (select verdict from public.icp_strategy_results where check_id = v_check_id and company_id = v_companies[1]) is distinct from 'FIT'
       or (select verdict from public.icp_strategy_results where check_id = v_check_id and company_id = v_companies[2]) is distinct from 'NON_FIT'
       or (select reason from public.icp_strategy_results where check_id = v_check_id and company_id = v_companies[2]) <> 'a software vendor'
       or (select count(*) from public.client_company_icp_verdicts where icp_profile_id = v_profile and source = 'strategy:strict') <> 2 then
      raise exception 'ICP strategy proof: strict outcome wrong';
    end if;
    select public.icp_strategy_checks_v1(v_client, 100) into v_list;
    if not exists (select 1 from jsonb_array_elements(v_list) e
                    where (e->>'id')::uuid = v_check_id and e->>'status' = 'completed'
                      and (e->'outcome'->>'fit')::int = 1 and (e->'outcome'->>'non_fit')::int = 1
                      and (e->'outcome'->>'split')::int = 1 and jsonb_array_length(e->'passes') = 2) then
      raise exception 'ICP strategy proof: the checks list answered %', v_list;
    end if;
    if (public.icp_strategy_results_v1(v_client, v_check_id, 'split', '', 100, 0)->>'total')::int <> 1 then
      raise exception 'ICP strategy proof: the split filter is wrong';
    end if;

    -- LENIENT: company 1 NON_FIT then FIT -> FIT; company 2 NON_FIT twice.
    v_check := public.start_icp_strategy_check_v1(v_client, v_profile, 'lenient', 'selection', v_companies,
      '', '[]'::jsonb, null, null, 'default', 'proof');
    v_check_id := (v_check->>'id')::uuid;
    if exists (select 1 from public.icp_validation_items i join public.icp_validation_runs r on r.id = i.run_id
                where r.strategy_check_id = v_check_id and i.cached) then
      raise exception 'ICP strategy proof: a lenient pass reused an earlier verdict';
    end if;
    for v_run in select id from public.icp_validation_runs where strategy_check_id = v_check_id order by pass_no loop
      v_token := gen_random_uuid();
      update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
      perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
        jsonb_build_object('company_id', v_companies[1], 'verdict',
          case when (select pass_no from public.icp_validation_runs where id = v_run) = 1 then 'NON_FIT' else 'FIT' end, 'reason', 'r'),
        jsonb_build_object('company_id', v_companies[2], 'verdict', 'NON_FIT', 'reason', 'r')), '{}'::jsonb);
    end loop;
    if (select string_agg(coalesce(verdict, '-'), ',' order by company_id) from public.icp_strategy_results where check_id = v_check_id)
       <> 'FIT,NON_FIT' then
      raise exception 'ICP strategy proof: lenient outcome wrong';
    end if;

    -- BALANCED: company 1 FIT, NON_FIT, FIT -> FIT (decided on pass 3);
    -- company 2 NON_FIT, NON_FIT -> NON_FIT (decided on pass 2).
    v_check := public.start_icp_strategy_check_v1(v_client, v_profile, 'balanced', 'selection', v_companies,
      '', '[]'::jsonb, null, null, 'cheapest', 'proof');
    v_check_id := (v_check->>'id')::uuid;
    for v_run in select id from public.icp_validation_runs where strategy_check_id = v_check_id order by pass_no loop
      v_token := gen_random_uuid();
      update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
      perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
        jsonb_build_object('company_id', v_companies[1], 'verdict',
          case (select pass_no from public.icp_validation_runs where id = v_run) when 2 then 'NON_FIT' else 'FIT' end, 'reason', 'r'),
        jsonb_build_object('company_id', v_companies[2], 'verdict', 'NON_FIT', 'reason', 'r')), '{}'::jsonb);
      if (select pass_no from public.icp_validation_runs where id = v_run) = 2
         and (select string_agg(coalesce(verdict, '-'), ',' order by company_id) from public.icp_strategy_results where check_id = v_check_id) <> '-,NON_FIT' then
        raise exception 'ICP strategy proof: balanced after two passes is wrong';
      end if;
    end loop;
    if (select string_agg(coalesce(verdict, '-'), ',' order by company_id) from public.icp_strategy_results where check_id = v_check_id)
       <> 'FIT,NON_FIT' then
      raise exception 'ICP strategy proof: balanced outcome wrong';
    end if;

    -- "Not checked yet" no longer counts the two companies for any strategy.
    v_list := public.icp_strategy_scope_counts_v1(v_client, v_profile);
    if (v_list->'unchecked'->>'balanced')::int <> (v_list->>'all')::int - 2
       or (v_list->'unchecked'->>'strict')::int <> (v_list->>'all')::int - 2 then
      raise exception 'ICP strategy proof: scope counts answered %', v_list;
    end if;

    -- The model bench does not see strategy passes.
    if jsonb_array_length(public.icp_validator_overview_v1(v_client, v_profile)->'runs') <> 0
       or jsonb_array_length(public.icp_validator_overview_v1(v_client, v_profile)->'sources') <> 0 then
      raise exception 'ICP strategy proof: strategy passes leaked into the ICP Validator overview';
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP strategy proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
