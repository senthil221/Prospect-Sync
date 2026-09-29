-- ICP validation straight from a Company DB selection.
--
-- Until now the operator exported the client's companies ("Export for ICP
-- validation"), ran them through a model elsewhere, and read the answers
-- back by hand. This lets the same selection - ticked rows, or "all N
-- matching" these filters - be queued for the ICP worker directly, and puts
-- the verdicts back on the Company DB rows.
--
--   start_icp_validation_selection_v1  resolves the selection ONCE with
--       resolve_company_action_selection_v1 (the resolver push, tagging and
--       Mark ICP verified already use, same client scope and cap) and queues
--       one run per chosen model over exactly those companies.
--   icp_verdict_labels_v1  the verdicts for one page of Company DB rows.
--
-- Still a label: nothing here writes to companies, clients or the manual
-- ICP verification.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

alter table public.icp_validation_runs drop constraint if exists icp_validation_runs_scope_check;
alter table public.icp_validation_runs add constraint icp_validation_runs_scope_check
  check (scope in ('all', 'unchecked', 'reference', 'sample', 'same_as', 'selection'));

-- Internal: one run over a given list of the client's companies.
create or replace function public.enqueue_icp_validation_run_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_model text,
  p_reasoning_effort text,
  p_scope text,
  p_scope_detail text,
  p_company_ids text[],
  p_reuse boolean,
  p_bake_off_id uuid,
  p_created_by text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.client_icp_profiles%rowtype;
  v_run_id uuid := gen_random_uuid();
  v_hash text;
  v_total integer;
  v_cached integer := 0;
  v_fit integer := 0;
  v_non_fit integer := 0;
begin
  select * into v_profile from public.client_icp_profiles
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
  v_hash := md5(v_profile.description);

  insert into public.icp_validation_runs (
    id, client_id, icp_profile_id, icp_name, icp_text, icp_hash, model, reasoning_effort,
    scope, scope_detail, batch_size, bake_off_id, created_by)
  values (
    v_run_id, p_client_id, p_icp_profile_id, v_profile.name, v_profile.description, v_hash, p_model,
    coalesce(nullif(p_reasoning_effort, ''), 'low'), p_scope, coalesce(p_scope_detail, ''), 20,
    p_bake_off_id, coalesce(p_created_by, ''));

  -- Only companies that exist; order is the selection's order.
  insert into public.icp_validation_items (run_id, company_id, position)
  select v_run_id, ids.company_id, min(ids.ord)
    from unnest(p_company_ids) with ordinality as ids(company_id, ord)
    join public.companies c on c.id = ids.company_id
   group by ids.company_id;
  get diagnostics v_total = row_count;
  if v_total = 0 then
    raise exception using errcode = 'P0002', message = 'There are no companies to check.';
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

revoke execute on function public.enqueue_icp_validation_run_v1(text, text, text, text, text, text, text[], boolean, uuid, text) from public, anon, authenticated;

-- App: validate a Company DB selection with one to three models. Every model
-- gets the same companies - the selection is resolved once.
create or replace function public.start_icp_validation_selection_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_models text[],
  p_reasoning_effort text default 'low',
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_reuse boolean default true,
  p_created_by text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_models text[];
  v_model text;
  v_runs jsonb := '[]'::jsonb;
  v_bake_off uuid;
  v_max constant integer := 100000;
begin
  if not exists (select 1 from public.client_icp_profiles where id = p_icp_profile_id and client_id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;
  select coalesce(array_agg(distinct m), array[]::text[]) into v_models
    from unnest(coalesce(p_models, array[]::text[])) m where btrim(m) <> '';
  if cardinality(v_models) not between 1 and 3 then
    raise exception using errcode = '22023', message = 'Choose one to three models.';
  end if;
  -- Without ids and without a filter, "all matching" is the whole client -
  -- which is allowed, and is what the ICP Validator tab's "All companies" does.
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
    from public.resolve_company_action_selection_v1(
      p_client_id, p_company_ids, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb),
      p_people_scope, p_excluded_ids, v_max + 1);
  if cardinality(v_ids) = 0 then
    raise exception using errcode = 'P0002', message = 'None of the selected companies are in this client.';
  end if;
  if cardinality(v_ids) > v_max then
    raise exception using errcode = '22023', message = 'Validate at most 100,000 companies at a time. Narrow the selection with a filter.';
  end if;

  v_bake_off := case when cardinality(v_models) > 1 then gen_random_uuid() end;
  foreach v_model in array v_models loop
    v_runs := v_runs || jsonb_build_array(public.enqueue_icp_validation_run_v1(
      p_client_id, p_icp_profile_id, v_model, p_reasoning_effort, 'selection',
      cardinality(v_ids)::text, v_ids, coalesce(p_reuse, true), v_bake_off, p_created_by));
  end loop;

  return jsonb_build_object('selected', cardinality(v_ids), 'runs', v_runs);
end;
$$;

revoke execute on function public.start_icp_validation_selection_v1(text, text, text[], text, text[], text, jsonb, jsonb, text[], boolean, text) from public, anon, authenticated;
grant execute on function public.start_icp_validation_selection_v1(text, text, text[], text, text[], text, jsonb, jsonb, text[], boolean, text) to service_role;

-- App: the verdicts on one page of Company DB rows, every ICP and source.
create or replace function public.icp_verdict_labels_v1(p_client_id text, p_company_ids text[])
returns table (
  company_id text, icp_profile_id text, icp_name text, source text,
  verdict text, reason text, current boolean, decided_at timestamptz
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '10s'
as $$
  select v.company_id, v.icp_profile_id, p.name, v.source, v.verdict, v.reason,
         v.source like 'reference:%' or v.icp_hash = md5(p.description), v.decided_at
    from public.client_company_icp_verdicts v
    join public.client_icp_profiles p on p.id = v.icp_profile_id
   where v.client_id = p_client_id
     and v.company_id = any((coalesce(p_company_ids, array[]::text[]))[1:200])
   order by v.company_id, p.sort_order, p.id, v.source
$$;

revoke execute on function public.icp_verdict_labels_v1(text, text[]) from public, anon, authenticated;
grant execute on function public.icp_verdict_labels_v1(text, text[]) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: a two-company selection with two models queues two runs
-- over the same two companies, reuses a verdict it already has, and the
-- labels read them back.
do $$
declare
  v_client text;
  v_companies text[];
  v_profile text := 'icp-selection-proof-' || gen_random_uuid();
  v_result jsonb;
  v_labels integer;
begin
  select cc.client_id into v_client
    from public.client_companies cc
   group by cc.client_id
  having count(*) >= 2
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP selection proof skipped: no client with two companies.';
    return;
  end if;

  begin
    select array_agg(company_id order by company_id) into v_companies
      from (select company_id from public.client_companies where client_id = v_client order by company_id limit 2) picked;
    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');
    insert into public.client_company_icp_verdicts (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash)
    values (v_client, v_profile, 'openai/gpt-6-luna', v_companies[1], 'NON_FIT', 'earlier', md5('Companies that manufacture fertilizer.'));

    v_result := public.start_icp_validation_selection_v1(
      v_client, v_profile, array['openai/gpt-6-luna', 'xiaomi/mimo-v2.6-flash', 'openai/gpt-6-luna'], 'low',
      v_companies || array['not-a-company-' || gen_random_uuid()], '', '[]'::jsonb, null, null, true, 'proof');
    if (v_result->>'selected')::int <> 2 or jsonb_array_length(v_result->'runs') <> 2 then
      raise exception 'ICP selection proof: start answered %', v_result;
    end if;
    if (select count(*) from public.icp_validation_items i
          join public.icp_validation_runs r on r.id = i.run_id
         where r.icp_profile_id = v_profile and r.scope = 'selection') <> 4 then
      raise exception 'ICP selection proof: expected two companies per run';
    end if;
    if (select cached_items from public.icp_validation_runs
         where icp_profile_id = v_profile and model = 'openai/gpt-6-luna') <> 1 then
      raise exception 'ICP selection proof: the earlier verdict was not reused';
    end if;

    select count(*) into v_labels from public.icp_verdict_labels_v1(v_client, v_companies);
    if v_labels <> 1 then
      raise exception 'ICP selection proof: labels answered % rows', v_labels;
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP selection proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
