-- ICP checks skip companies with nothing to read.
--
-- The prompt's rule is "empty text is FIT" - right for a row whose text is thin
-- or ambiguous, wrong for a row with no text at all. Those are exactly the
-- client's Incomplete Info companies (no keywords and no short description,
-- the predicate 20260929120000 segregates them by), and on 2026-09-30 every
-- one checked so far had been labelled FIT by every model: 57 companies x 3
-- models in "Testing ICP", 171 guesses dressed as verdicts, each one paid for.
--
--   * company_has_icp_text_v1 - the same predicate, negated: the company has
--     keywords or a short description.
--   * A BEFORE INSERT guard on icp_validation_items drops any company without
--     text, so no path - All companies, sample, Validate ICP on a stale
--     selection, or one added later - can queue one. Totals count only what
--     was queued, because a dropped row is not an inserted row.
--   * The ICP Validator's "All N companies" counts only checkable companies.
--   * The labels already written on such companies are removed, and any of
--     their checks still queued are skipped.
-- A company that later gains a description or keywords leaves Incomplete
-- Info and is picked up by the next "without a current verdict" check.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.company_has_icp_text_v1(p_keywords text[], p_short_description text)
returns boolean
language sql
immutable
parallel safe
as $$
  select not (btrim(coalesce(public.tag_array_text_v1(p_keywords), '')) = ''
              and btrim(coalesce(p_short_description, '')) = '')
$$;

comment on function public.company_has_icp_text_v1(text[], text) is
  'True when a company has keywords or a short description for an ICP check to read; false exactly for Incomplete Info companies.';

create or replace function public.skip_icp_item_without_text_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.companies c
              where c.id = new.company_id
                and not public.company_has_icp_text_v1(c.keywords, c.short_description)) then
    return null;
  end if;
  return new;
end;
$$;

revoke execute on function public.skip_icp_item_without_text_v1() from public, anon, authenticated;

create or replace trigger skip_icp_item_without_text
  before insert on public.icp_validation_items
  for each row execute function public.skip_icp_item_without_text_v1();

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

-- ---------------------------------------------------------------------------
-- Proof, rolled back: a run over one company with text and one without queues
-- only the first.
do $$
declare
  v_client text;
  v_with text;
  v_without text;
  v_profile text := 'icp-no-text-proof-' || gen_random_uuid();
  v_run jsonb;
begin
  select cc.client_id, min(cc.company_id) filter (where public.company_has_icp_text_v1(c.keywords, c.short_description)),
         min(cc.company_id) filter (where not public.company_has_icp_text_v1(c.keywords, c.short_description))
    into v_client, v_with, v_without
    from public.client_companies cc join public.companies c on c.id = cc.company_id
   group by cc.client_id
  having count(*) filter (where public.company_has_icp_text_v1(c.keywords, c.short_description)) > 0
     and count(*) filter (where not public.company_has_icp_text_v1(c.keywords, c.short_description)) > 0
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP no-text proof skipped: no client with both kinds of company.';
    return;
  end if;

  begin
    insert into public.client_icp_profiles (id, client_id, name, description)
    values (v_profile, v_client, 'Proof', 'Companies that manufacture fertilizer.');
    v_run := public.start_icp_validation_selection_v1(v_client, v_profile, array['openai/gpt-6-luna'], 'low',
      array[v_with, v_without], '', '[]'::jsonb, null, null, false, 'proof');
    if (v_run->'runs'->0->>'total_items')::int <> 1
       or exists (select 1 from public.icp_validation_items i join public.icp_validation_runs r on r.id = i.run_id
                   where r.icp_profile_id = v_profile and i.company_id = v_without) then
      raise exception 'ICP no-text proof: a company without text was queued: %', v_run;
    end if;
    begin
      perform public.start_icp_validation_selection_v1(v_client, v_profile, array['openai/gpt-6-luna'], 'low',
        array[v_without], '', '[]'::jsonb, null, null, false, 'proof');
      raise exception 'ICP no-text proof: a run of only textless companies started';
    exception when sqlstate 'P0002' then null;
    end;
    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP no-text proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Remove the labels already written on companies without text, and skip their
-- queued checks. Only this feature's labels; the companies are untouched.
do $$
declare
  v_labels integer;
  v_items integer;
begin
  delete from public.client_company_icp_verdicts v
   using public.companies c
   where c.id = v.company_id
     and not public.company_has_icp_text_v1(c.keywords, c.short_description);
  get diagnostics v_labels = row_count;

  update public.icp_validation_items i
     set state = 'skipped', last_error = 'No description or keywords to judge.'
    from public.companies c
   where c.id = i.company_id and i.state = 'pending'
     and not public.company_has_icp_text_v1(c.keywords, c.short_description);
  get diagnostics v_items = row_count;

  raise notice 'Removed % ICP labels on companies without text; skipped % queued checks.', v_labels, v_items;
end $$;
