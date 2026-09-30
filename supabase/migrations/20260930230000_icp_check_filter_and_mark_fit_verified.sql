-- ICP check results where the work happens: a Company DB filter, and one step
-- from FIT to ICP verified.
--
--   * Company filter __company_icp_check. Values are '<client id>|<state>',
--     state FIT, NON_FIT or UNCHECKED; several values are OR'd, not_contains
--     negates. A company's result for a client is the latest current ICP
--     check (strategy) label of each of the client's ICPs - current meaning it
--     was judged against the brief as it is now. FIT matches if any ICP's latest
--     result is FIT (clients mostly have one ICP); UNCHECKED means no current
--     result for any ICP. Compiled by company_filter_sql_v3 and matched by
--     company_matches_filters_v1, like __company_tags, through one helper so
--     the two can never disagree. The client Company DB reads only the client's
--     own companies, so this is one probe of idx_client_company_icp_verdicts_by_company
--     per row there.
--   * mark_icp_check_fit_verified_v1: the FIT companies of one check become
--     ICP verified for the client through set_company_icp_verified_v2 - the
--     same path as the Company DB's "Mark ICP verified", so prospects follow.
--     NON_FIT stays a label. The check records who did it and how many.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.company_icp_check_matches_v1(p_company_id text, p_client_id text, p_state text)
returns boolean
language sql
stable
-- No SET clause, so the planner can inline it into the filter (every name is
-- schema-qualified).
as $$
  select case upper(coalesce(p_state, ''))
    when 'UNCHECKED' then not exists (
      select 1
        from public.client_company_icp_verdicts v
        join public.client_icp_profiles p on p.id = v.icp_profile_id
       where v.company_id = p_company_id and v.client_id = p_client_id
         and v.source like 'strategy:%' and v.icp_hash = md5(p.description))
    when 'FIT' then exists (
      select 1 from (
        select distinct on (v.icp_profile_id) v.verdict
          from public.client_company_icp_verdicts v
          join public.client_icp_profiles p on p.id = v.icp_profile_id
         where v.company_id = p_company_id and v.client_id = p_client_id
           and v.source like 'strategy:%' and v.icp_hash = md5(p.description)
         order by v.icp_profile_id, v.decided_at desc) latest
       where latest.verdict = 'FIT')
    when 'NON_FIT' then exists (
      select 1 from (
        select distinct on (v.icp_profile_id) v.verdict
          from public.client_company_icp_verdicts v
          join public.client_icp_profiles p on p.id = v.icp_profile_id
         where v.company_id = p_company_id and v.client_id = p_client_id
           and v.source like 'strategy:%' and v.icp_hash = md5(p.description)
         order by v.icp_profile_id, v.decided_at desc) latest
       where latest.verdict = 'NON_FIT')
    else false end
$$;

comment on function public.company_icp_check_matches_v1(text, text, text) is
  'Company DB filter __company_icp_check: does this company''s latest current ICP check result for the client match FIT, NON_FIT or UNCHECKED.';

revoke execute on function public.company_icp_check_matches_v1(text, text, text) from public, anon, authenticated;
grant execute on function public.company_icp_check_matches_v1(text, text, text) to service_role;

do $patch_filters$
declare
  v_definition text;
  v_rewritten text;
begin
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  if position('__company_icp_check' in v_definition) = 0 then
    v_rewritten := replace(v_definition,
      $old$      if field_key = '__company_tags' then$old$,
      $new$      if field_key = '__company_icp_check' then
        if cardinality(raw_values) = 0 then continue; end if;
        value_parts := array(select format('public.company_icp_check_matches_v1(c.id, %L, %L)',
                                           split_part(v, '|', 1), split_part(v, '|', 2)) from unnest(raw_values) v);
        conjuncts := conjuncts || format('(%s(%s))',
          case when operator_key in ('not_contains', 'not_equals') then 'not ' else '' end,
          array_to_string(value_parts, ' or '));
        continue;
      end if;
      if field_key = '__company_tags' then$new$);
    if v_rewritten = v_definition then raise exception 'Could not patch company_filter_sql_v3 for __company_icp_check'; end if;
    execute v_rewritten;
  end if;

  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  if position('__company_icp_check' in v_definition) = 0 then
    v_rewritten := replace(v_definition,
      $old$      when filter_item->>'field' = '__company_tags' then ($old$,
      $new$      when filter_item->>'field' = '__company_icp_check' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from jsonb_array_elements_text(filter_item->'values') selected(value)
                  where public.company_icp_check_matches_v1((p_row).id, split_part(selected.value, '|', 1),
                                                            split_part(selected.value, '|', 2)))))
      )
      when filter_item->>'field' = '__company_tags' then ($new$);
    if v_rewritten = v_definition then raise exception 'Could not patch company_matches_filters_v1 for __company_icp_check'; end if;
    execute v_rewritten;
  end if;
end;
$patch_filters$;

-- ---------------------------------------------------------------------------
alter table public.icp_strategy_checks
  add column if not exists verified_at timestamptz,
  add column if not exists verified_by text not null default '',
  add column if not exists verified_items integer not null default 0;

create or replace function public.mark_icp_check_fit_verified_v1(p_client_id text, p_check_id uuid, p_actor text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_result jsonb;
begin
  if not exists (select 1 from public.icp_strategy_checks where id = p_check_id and client_id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'That check does not belong to this client.';
  end if;
  select coalesce(array_agg(company_id order by position), array[]::text[]) into v_ids
    from public.icp_strategy_results
   where check_id = p_check_id and verdict = 'FIT';
  if cardinality(v_ids) = 0 then
    raise exception using errcode = '22023', message = 'This check has no FIT companies yet.';
  end if;

  v_result := public.set_company_icp_verified_v2(p_client_id, true, v_ids, '', '[]'::jsonb, null, null, p_actor);

  update public.icp_strategy_checks
     set verified_at = now(), verified_by = left(coalesce(p_actor, ''), 200), verified_items = cardinality(v_ids)
   where id = p_check_id;
  return v_result || jsonb_build_object('fit', cardinality(v_ids));
end;
$$;

revoke execute on function public.mark_icp_check_fit_verified_v1(text, uuid, text) from public, anon, authenticated;
grant execute on function public.mark_icp_check_fit_verified_v1(text, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: three companies - one FIT, one NON_FIT, one unchecked -
-- through the compiled filter and the row matcher alike; a newer NON_FIT
-- overrides an older FIT; a label on an edited brief does not count; and a
-- check's FIT companies become ICP verified.
do $$
declare
  v_client text;
  v_companies text[];
  v_profile text := 'icp-filter-proof-' || gen_random_uuid();
  v_brief text := 'Companies that manufacture fertilizer.';
  v_sql text;
  v_count integer;
  v_matches integer;
  v_check jsonb;
  v_check_id uuid;
  v_run uuid;
  v_token uuid;
  v_result jsonb;
  f jsonb;
begin
  select cc.client_id into v_client
    from public.client_companies cc join public.companies c on c.id = cc.company_id
   where public.company_has_icp_text_v1(c.keywords, c.short_description)
     and not exists (select 1 from public.client_company_icp_verdicts v where v.client_id = cc.client_id and v.company_id = cc.company_id)
     and not exists (select 1 from public.client_company_icp_validations iv where iv.client_id = cc.client_id and iv.company_id = cc.company_id)
   group by cc.client_id
  having count(*) >= 3
   order by count(*)
   limit 1;
  if v_client is null then
    raise notice 'ICP filter proof skipped: no client with three unlabelled checkable companies.';
    return;
  end if;

  begin
    select array_agg(company_id order by company_id) into v_companies
      from (select cc.company_id from public.client_companies cc join public.companies c on c.id = cc.company_id
             where cc.client_id = v_client and public.company_has_icp_text_v1(c.keywords, c.short_description)
               and not exists (select 1 from public.client_company_icp_verdicts v where v.client_id = cc.client_id and v.company_id = cc.company_id)
               and not exists (select 1 from public.client_company_icp_validations iv where iv.client_id = cc.client_id and iv.company_id = cc.company_id)
             order by cc.company_id limit 3) picked;
    insert into public.client_icp_profiles (id, client_id, name, description) values (v_profile, v_client, 'Proof', v_brief);
    insert into public.client_company_icp_verdicts (client_id, icp_profile_id, source, company_id, verdict, reason, icp_hash, decided_at) values
      (v_client, v_profile, 'strategy:lenient', v_companies[1], 'FIT', '', md5(v_brief), now() - interval '1 hour'),
      (v_client, v_profile, 'strategy:balanced', v_companies[2], 'FIT', '', md5(v_brief), now() - interval '1 hour'),
      (v_client, v_profile, 'strategy:strict', v_companies[2], 'NON_FIT', '', md5(v_brief), now()),
      -- judged against an older brief: does not count
      (v_client, v_profile, 'strategy:strict', v_companies[3], 'FIT', '', md5('an older brief'), now());

    foreach f in array array[
      jsonb_build_object('state', 'FIT', 'want', 1),
      jsonb_build_object('state', 'NON_FIT', 'want', 1),
      jsonb_build_object('state', 'UNCHECKED', 'want', 1)] loop
      v_sql := public.company_effective_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
        'field', '__company_icp_check', 'operator', 'contains', 'values', jsonb_build_array(v_client || '|' || (f->>'state')))));
      execute format('select count(*) from public.companies c where c.id = any($1) and %s', v_sql) into v_count using v_companies;
      select count(*) into v_matches from public.companies c
       where c.id = any(v_companies)
         and public.company_matches_filters_v1(c, '', jsonb_build_array(jsonb_build_object(
               'field', '__company_icp_check', 'operator', 'contains', 'values', jsonb_build_array(v_client || '|' || (f->>'state')))));
      if v_count <> (f->>'want')::int or v_matches <> v_count then
        raise exception 'ICP filter proof: % compiled % / matched %, wanted %', f->>'state', v_count, v_matches, f->>'want';
      end if;
    end loop;
    -- Negated, and several values OR'd.
    v_sql := public.company_effective_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__company_icp_check', 'operator', 'not_contains', 'values', jsonb_build_array(v_client || '|FIT'))));
    execute format('select count(*) from public.companies c where c.id = any($1) and %s', v_sql) into v_count using v_companies;
    if v_count <> 2 then raise exception 'ICP filter proof: not FIT counted %', v_count; end if;
    v_sql := public.company_effective_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__company_icp_check', 'operator', 'contains', 'values', jsonb_build_array(v_client || '|FIT', v_client || '|UNCHECKED'))));
    execute format('select count(*) from public.companies c where c.id = any($1) and %s', v_sql) into v_count using v_companies;
    if v_count <> 2 then raise exception 'ICP filter proof: FIT or unchecked counted %', v_count; end if;

    -- Mark FIT verified: a Strict check where company 1 is FIT and company 2 NON_FIT.
    v_check := public.start_icp_strategy_check_v2(v_client, v_profile, 'strict', 'selection', v_companies[1:2],
      '', '[]'::jsonb, null, null, true, 'cheapest', 'proof');
    v_check_id := (v_check->>'id')::uuid;
    for v_run in select id from public.icp_validation_runs where strategy_check_id = v_check_id order by pass_no loop
      v_token := gen_random_uuid();
      update public.icp_validation_items set state = 'leased', lease_token = v_token, attempts = 1 where run_id = v_run;
      perform public.complete_icp_validation_batch_v1(v_run, v_token, jsonb_build_array(
        jsonb_build_object('company_id', v_companies[1], 'verdict', 'FIT', 'reason', 'r'),
        jsonb_build_object('company_id', v_companies[2], 'verdict', 'NON_FIT', 'reason', 'r')), '{}'::jsonb);
    end loop;
    v_result := public.mark_icp_check_fit_verified_v1(v_client, v_check_id, 'proof');
    if (v_result->>'fit')::int <> 1
       or not exists (select 1 from public.client_company_icp_validations where client_id = v_client and company_id = v_companies[1])
       or exists (select 1 from public.client_company_icp_validations where client_id = v_client and company_id = v_companies[2])
       or (select verified_items from public.icp_strategy_checks where id = v_check_id) <> 1 then
      raise exception 'ICP filter proof: marking FIT verified answered %', v_result;
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'ICP check filter proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
