\set ON_ERROR_STOP on

-- Synthetic only: this fixture writes representative memberships and must
-- never run against the application database.
do $$
begin
  if current_database() not in ('schema_check', 'cursor_migration_test') then
    raise exception 'Refusing to run incomplete-info fixture outside a named disposable database.';
  end if;
end $$;

insert into public.clients(id, name, normalized_name)
values
  ('segregation-source', 'Segregation Source', 'segregation source'),
  ('segregation-destination', 'Segregation Destination', 'segregation destination');

insert into public.companies(id, name, normalized_name, domain, normalized_domain, keywords, short_description)
values
  ('segregation-incomplete-company', 'Incomplete Fixture Co', 'incomplete fixture co', 'incomplete-fixture.test', 'incomplete-fixture.test', '{}'::text[], ''),
  ('segregation-complete-company', 'Complete Fixture Co', 'complete fixture co', 'complete-fixture.test', 'complete-fixture.test', '{}'::text[], 'A usable profile'),
  ('segregation-outsider-incomplete-company', 'Outsider Incomplete Fixture Co', 'outsider incomplete fixture co', 'outsider-incomplete-fixture.test', 'outsider-incomplete-fixture.test', '{}'::text[], ''),
  ('segregation-outsider-complete-company', 'Outsider Complete Fixture Co', 'outsider complete fixture co', 'outsider-complete-fixture.test', 'outsider-complete-fixture.test', '{}'::text[], 'Another usable profile');

insert into public.prospects(id, full_name, work_email, company_id)
values
  ('segregation-incomplete-person', 'Incomplete Fixture Person', 'incomplete@fixture.test', 'segregation-incomplete-company'),
  ('segregation-complete-person', 'Complete Fixture Person', 'complete@fixture.test', 'segregation-complete-company'),
  ('segregation-unlinked-person', 'Unlinked Fixture Person', 'unlinked@fixture.test', null);
select public.reindex_prospects(array[
  'segregation-incomplete-person', 'segregation-complete-person', 'segregation-unlinked-person'
]);

-- Exercise the real push path. The incomplete records keep their memberships;
-- the read partition decides which client tab owns them.
select public.push_prospects_to_client_v2(
  p_client_id => 'segregation-destination',
  p_prospect_ids => array['segregation-incomplete-person','segregation-complete-person','segregation-unlinked-person'],
  p_actor => 'fixture', p_request_id => 'segregation-people-push');
select public.push_companies_to_client_v2(
  p_client_id => 'segregation-destination',
  p_company_ids => array['segregation-incomplete-company','segregation-complete-company'],
  p_actor => 'fixture', p_request_id => 'segregation-company-push');
update public.client_prospects
set icp_verified = true
where client_id = 'segregation-destination'
  and prospect_id in ('segregation-incomplete-person', 'segregation-complete-person');

do $$
declare
  v_incomplete jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb;
  v_complete jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb;
  v_company_membership jsonb := '[{"field":"__company_client_ids","operator":"contains","values":["segregation-destination"]}]'::jsonb;
  v_people_incomplete record;
  v_people_complete record;
  v_companies_incomplete record;
  v_companies_complete record;
  v_companies_incomplete_master record;
  v_companies_complete_master record;
  v_incomplete_people text[];
  v_complete_people text[];
  v_incomplete_companies text[];
  v_complete_companies text[];
  v_master_people text[];
  v_master_people_set text[];
  v_people_complete_set text[];
  v_people_incomplete_set text[];
  v_companies_complete_set text[];
  v_companies_incomplete_set text[];
  v_companies_complete_master_ids text[];
  v_companies_incomplete_master_ids text[];
  v_requested record;
  v_built record;
  v_master record;
  v_summary record;
begin
  select * into v_people_incomplete from public.search_prospect_workspace_v13(
    '', v_incomplete, 'created_at', 'desc', 50, 0,
    'segregation-destination', '{}'::jsonb, true, null);
  select * into v_people_complete from public.search_prospect_workspace_v13(
    '', v_complete, 'created_at', 'desc', 50, 0,
    'segregation-destination', '{}'::jsonb, true, null);
  select coalesce(array_agg(row->>'id' order by row->>'id'), '{}'::text[])
    into v_incomplete_people from jsonb_array_elements(v_people_incomplete.result_rows) row;
  select coalesce(array_agg(row->>'id' order by row->>'id'), '{}'::text[])
    into v_complete_people from jsonb_array_elements(v_people_complete.result_rows) row;
  if v_incomplete_people is distinct from array['segregation-incomplete-person']::text[]
    or v_complete_people is distinct from array['segregation-complete-person','segregation-unlinked-person']::text[] then
    raise exception 'People partition mismatch. incomplete %, complete %', v_incomplete_people, v_complete_people;
  end if;
  if v_incomplete_people && v_complete_people or cardinality(v_incomplete_people) + cardinality(v_complete_people) <> 3 then
    raise exception 'People partitions overlap or do not cover the client membership.';
  end if;

  select * into v_companies_incomplete from public.client_company_workspace_v2(
    'segregation-destination', 'Fixture Co', v_incomplete, null, 50, 0);
  select * into v_companies_complete from public.client_company_workspace_v2(
    'segregation-destination', 'Fixture Co', v_complete, null, 50, 0);
  select coalesce(array_agg(row->>'id' order by row->>'id'), '{}'::text[])
    into v_incomplete_companies from jsonb_array_elements(v_companies_incomplete.result_rows) row;
  select coalesce(array_agg(row->>'id' order by row->>'id'), '{}'::text[])
    into v_complete_companies from jsonb_array_elements(v_companies_complete.result_rows) row;
  if v_incomplete_companies is distinct from array['segregation-incomplete-company']::text[]
    or v_complete_companies is distinct from array['segregation-complete-company']::text[] then
    raise exception 'Company partition mismatch. incomplete %, complete %', v_incomplete_companies, v_complete_companies;
  end if;
  if v_incomplete_companies && v_complete_companies or cardinality(v_incomplete_companies) + cardinality(v_complete_companies) <> 2 then
    raise exception 'Company partitions overlap or do not cover the client membership.';
  end if;

  -- Freeze the same final predicates the API hands to the result-set worker.
  -- Ordinary client tabs do not send the hidden complete predicate themselves;
  -- the route adds v_complete before authorization, hashing and this request.
  -- Explicit Incomplete Info keeps v_incomplete. Build the actual result sets
  -- and compare their stored ids with the interactive reads above.
  select * into v_requested from public.request_result_set_v1(
    'segregation-fixture-owner', 'prospect', 'segregation-destination', '',
    v_complete, 'segregation-people-complete', null, '{}'::jsonb);
  loop
    select * into v_built from prospect_results.build_batch_v1(v_requested.set_id, 1000);
    exit when v_built.done;
  end loop;
  select coalesce(array_agg(entity_id order by entity_id), '{}'::text[])
    into v_people_complete_set
    from prospect_results.result_set_items where result_set_id = v_requested.set_id;
  if v_people_complete_set is distinct from v_complete_people then
    raise exception 'Complete client People result set differs from the interactive workspace: set %, workspace %',
      v_people_complete_set, v_complete_people;
  end if;
  if (select row_count from prospect_results.result_sets where id = v_requested.set_id)
      <> cardinality(v_complete_people) then
    raise exception 'Complete client People result-set count differs from the interactive workspace.';
  end if;

  select * into v_requested from public.request_result_set_v1(
    'segregation-fixture-owner', 'prospect', 'segregation-destination', '',
    v_incomplete, 'segregation-people-incomplete', null, '{}'::jsonb);
  loop
    select * into v_built from prospect_results.build_batch_v1(v_requested.set_id, 1000);
    exit when v_built.done;
  end loop;
  select coalesce(array_agg(entity_id order by entity_id), '{}'::text[])
    into v_people_incomplete_set
    from prospect_results.result_set_items where result_set_id = v_requested.set_id;
  if v_people_incomplete_set is distinct from v_incomplete_people then
    raise exception 'Incomplete client People result set differs from the interactive workspace: set %, workspace %',
      v_people_incomplete_set, v_incomplete_people;
  end if;
  if (select row_count from prospect_results.result_sets where id = v_requested.set_id)
      <> cardinality(v_incomplete_people) then
    raise exception 'Incomplete client People result-set count differs from the interactive workspace.';
  end if;

  -- The durable Company builder compiles filters but does not independently
  -- consume client_scope. The API normalizes client membership into the same
  -- __company_client_ids filter already used by streamed company exports. The
  -- outsider controls prove that this final filter cannot widen to another
  -- client while preserving the complete/incomplete profile predicate.
  select * into v_companies_complete_master from public.filter_companies_v4(
    'Fixture Co', v_complete, null, null, 50, 0);
  select coalesce(array_agg(row->>'id' order by row->>'id'), '{}'::text[])
    into v_companies_complete_master_ids
    from jsonb_array_elements(v_companies_complete_master.result_rows) row;
  if v_companies_complete_master_ids is distinct from array[
      'segregation-complete-company', 'segregation-outsider-complete-company']::text[] then
    raise exception 'Master complete Company control did not include both client and outsider rows: %',
      v_companies_complete_master_ids;
  end if;
  select * into v_requested from public.request_result_set_v1(
    'segregation-fixture-owner', 'company', 'segregation-destination', 'Fixture Co',
    v_complete || v_company_membership, 'segregation-companies-complete', null, '{}'::jsonb);
  loop
    select * into v_built from prospect_results.build_batch_v1(v_requested.set_id, 1000);
    exit when v_built.done;
  end loop;
  select coalesce(array_agg(entity_id order by entity_id), '{}'::text[])
    into v_companies_complete_set
    from prospect_results.result_set_items where result_set_id = v_requested.set_id;
  if v_companies_complete_set is distinct from v_complete_companies then
    raise exception 'Complete client Company result set differs from the interactive workspace: set %, workspace %',
      v_companies_complete_set, v_complete_companies;
  end if;
  if (select row_count from prospect_results.result_sets where id = v_requested.set_id)
      <> cardinality(v_complete_companies) then
    raise exception 'Complete client Company result-set count differs from the interactive workspace.';
  end if;

  select * into v_companies_incomplete_master from public.filter_companies_v4(
    'Fixture Co', v_incomplete, null, null, 50, 0);
  select coalesce(array_agg(row->>'id' order by row->>'id'), '{}'::text[])
    into v_companies_incomplete_master_ids
    from jsonb_array_elements(v_companies_incomplete_master.result_rows) row;
  if v_companies_incomplete_master_ids is distinct from array[
      'segregation-incomplete-company', 'segregation-outsider-incomplete-company']::text[] then
    raise exception 'Master incomplete Company control did not include both client and outsider rows: %',
      v_companies_incomplete_master_ids;
  end if;
  select * into v_requested from public.request_result_set_v1(
    'segregation-fixture-owner', 'company', 'segregation-destination', 'Fixture Co',
    v_incomplete || v_company_membership, 'segregation-companies-incomplete', null, '{}'::jsonb);
  loop
    select * into v_built from prospect_results.build_batch_v1(v_requested.set_id, 1000);
    exit when v_built.done;
  end loop;
  select coalesce(array_agg(entity_id order by entity_id), '{}'::text[])
    into v_companies_incomplete_set
    from prospect_results.result_set_items where result_set_id = v_requested.set_id;
  if v_companies_incomplete_set is distinct from v_incomplete_companies then
    raise exception 'Incomplete client Company result set differs from the interactive workspace: set %, workspace %',
      v_companies_incomplete_set, v_incomplete_companies;
  end if;
  if (select row_count from prospect_results.result_sets where id = v_requested.set_id)
      <> cardinality(v_incomplete_companies) then
    raise exception 'Incomplete client Company result-set count differs from the interactive workspace.';
  end if;

  -- Master remains unpartitioned. The server helper is tested in Node; this
  -- proves the unchanged SQL question still freezes every fixture person.
  select * into v_master from public.search_prospect_workspace_v13(
    'Fixture Person', '[]'::jsonb, 'created_at', 'desc', 50, 0,
    null, '{}'::jsonb, true, null);
  select coalesce(array_agg(row->>'id' order by row->>'id'), '{}'::text[])
    into v_master_people from jsonb_array_elements(v_master.result_rows) row;
  select * into v_requested from public.request_result_set_v1(
    'segregation-fixture-owner', 'prospect', '', 'Fixture Person',
    '[]'::jsonb, 'segregation-master-unchanged', null, '{}'::jsonb);
  loop
    select * into v_built from prospect_results.build_batch_v1(v_requested.set_id, 1000);
    exit when v_built.done;
  end loop;
  select coalesce(array_agg(entity_id order by entity_id), '{}'::text[])
    into v_master_people_set
    from prospect_results.result_set_items where result_set_id = v_requested.set_id;
  if v_master_people_set is distinct from v_master_people
      or cardinality(v_master_people_set) <> 3 then
    raise exception 'Master result set was partitioned or differs from the interactive workspace: set %, workspace %',
      v_master_people_set, v_master_people;
  end if;

  select * into strict v_summary
  from public.client_summaries where id = 'segregation-destination';
  if v_summary.prospect_count <> 2 or v_summary.company_count <> 1
    or v_summary.icp_verified_count <> 1 or v_summary.blocked_count <> 0 then
    raise exception 'Client summary did not subtract only the incomplete slice: people %, companies %, ICP %, blocked %',
      v_summary.prospect_count, v_summary.company_count,
      v_summary.icp_verified_count, v_summary.blocked_count;
  end if;
end $$;

-- Enrich one of the two defining fields. No membership move or re-push is
-- needed: the next read promotes both the company and its linked person.
update public.companies
set short_description = 'Enriched by the fixture'
where id = 'segregation-incomplete-company';

do $$
declare
  v_incomplete jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb;
  v_complete jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb;
  v_people record;
  v_companies record;
  v_summary record;
begin
  select * into v_people from public.search_prospect_workspace_v13(
    '', v_incomplete, 'created_at', 'desc', 50, 0,
    'segregation-destination', '{}'::jsonb, true, null);
  if v_people.total_count <> 0 then
    raise exception 'Enriched linked person remained in Incomplete Info.';
  end if;
  select * into v_people from public.search_prospect_workspace_v13(
    '', v_complete, 'created_at', 'desc', 50, 0,
    'segregation-destination', '{}'::jsonb, true, null);
  if v_people.total_count <> 3 then
    raise exception 'Enrichment did not promote all three normal People rows: %', v_people.total_count;
  end if;
  select * into v_companies from public.client_company_workspace_v2(
    'segregation-destination', '', v_incomplete, null, 50, 0);
  if v_companies.total_count <> 0 then
    raise exception 'Enriched company remained in Incomplete Info.';
  end if;
  select * into v_companies from public.client_company_workspace_v2(
    'segregation-destination', '', v_complete, null, 50, 0);
  if v_companies.total_count <> 2 then
    raise exception 'Enrichment did not promote both normal Company rows: %', v_companies.total_count;
  end if;
  select * into strict v_summary
  from public.client_summaries where id = 'segregation-destination';
  if v_summary.prospect_count <> 3 or v_summary.company_count <> 2 then
    raise exception 'Client summary did not promote enriched memberships: people %, companies %',
      v_summary.prospect_count, v_summary.company_count;
  end if;
end $$;

-- Blocked counts keep their historical meaning and companyless people remain
-- in the normal client partition. Neither may be confused with incomplete.
insert into public.prospects(id, full_name, work_email, company_id)
values ('segregation-blocked-person', 'Blocked Fixture Person', 'blocked@fixture.test', null);
insert into public.client_prospects(client_id, prospect_id, status, added_via)
values ('segregation-destination', 'segregation-blocked-person', 'blocked', 'manual');

do $$
declare v_summary record;
begin
  select * into strict v_summary
  from public.client_summaries where id = 'segregation-destination';
  if v_summary.prospect_count <> 3 or v_summary.company_count <> 2
    or v_summary.icp_verified_count <> 2 or v_summary.blocked_count <> 1 then
    raise exception 'Client summary changed blocked/companyless semantics: people %, companies %, ICP %, blocked %',
      v_summary.prospect_count, v_summary.company_count,
      v_summary.icp_verified_count, v_summary.blocked_count;
  end if;
end $$;

select 'incomplete_info_segregation_ok' as result;
