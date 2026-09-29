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
  ('segregation-complete-company', 'Complete Fixture Co', 'complete fixture co', 'complete-fixture.test', 'complete-fixture.test', '{}'::text[], 'A usable profile');

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

do $$
declare
  v_incomplete jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb;
  v_complete jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb;
  v_people_incomplete record;
  v_people_complete record;
  v_companies_incomplete record;
  v_companies_complete record;
  v_incomplete_people text[];
  v_complete_people text[];
  v_incomplete_companies text[];
  v_complete_companies text[];
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
    'segregation-destination', '', v_incomplete, null, 50, 0);
  select * into v_companies_complete from public.client_company_workspace_v2(
    'segregation-destination', '', v_complete, null, 50, 0);
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
end $$;

select 'incomplete_info_segregation_ok' as result;
