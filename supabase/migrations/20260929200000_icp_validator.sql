-- ICP validator: an LLM reads a client's ICP brief and labels each of that
-- client's companies FIT or NON_FIT from the company's own text.
--
-- WHAT IT IS FOR. Lists are keyword-pulled, so a client's Company DB holds the
-- companies that TALK about the ICP audience (vendors, agencies, publishers)
-- mixed in with the ones that ARE it. Reading 11,000 short descriptions by hand
-- is the job this does.
--
-- THE SHAPE.
--   icp_validation_runs     one "check these companies against this ICP with
--                           this model" request. The ICP text is copied into
--                           the run, so editing the brief later never changes
--                           what an in-flight run is judging against.
--   icp_validation_items    the run's queue: one row per company, leased to the
--                           ICP worker 20 at a time.
--   client_company_icp_verdicts
--                           the latest verdict per (client, ICP, source,
--                           company). A source is a model slug, or
--                           'reference:<label>' for results produced elsewhere
--                           (e.g. an earlier Claude Fable run) and imported so the
--                           models can be scored against them.
--
-- A LABEL, NOT AN ACTION. Nothing here hides, removes, blocks or validates a
-- company. client_company_icp_validations (the manual "validated" umbrella that
-- also flips prospects to icp_verified) is not touched. Deciding what to do
-- with NON_FIT stays with the operator.
--
-- NEVER PAY TWICE. Each verdict records md5 of the ICP text it was judged
-- against. A new run reuses a verdict from the same model for the same ICP
-- text; an edited brief makes the old verdicts "stale" instead of silently
-- current.
--
-- WHO CAN CALL WHAT. The app (service_role) starts, steers and reads runs.
-- The ICP worker logs in as prospect_icp_worker, a member of the
-- prospect_icp_validator capability role, which can execute exactly four
-- functions: report, claim, complete, fail. It reads company text only through
-- claim, and only the rows it has leased.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create table if not exists public.icp_validation_runs (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references public.clients(id) on delete cascade,
  icp_profile_id text not null references public.client_icp_profiles(id) on delete cascade,
  icp_name text not null default '',
  icp_text text not null,
  icp_hash text not null,
  model text not null,
  reasoning_effort text not null default 'low'
    check (reasoning_effort in ('minimal', 'low', 'medium', 'high')),
  scope text not null check (scope in ('all', 'unchecked', 'reference', 'sample', 'same_as')),
  scope_detail text not null default '',
  batch_size integer not null default 20 check (batch_size between 1 and 50),
  status text not null default 'queued'
    check (status in ('queued', 'running', 'paused', 'completed', 'cancelled')),
  status_message text not null default '',
  total_items integer not null default 0,
  done_items integer not null default 0,
  cached_items integer not null default 0,
  fit_items integer not null default 0,
  non_fit_items integer not null default 0,
  failed_items integer not null default 0,
  cost_usd numeric(14, 6) not null default 0,
  prompt_tokens bigint not null default 0,
  cached_prompt_tokens bigint not null default 0,
  completion_tokens bigint not null default 0,
  reasoning_tokens bigint not null default 0,
  request_count integer not null default 0,
  request_ms bigint not null default 0,
  bake_off_id uuid,
  created_by text not null default '',
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  last_claimed_at timestamptz
);

comment on table public.icp_validation_runs is
  'One LLM ICP check: a client ICP (text frozen at start), a model, and a set of companies queued in icp_validation_items.';

create index if not exists idx_icp_validation_runs_profile
  on public.icp_validation_runs (client_id, icp_profile_id, created_at desc);
-- The worker's only question: which runs have work.
create index if not exists idx_icp_validation_runs_active
  on public.icp_validation_runs (last_claimed_at nulls first, created_at)
  where status in ('queued', 'running');

create table if not exists public.icp_validation_items (
  run_id uuid not null references public.icp_validation_runs(id) on delete cascade,
  company_id text not null references public.companies(id) on delete cascade,
  position integer not null,
  state text not null default 'pending'
    check (state in ('pending', 'leased', 'done', 'failed', 'skipped')),
  verdict text check (verdict in ('FIT', 'NON_FIT')),
  reason text not null default '',
  cached boolean not null default false,
  attempts smallint not null default 0,
  lease_token uuid,
  lease_until timestamptz,
  last_error text not null default '',
  finished_at timestamptz,
  primary key (run_id, company_id)
);

create index if not exists idx_icp_validation_items_pending
  on public.icp_validation_items (run_id, position) where state = 'pending';
create index if not exists idx_icp_validation_items_leased
  on public.icp_validation_items (lease_until) where state = 'leased';
create index if not exists idx_icp_validation_items_token
  on public.icp_validation_items (lease_token) where lease_token is not null;
create index if not exists idx_icp_validation_items_company
  on public.icp_validation_items (company_id);

create table if not exists public.client_company_icp_verdicts (
  client_id text not null references public.clients(id) on delete cascade,
  icp_profile_id text not null references public.client_icp_profiles(id) on delete cascade,
  source text not null check (source <> ''),
  company_id text not null references public.companies(id) on delete cascade,
  verdict text not null check (verdict in ('FIT', 'NON_FIT')),
  reason text not null default '',
  icp_hash text not null default '',
  run_id uuid references public.icp_validation_runs(id) on delete set null,
  decided_at timestamptz not null default now(),
  primary key (client_id, icp_profile_id, source, company_id)
);

comment on table public.client_company_icp_verdicts is
  'Latest FIT/NON_FIT per client ICP, company and source (a model slug, or reference:<label> for imported results). A label only - nothing is hidden or removed by it.';

create index if not exists idx_client_company_icp_verdicts_company
  on public.client_company_icp_verdicts (client_id, icp_profile_id, company_id);
create index if not exists idx_client_company_icp_verdicts_by_company
  on public.client_company_icp_verdicts (company_id);
create index if not exists idx_client_company_icp_verdicts_run
  on public.client_company_icp_verdicts (run_id) where run_id is not null;

-- One row: whether an ICP worker is alive and has an OpenRouter key. The page
-- reads it to say "add the key" instead of showing a queue that never moves.
create table if not exists public.icp_worker_heartbeat (
  id boolean primary key default true check (id),
  configured boolean not null default false,
  worker text not null default '',
  seen_at timestamptz not null default now()
);

do $$
declare
  v_table text;
begin
  foreach v_table in array array['icp_validation_runs', 'icp_validation_items', 'client_company_icp_verdicts', 'icp_worker_heartbeat'] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('revoke all on public.%I from public, anon, authenticated', v_table);
    execute format('grant select, insert, update, delete on public.%I to service_role', v_table);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Internal: close a run once nothing is pending or leased.
create or replace function public.finish_icp_validation_run_if_drained_v1(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.icp_validation_runs r
     set status = 'completed',
         finished_at = now(),
         status_message = case when r.failed_items > 0
           then r.failed_items || ' compan' || case when r.failed_items = 1 then 'y' else 'ies' end
                || ' could not be checked. Use "Retry failed" to try them again.'
           else '' end
   where r.id = p_run_id
     and r.status in ('queued', 'running')
     and not exists (
       select 1 from public.icp_validation_items i
        where i.run_id = p_run_id and i.state in ('pending', 'leased'));
end;
$$;

revoke execute on function public.finish_icp_validation_run_if_drained_v1(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- App: start a run.
--   all        every company in the client's Company DB
--   unchecked  the client's companies this model has no current verdict for
--   reference  the companies an imported reference (p_scope_detail = label) judged
--   sample     p_sample_size random companies from the client's Company DB
--   same_as    exactly the companies of run p_scope_detail (for a fair
--              side-by-side of several models on one random sample)
create or replace function public.start_icp_validation_run_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_model text,
  p_reasoning_effort text default 'low',
  p_scope text default 'all',
  p_scope_detail text default '',
  p_sample_size integer default null,
  p_reuse boolean default true,
  p_batch_size integer default 20,
  p_bake_off_id uuid default null,
  p_created_by text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_profile public.client_icp_profiles%rowtype;
  v_run_id uuid := gen_random_uuid();
  v_hash text;
  v_total integer;
  v_cached integer := 0;
  v_fit integer := 0;
  v_non_fit integer := 0;
  v_source_run uuid;
  v_max_items constant integer := 100000;
begin
  select * into v_profile
    from public.client_icp_profiles
   where id = p_icp_profile_id and client_id = p_client_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;
  if btrim(v_profile.description) = '' then
    raise exception using errcode = '22023', message = 'This ICP has no brief to check companies against. Add one on the ICPs tab.';
  end if;
  if coalesce(p_model, '') !~ '^[a-z0-9][a-z0-9._~-]*/[a-z0-9][a-z0-9._:~-]*$' then
    raise exception using errcode = '22023', message = 'Unknown model.';
  end if;
  if p_scope not in ('all', 'unchecked', 'reference', 'sample', 'same_as') then
    raise exception using errcode = '22023', message = 'Unknown scope.';
  end if;
  if p_scope = 'sample' and coalesce(p_sample_size, 0) not between 1 and 5000 then
    raise exception using errcode = '22023', message = 'A sample is between 1 and 5,000 companies.';
  end if;
  if p_scope = 'same_as' then
    begin
      v_source_run := p_scope_detail::uuid;
    exception when invalid_text_representation then
      raise exception using errcode = '22023', message = 'Which run should be repeated?';
    end;
    if not exists (select 1 from public.icp_validation_runs
                    where id = v_source_run and client_id = p_client_id and icp_profile_id = p_icp_profile_id) then
      raise exception using errcode = 'P0002', message = 'That run does not belong to this ICP.';
    end if;
  end if;

  v_hash := md5(v_profile.description);

  insert into public.icp_validation_runs (
    id, client_id, icp_profile_id, icp_name, icp_text, icp_hash, model, reasoning_effort,
    scope, scope_detail, batch_size, bake_off_id, created_by)
  values (
    v_run_id, p_client_id, p_icp_profile_id, v_profile.name, v_profile.description, v_hash, p_model,
    coalesce(nullif(p_reasoning_effort, ''), 'low'),
    p_scope, case when p_scope = 'sample' then p_sample_size::text else coalesce(p_scope_detail, '') end,
    greatest(1, least(coalesce(p_batch_size, 20), 50)), p_bake_off_id, coalesce(p_created_by, ''));

  insert into public.icp_validation_items (run_id, company_id, position)
  select v_run_id, candidate.company_id, row_number() over (order by candidate.sort_key, candidate.company_id)
    from (
      select cc.company_id, cc.company_id as sort_key
        from public.client_companies cc
       where p_scope in ('all', 'unchecked')
         and cc.client_id = p_client_id
         and (p_scope = 'all' or not exists (
               select 1 from public.client_company_icp_verdicts v
                where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
                  and v.source = p_model and v.company_id = cc.company_id and v.icp_hash = v_hash))
      union all
      select v.company_id, v.company_id
        from public.client_company_icp_verdicts v
       where p_scope = 'reference'
         and v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
         and v.source = 'reference:' || p_scope_detail
      union all
      select sampled.company_id, sampled.company_id
        from (select cc.company_id from public.client_companies cc
               where p_scope = 'sample' and cc.client_id = p_client_id
               order by random() limit greatest(coalesce(p_sample_size, 0), 0)) sampled
      union all
      select i.company_id, lpad(i.position::text, 10, '0')
        from public.icp_validation_items i
       where p_scope = 'same_as' and i.run_id = v_source_run
    ) candidate
   limit v_max_items;

  get diagnostics v_total = row_count;
  if v_total = 0 then
    raise exception using errcode = 'P0002', message = case p_scope
      when 'unchecked' then 'Every company already has a current verdict from this model.'
      when 'reference' then 'No reference results are imported under that name for this ICP.'
      else 'There are no companies to check.' end;
  end if;

  if p_reuse then
    with reused as (
      update public.icp_validation_items i
         set state = 'done', verdict = v.verdict, reason = v.reason, cached = true, finished_at = now()
        from public.client_company_icp_verdicts v
       where i.run_id = v_run_id
         and v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
         and v.source = p_model and v.company_id = i.company_id and v.icp_hash = v_hash
      returning i.verdict)
    select count(*), count(*) filter (where verdict = 'FIT'), count(*) filter (where verdict = 'NON_FIT')
      into v_cached, v_fit, v_non_fit
      from reused;
  end if;

  update public.icp_validation_runs
     set total_items = v_total, done_items = v_cached, cached_items = v_cached,
         fit_items = v_fit, non_fit_items = v_non_fit
   where id = v_run_id;

  perform public.finish_icp_validation_run_if_drained_v1(v_run_id);

  return (select to_jsonb(r) - 'icp_text' from public.icp_validation_runs r where r.id = v_run_id);
end;
$$;

revoke execute on function public.start_icp_validation_run_v1(text, text, text, text, text, text, integer, boolean, integer, uuid, text) from public, anon, authenticated;
grant execute on function public.start_icp_validation_run_v1(text, text, text, text, text, text, integer, boolean, integer, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- App: pause, resume, cancel, or retry the failed companies of a run.
create or replace function public.set_icp_validation_run_state_v1(
  p_client_id text,
  p_run_id uuid,
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
  v_count integer;
begin
  select * into v_run from public.icp_validation_runs
   where id = p_run_id and client_id = p_client_id
   for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'That run does not belong to this client.';
  end if;

  if p_action = 'pause' then
    if v_run.status not in ('queued', 'running') then
      raise exception using errcode = '22023', message = 'Only a queued or running check can be paused.';
    end if;
    update public.icp_validation_runs
       set status = 'paused', status_message = 'Paused' || case when p_actor <> '' then ' by ' || p_actor else '' end || '.'
     where id = p_run_id;
  elsif p_action = 'resume' then
    if v_run.status <> 'paused' then
      raise exception using errcode = '22023', message = 'Only a paused check can be resumed.';
    end if;
    update public.icp_validation_runs set status = 'queued', status_message = '' where id = p_run_id;
    perform public.finish_icp_validation_run_if_drained_v1(p_run_id);
  elsif p_action = 'cancel' then
    if v_run.status in ('completed', 'cancelled') then
      raise exception using errcode = '22023', message = 'This check has already finished.';
    end if;
    -- Leased rows are left alone: their model call is already paid for, and
    -- complete_ saves what comes back even for a cancelled run.
    update public.icp_validation_items set state = 'skipped'
     where run_id = p_run_id and state = 'pending';
    update public.icp_validation_runs
       set status = 'cancelled', finished_at = now(),
           status_message = 'Cancelled' || case when p_actor <> '' then ' by ' || p_actor else '' end || '.'
     where id = p_run_id;
  elsif p_action = 'retry_failed' then
    update public.icp_validation_items
       set state = 'pending', attempts = 0, last_error = ''
     where run_id = p_run_id and state = 'failed';
    get diagnostics v_count = row_count;
    if v_count = 0 then
      raise exception using errcode = '22023', message = 'This check has no failed companies to retry.';
    end if;
    update public.icp_validation_runs
       set status = 'queued', status_message = '', finished_at = null,
           failed_items = greatest(0, failed_items - v_count)
     where id = p_run_id;
  else
    raise exception using errcode = '22023', message = 'Unknown action.';
  end if;

  return (select to_jsonb(r) - 'icp_text' from public.icp_validation_runs r where r.id = p_run_id);
end;
$$;

revoke execute on function public.set_icp_validation_run_state_v1(text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.set_icp_validation_run_state_v1(text, uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- App: import verdicts produced elsewhere as a reference to score models by.
-- p_rows: [{name, domain, verdict, reason}]. The app normalizes domain the
-- same way imports do (host, no www). Matching is exact and client-scoped:
-- domain first, then the normalized name; anything that matches none or more
-- than one of the client's companies is reported, never guessed.
create or replace function public.import_icp_reference_verdicts_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_label text,
  p_rows jsonb,
  p_replace boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_label text := lower(btrim(coalesce(p_label, '')));
  v_source text;
  v_result jsonb;
begin
  if v_label !~ '^[a-z0-9][a-z0-9_-]{0,39}$' then
    raise exception using errcode = '22023', message = 'A reference name is 1-40 letters, digits, dashes or underscores.';
  end if;
  if not exists (select 1 from public.client_icp_profiles where id = p_icp_profile_id and client_id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 5000 then
    raise exception using errcode = '22023', message = 'Send reference rows as an array of at most 5,000.';
  end if;
  v_source := 'reference:' || v_label;

  if p_replace then
    delete from public.client_company_icp_verdicts
     where client_id = p_client_id and icp_profile_id = p_icp_profile_id and source = v_source;
  end if;

  with input as (
    select ord as n,
           btrim(coalesce(r->>'name', '')) as name,
           lower(regexp_replace(btrim(coalesce(r->>'name', '')), '\s+', ' ', 'g')) as nname,
           lower(btrim(coalesce(r->>'domain', ''))) as domain,
           upper(replace(replace(btrim(coalesce(r->>'verdict', '')), '-', '_'), ' ', '_')) as verdict,
           left(btrim(coalesce(r->>'reason', '')), 1000) as reason
      from jsonb_array_elements(p_rows) with ordinality as t(r, ord)
  ),
  member as materialized (
    select c.id, c.normalized_name, c.normalized_domain
      from public.client_companies cc
      join public.companies c on c.id = cc.company_id
     where cc.client_id = p_client_id
  ),
  domain_hits as (
    select i.n, count(*) as hits, min(m.id) as company_id
      from input i join member m on i.domain <> '' and m.normalized_domain = i.domain
     group by i.n
  ),
  name_hits as (
    select i.n, count(*) as hits, min(m.id) as company_id
      from input i join member m on i.nname <> '' and m.normalized_name = i.nname
     group by i.n
  ),
  resolved as (
    select i.*,
           case when i.verdict not in ('FIT', 'NON_FIT') then null
                when d.hits = 1 then d.company_id
                when nh.hits = 1 then nh.company_id end as company_id,
           case when i.verdict not in ('FIT', 'NON_FIT') then 'invalid'
                when d.hits = 1 or nh.hits = 1 then 'matched'
                when coalesce(d.hits, 0) > 1 or coalesce(nh.hits, 0) > 1 then 'ambiguous'
                else 'unmatched' end as outcome
      from input i
      left join domain_hits d on d.n = i.n
      left join name_hits nh on nh.n = i.n
  ),
  -- The same company listed twice keeps its last verdict.
  latest as (
    select distinct on (company_id) company_id, verdict, reason
      from resolved where company_id is not null
     order by company_id, n desc
  ),
  saved as (
    insert into public.client_company_icp_verdicts
      (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash, run_id, decided_at)
    select p_client_id, p_icp_profile_id, v_source, company_id, verdict, reason, '', null, now()
      from latest
    on conflict (client_id, icp_profile_id, source, company_id) do update
      set verdict = excluded.verdict, reason = excluded.reason, decided_at = excluded.decided_at
    returning 1
  )
  select jsonb_build_object(
    'source', v_source,
    'received', (select count(*) from input),
    'saved', (select count(*) from saved),
    'matched', (select count(*) from resolved where outcome = 'matched'),
    'unmatched', (select count(*) from resolved where outcome = 'unmatched'),
    'ambiguous', (select count(*) from resolved where outcome = 'ambiguous'),
    'invalid', (select count(*) from resolved where outcome = 'invalid'),
    'problems', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'domain', domain, 'verdict', verdict, 'outcome', outcome) order by n)
        from (select * from resolved where outcome <> 'matched' order by n limit 50) p), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function public.import_icp_reference_verdicts_v1(text, text, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.import_icp_reference_verdicts_v1(text, text, text, jsonb, boolean) to service_role;

-- App: forget one source's verdicts for an ICP (a bad reference import, or a
-- model you have ruled out).
create or replace function public.delete_icp_verdict_source_v1(p_client_id text, p_icp_profile_id text, p_source text)
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  v_count integer;
begin
  delete from public.client_company_icp_verdicts
   where client_id = p_client_id and icp_profile_id = p_icp_profile_id and source = p_source;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.delete_icp_verdict_source_v1(text, text, text) from public, anon, authenticated;
grant execute on function public.delete_icp_verdict_source_v1(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- App: everything the validator screen shows for one ICP, in one call.
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
      'company_count', (select count(*) from public.client_companies cc where cc.client_id = p_client_id)),
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
           group by v.source) s), '[]'::jsonb),
    'runs', coalesce((
      select jsonb_agg(to_jsonb(r) - 'icp_text' || jsonb_build_object('icp_current', r.icp_hash = v_hash) order by r.created_at desc)
        from (select * from public.icp_validation_runs
               where client_id = p_client_id and icp_profile_id = p_icp_profile_id
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

-- App: how each source agrees with a reference, as a confusion matrix. The
-- two ways to disagree are not equally bad: false_non_fit (model says
-- NON_FIT, reference says FIT) is a lost lead; missed_non_fit is a wasted
-- email. Stale model verdicts (judged against an older brief) are left out
-- unless asked for.
create or replace function public.icp_verdict_comparison_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_reference text,
  p_include_stale boolean default false
)
returns table (
  source text, compared bigint, agree bigint, both_fit bigint, both_non_fit bigint,
  false_non_fit bigint, missed_non_fit bigint, reference_total bigint
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
  with profile as (
    select md5(description) as icp_hash from public.client_icp_profiles
     where id = p_icp_profile_id and client_id = p_client_id
  ),
  ref as (
    select company_id, verdict from public.client_company_icp_verdicts
     where client_id = p_client_id and icp_profile_id = p_icp_profile_id and source = p_reference
  )
  select m.source,
         count(*),
         count(*) filter (where m.verdict = ref.verdict),
         count(*) filter (where m.verdict = 'FIT' and ref.verdict = 'FIT'),
         count(*) filter (where m.verdict = 'NON_FIT' and ref.verdict = 'NON_FIT'),
         count(*) filter (where m.verdict = 'NON_FIT' and ref.verdict = 'FIT'),
         count(*) filter (where m.verdict = 'FIT' and ref.verdict = 'NON_FIT'),
         (select count(*) from ref)
    from ref
    join public.client_company_icp_verdicts m
      on m.client_id = p_client_id and m.icp_profile_id = p_icp_profile_id
     and m.company_id = ref.company_id and m.source <> p_reference
   cross join profile
   where p_include_stale or m.source like 'reference:%' or m.icp_hash = profile.icp_hash
   group by m.source
   order by m.source
$$;

revoke execute on function public.icp_verdict_comparison_v1(text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.icp_verdict_comparison_v1(text, text, text, boolean) to service_role;

-- App: companies with their verdicts from the chosen sources, side by side.
--   p_filter  all | disagree (the sources differ) | non_fit (any says NON_FIT)
--             | fit (all say FIT)
--   p_verdict_source + p_verdict  optional: only rows where that source said
--             that verdict
create or replace function public.icp_verdict_rows_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_sources text[],
  p_filter text default 'all',
  p_search text default '',
  p_limit integer default 100,
  p_offset integer default 0,
  p_verdict_source text default '',
  p_verdict text default ''
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $$
declare
  v_hash text;
  v_search text := btrim(coalesce(p_search, ''));
  v_result jsonb;
begin
  select md5(description) into v_hash from public.client_icp_profiles
   where id = p_icp_profile_id and client_id = p_client_id;
  if v_hash is null then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;

  with grouped as (
    select v.company_id,
           jsonb_object_agg(v.source, jsonb_build_object(
             'verdict', v.verdict, 'reason', v.reason,
             'current', v.source like 'reference:%' or v.icp_hash = v_hash)) as verdicts,
           count(distinct v.verdict) as kinds,
           bool_or(v.verdict = 'NON_FIT') as any_non_fit,
           bool_and(v.verdict = 'FIT') as all_fit,
           bool_or(v.source = p_verdict_source and v.verdict = p_verdict) as verdict_match
      from public.client_company_icp_verdicts v
     where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
       and v.source = any(coalesce(p_sources, array[]::text[]))
     group by v.company_id
  ),
  filtered as (
    select g.*, c.name, c.domain, c.industry, c.short_description, c.keywords
      from grouped g
      join public.companies c on c.id = g.company_id
     where (coalesce(p_filter, 'all') = 'all'
            or (p_filter = 'disagree' and g.kinds > 1)
            or (p_filter = 'non_fit' and g.any_non_fit)
            or (p_filter = 'fit' and g.all_fit))
       and (coalesce(p_verdict_source, '') = '' or g.verdict_match)
       and (v_search = '' or c.name ilike '%' || v_search || '%' or c.domain ilike '%' || v_search || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'company_id', f.company_id, 'name', f.name, 'domain', f.domain, 'industry', f.industry,
               'short_description', left(f.short_description, 1200),
               'keywords', left(array_to_string(f.keywords, ', '), 600),
               'verdicts', f.verdicts) order by f.kinds > 1 desc, lower(f.name), f.company_id)
        from (select * from filtered
               order by kinds > 1 desc, lower(name), company_id
               limit greatest(1, least(coalesce(p_limit, 100), 1000))
               offset greatest(0, coalesce(p_offset, 0))) f), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke execute on function public.icp_verdict_rows_v1(text, text, text[], text, text, integer, integer, text, text) from public, anon, authenticated;
grant execute on function public.icp_verdict_rows_v1(text, text, text[], text, text, integer, integer, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Worker: heartbeat.
create or replace function public.report_icp_worker_v1(p_configured boolean, p_worker text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.icp_worker_heartbeat (id, configured, worker, seen_at)
  values (true, coalesce(p_configured, false), left(coalesce(p_worker, ''), 200), now())
  on conflict (id) do update
    set configured = excluded.configured, worker = excluded.worker, seen_at = excluded.seen_at
$$;

revoke execute on function public.report_icp_worker_v1(boolean, text) from public, anon, authenticated;

-- Worker: lease the next batch. Runs take turns (least recently claimed
-- first), so three models started together progress together.
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
    'reasoning_effort', v_run.reasoning_effort, 'icp_text', v_run.icp_text,
    'rows', coalesce(v_rows, '[]'::jsonb));
end;
$$;

revoke execute on function public.claim_icp_validation_batch_v1(text, integer) from public, anon, authenticated;

-- Worker: save a batch's verdicts. Rows the model left out go back in line
-- (or fail after four attempts). Saved even if the run was paused or
-- cancelled meanwhile: the call is already paid for.
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
    on conflict (client_id, icp_profile_id, source, company_id) do update
      set verdict = excluded.verdict, reason = excluded.reason, icp_hash = excluded.icp_hash,
          run_id = excluded.run_id, decided_at = excluded.decided_at
    returning 1
  )
  select count(*), count(*) filter (where verdict = 'FIT'), count(*) filter (where verdict = 'NON_FIT')
    into v_saved, v_fit, v_non_fit
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
         request_ms = request_ms + coalesce((p_usage->>'ms')::bigint, 0)
   where id = p_run_id;

  perform public.finish_icp_validation_run_if_drained_v1(p_run_id);
  return jsonb_build_object('saved', v_saved, 'failed', v_failed);
end;
$$;

revoke execute on function public.complete_icp_validation_batch_v1(uuid, uuid, jsonb, jsonb) from public, anon, authenticated;

-- Worker: a batch's model call failed.
--   p_retry         put the rows back in line (until they run out of attempts)
--   p_pause_scope   '' | 'run' | 'all': the problem is not these rows but the
--                   run (the model says the ICP can't be judged from this
--                   text) or every run (bad key, no credits). The rows go back
--                   with the attempt refunded and the run(s) pause with
--                   p_message, so nothing burns while it can't succeed.
create or replace function public.fail_icp_validation_batch_v1(
  p_run_id uuid,
  p_token uuid,
  p_error text,
  p_retry boolean default true,
  p_pause_scope text default '',
  p_message text default '',
  p_usage jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_failed integer := 0;
  v_pause boolean := coalesce(p_pause_scope, '') in ('run', 'all');
begin
  perform 1 from public.icp_validation_runs where id = p_run_id for update;
  if not found then
    return jsonb_build_object('failed', 0);
  end if;

  with released as (
    update public.icp_validation_items
       set state = case when v_pause then 'pending'
                        when p_retry and attempts < 4 then 'pending'
                        else 'failed' end,
           attempts = case when v_pause then greatest(0, attempts - 1) else attempts end,
           lease_token = null, lease_until = null,
           last_error = left(coalesce(p_error, ''), 500)
     where run_id = p_run_id and lease_token = p_token and state = 'leased'
    returning state)
  select count(*) filter (where state = 'failed') into v_failed from released;

  update public.icp_validation_runs
     set failed_items = failed_items + v_failed,
         cost_usd = cost_usd + coalesce((p_usage->>'cost')::numeric, 0),
         prompt_tokens = prompt_tokens + coalesce((p_usage->>'prompt_tokens')::bigint, 0),
         completion_tokens = completion_tokens + coalesce((p_usage->>'completion_tokens')::bigint, 0),
         request_count = request_count + 1,
         request_ms = request_ms + coalesce((p_usage->>'ms')::bigint, 0)
   where id = p_run_id;

  if p_pause_scope = 'run' then
    update public.icp_validation_runs
       set status = 'paused', status_message = left(coalesce(p_message, ''), 1000)
     where id = p_run_id and status in ('queued', 'running');
  elsif p_pause_scope = 'all' then
    update public.icp_validation_runs
       set status = 'paused', status_message = left(coalesce(p_message, ''), 1000)
     where status in ('queued', 'running');
  end if;

  perform public.finish_icp_validation_run_if_drained_v1(p_run_id);
  return jsonb_build_object('failed', v_failed);
end;
$$;

revoke execute on function public.fail_icp_validation_batch_v1(uuid, uuid, text, boolean, text, text, jsonb) from public, anon, authenticated;

-- The worker's capability role is created by postgres/init/00-prospect-bootstrap.sh,
-- which update.sh runs before migrations. Granted only when it exists, the
-- same way the verification worker's grants are.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'prospect_icp_validator') then
    execute 'grant usage on schema public to prospect_icp_validator';
    execute 'grant execute on function public.report_icp_worker_v1(boolean, text) to prospect_icp_validator';
    execute 'grant execute on function public.claim_icp_validation_batch_v1(text, integer) to prospect_icp_validator';
    execute 'grant execute on function public.complete_icp_validation_batch_v1(uuid, uuid, jsonb, jsonb) to prospect_icp_validator';
    execute 'grant execute on function public.fail_icp_validation_batch_v1(uuid, uuid, text, boolean, text, text, jsonb) to prospect_icp_validator';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: the whole lifecycle against a real client's companies.
-- Writes only to this feature's tables and client_icp_profiles, never to
-- clients or companies, and undoes all of it. Skipped on an empty database.
do $$
declare
  v_client text;
  v_companies text[];
  v_names text[];
  v_profile text := 'icp-validator-proof-' || gen_random_uuid();
  v_import jsonb;
  v_run jsonb;
  v_run_id uuid;
  v_claim jsonb;
  v_token uuid;
  v_done jsonb;
  v_state record;
  v_rows jsonb;
  v_cmp record;
begin
  select cc.client_id into v_client
    from public.client_companies cc
    join public.companies c on c.id = cc.company_id
   where c.normalized_name <> ''
   group by cc.client_id
  having count(*) >= 3
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP validator proof skipped: no client with three companies.';
    return;
  end if;

  begin
    -- Three companies whose names are unique within the client, so the
    -- reference import must match all three by name.
    select array_agg(id order by id), array_agg(name order by id) into v_companies, v_names
      from (select c.id, c.name
              from public.client_companies cc join public.companies c on c.id = cc.company_id
             where cc.client_id = v_client and c.normalized_name <> ''
               and c.normalized_name = lower(regexp_replace(btrim(c.name), '\s+', ' ', 'g'))
               and (select count(*) from public.client_companies cc2 join public.companies c2 on c2.id = cc2.company_id
                     where cc2.client_id = v_client and c2.normalized_name = c.normalized_name) = 1
             order by c.id limit 3) picked;
    if coalesce(array_length(v_companies, 1), 0) < 3 then
      raise exception 'proof-skip';
    end if;

    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');

    v_import := public.import_icp_reference_verdicts_v1(v_client, v_profile, 'fable', jsonb_build_array(
      jsonb_build_object('name', v_names[1], 'verdict', 'FIT', 'reason', 'r1'),
      jsonb_build_object('name', '  ' || upper(v_names[2]) || ' ', 'verdict', 'non-fit', 'reason', 'r2'),
      jsonb_build_object('name', v_names[3], 'verdict', 'FIT', 'reason', 'r3'),
      jsonb_build_object('name', 'no such company ' || gen_random_uuid(), 'verdict', 'FIT'),
      jsonb_build_object('name', v_names[1], 'verdict', 'maybe')), true);
    if (v_import->>'saved')::int <> 3 or (v_import->>'unmatched')::int <> 1 or (v_import->>'invalid')::int <> 1 then
      raise exception 'ICP proof: reference import answered %', v_import;
    end if;

    v_run := public.start_icp_validation_run_v1(v_client, v_profile, 'openai/gpt-6-luna', 'low', 'reference', 'fable', null, true, 2, null, 'proof');
    v_run_id := (v_run->>'id')::uuid;
    if (v_run->>'total_items')::int <> 3 or v_run->>'status' <> 'queued' then
      raise exception 'ICP proof: start answered %', v_run;
    end if;

    -- Other active runs on the box would be claimed first; make this one the
    -- oldest-never-claimed so the proof claims its own rows.
    update public.icp_validation_runs set created_at = '2000-01-01' where id = v_run_id;
    v_claim := public.claim_icp_validation_batch_v1('proof', 180);
    if (v_claim->>'run_id')::uuid <> v_run_id or jsonb_array_length(v_claim->'rows') <> 2 then
      raise exception 'ICP proof: claim answered %', v_claim;
    end if;
    v_token := (v_claim->>'token')::uuid;

    -- The model returns one of two rows: one saved, one back in line.
    v_done := public.complete_icp_validation_batch_v1(v_run_id, v_token, jsonb_build_array(
      jsonb_build_object('company_id', v_claim->'rows'->0->>'company_id', 'verdict', 'NON_FIT', 'reason', 'vendor')),
      '{"cost": 0.0012, "prompt_tokens": 900, "completion_tokens": 80, "ms": 1500}');
    if (v_done->>'saved')::int <> 1 then
      raise exception 'ICP proof: complete answered %', v_done;
    end if;
    select count(*) filter (where state = 'pending') as pending, count(*) filter (where state = 'done') as done
      into v_state from public.icp_validation_items where run_id = v_run_id;
    if v_state.pending <> 2 or v_state.done <> 1 then
      raise exception 'ICP proof: after complete % pending, % done', v_state.pending, v_state.done;
    end if;

    -- A bad key pauses every run and refunds the attempt: the two pending
    -- rows carry 1 + 0 attempts before the claim and must again after.
    update public.icp_validation_runs set last_claimed_at = null where id = v_run_id;
    v_claim := public.claim_icp_validation_batch_v1('proof', 180);
    v_token := (v_claim->>'token')::uuid;
    perform public.fail_icp_validation_batch_v1(v_run_id, v_token, 'http 401', true, 'all', 'OpenRouter rejected the API key.');
    if (select status from public.icp_validation_runs where id = v_run_id) <> 'paused'
       or (select sum(attempts) from public.icp_validation_items where run_id = v_run_id and state = 'pending') <> 1 then
      raise exception 'ICP proof: a paused run did not refund its rows';
    end if;
    perform public.set_icp_validation_run_state_v1(v_client, v_run_id, 'resume', 'proof');

    update public.icp_validation_runs set last_claimed_at = null where id = v_run_id;
    v_claim := public.claim_icp_validation_batch_v1('proof', 180);
    v_done := public.complete_icp_validation_batch_v1(v_run_id, (v_claim->>'token')::uuid,
      (select jsonb_agg(jsonb_build_object('company_id', r->>'company_id', 'verdict', 'FIT', 'reason', 'makes it'))
         from jsonb_array_elements(v_claim->'rows') r), '{}');
    if (select status from public.icp_validation_runs where id = v_run_id) <> 'completed' then
      raise exception 'ICP proof: a drained run did not complete: %', (select to_jsonb(r) - 'icp_text' from public.icp_validation_runs r where id = v_run_id);
    end if;

    -- Scored against the reference: the first company is FIT in the
    -- reference and NON_FIT from the model - one lost lead.
    select * into v_cmp from public.icp_verdict_comparison_v1(v_client, v_profile, 'reference:fable')
     where source = 'openai/gpt-6-luna';
    if v_cmp.compared <> 3 or v_cmp.reference_total <> 3 or v_cmp.false_non_fit + v_cmp.missed_non_fit + v_cmp.agree <> 3 then
      raise exception 'ICP proof: comparison answered %', to_jsonb(v_cmp);
    end if;

    v_rows := public.icp_verdict_rows_v1(v_client, v_profile, array['reference:fable', 'openai/gpt-6-luna'], 'disagree');
    if (v_rows->>'total')::int <> v_cmp.compared - v_cmp.agree then
      raise exception 'ICP proof: disagreement rows answered %', v_rows->'total';
    end if;

    -- Same model, same brief: a second run reuses every verdict.
    v_run := public.start_icp_validation_run_v1(v_client, v_profile, 'openai/gpt-6-luna', 'low', 'same_as', v_run_id::text);
    if (v_run->>'cached_items')::int <> 3 or v_run->>'status' <> 'completed' then
      raise exception 'ICP proof: a repeat run did not reuse verdicts: %', v_run;
    end if;

    -- An edited brief makes them stale, so they are checked again.
    update public.client_icp_profiles set description = description || ' Exclude traders.' where id = v_profile;
    v_run := public.start_icp_validation_run_v1(v_client, v_profile, 'openai/gpt-6-luna', 'low', 'unchecked');
    if (v_run->>'cached_items')::int <> 0 or (v_run->>'total_items')::int < 3 then
      raise exception 'ICP proof: an edited brief still reused verdicts: %', v_run;
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP validator proof passed and was rolled back.';
    elsif sqlerrm = 'proof-skip' then
      raise notice 'ICP validator proof skipped: no three uniquely named companies.';
    else
      raise;
    end if;
  end;
end $$;
