-- Clear the ICP check on a Company DB selection.
--
-- The Company DB's "Validate ICP" puts FIT / NON_FIT labels on companies; this
-- takes them off again for the same kind of selection - ticked rows, or all
-- matching the current search and filters - resolved by the same
-- resolve_company_action_selection_v1 in the same client scope.
--
-- Clearing has to stick: a check still queued for one of these companies would
-- put its label straight back, so those pending rows are skipped too. A batch
-- already at the model when this runs is paid for and still lands.
--
-- Only this feature's labels are removed. Companies, clients, and the manual
-- "ICP verified" are not touched; run history (counts, cost) is kept.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.clear_icp_verdicts_selection_v1(
  p_client_id text,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_icp_profile_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_cleared integer := 0;
  v_skipped integer := 0;
  v_run uuid;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  if p_icp_profile_id is not null and not exists (
    select 1 from public.client_icp_profiles where id = p_icp_profile_id and client_id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;

  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
    from public.resolve_company_action_selection_v1(
      p_client_id, p_company_ids, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb),
      p_people_scope, p_excluded_ids, 250000);
  if cardinality(v_ids) = 0 then
    return jsonb_build_object('selected', 0, 'cleared', 0, 'skipped', 0);
  end if;

  delete from public.client_company_icp_verdicts
   where client_id = p_client_id
     and company_id = any(v_ids)
     and (p_icp_profile_id is null or icp_profile_id = p_icp_profile_id);
  get diagnostics v_cleared = row_count;

  for v_run in
    select r.id from public.icp_validation_runs r
     where r.client_id = p_client_id
       and r.status in ('queued', 'running', 'paused')
       and (p_icp_profile_id is null or r.icp_profile_id = p_icp_profile_id)
     order by r.id
     for update
  loop
    with skipped as (
      update public.icp_validation_items
         set state = 'skipped', last_error = 'ICP check cleared for this company.'
       where run_id = v_run and state = 'pending' and company_id = any(v_ids)
      returning 1)
    select v_skipped + count(*) into v_skipped from skipped;
    perform public.finish_icp_validation_run_if_drained_v1(v_run);
  end loop;

  return jsonb_build_object('selected', cardinality(v_ids), 'cleared', v_cleared, 'skipped', v_skipped);
end;
$$;

revoke execute on function public.clear_icp_verdicts_selection_v1(text, text[], text, jsonb, jsonb, text[], text) from public, anon, authenticated;
grant execute on function public.clear_icp_verdicts_selection_v1(text, text[], text, jsonb, jsonb, text[], text) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: two labelled companies, one queued check; clearing one
-- company removes only its labels and skips only its queued row.
do $$
declare
  v_client text;
  v_companies text[];
  v_profile text := 'icp-clear-proof-' || gen_random_uuid();
  v_run jsonb;
  v_result jsonb;
begin
  select cc.client_id into v_client
    from public.client_companies cc
   group by cc.client_id
  having count(*) >= 2
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP clear proof skipped: no client with two companies.';
    return;
  end if;

  begin
    select array_agg(company_id order by company_id) into v_companies
      from (select company_id from public.client_companies where client_id = v_client order by company_id limit 2) picked;
    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');
    insert into public.client_company_icp_verdicts (client_id, icp_profile_id, source, company_id, verdict, icp_hash)
    select v_client, v_profile, source, company_id, 'FIT', md5('Companies that manufacture fertilizer.')
      from unnest(v_companies) company_id cross join unnest(array['openai/gpt-6-luna', 'xiaomi/mimo-v2.6-flash']) source;
    v_run := public.start_icp_validation_selection_v1(v_client, v_profile, array['deepseek/deepseek-v4.1-flash'], 'low',
      v_companies, '', '[]'::jsonb, null, null, true, 'proof');

    -- Scoped to the proof ICP: a real client can already carry real labels.
    v_result := public.clear_icp_verdicts_selection_v1(v_client, v_companies[1:1], '', '[]'::jsonb, null, null, v_profile);
    if (v_result->>'selected')::int <> 1 or (v_result->>'cleared')::int <> 2 or (v_result->>'skipped')::int <> 1 then
      raise exception 'ICP clear proof: clear answered %', v_result;
    end if;
    if (select count(*) from public.client_company_icp_verdicts where icp_profile_id = v_profile) <> 2
       or exists (select 1 from public.client_company_icp_verdicts where icp_profile_id = v_profile and company_id = v_companies[1]) then
      raise exception 'ICP clear proof: the wrong labels were removed';
    end if;
    if (select count(*) from public.icp_validation_items i join public.icp_validation_runs r on r.id = i.run_id
         where r.icp_profile_id = v_profile and i.state = 'pending') <> 1 then
      raise exception 'ICP clear proof: the other company''s queued check was skipped too';
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP clear proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
