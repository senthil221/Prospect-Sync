\set ON_ERROR_STOP on

-- Prove that client_companies.prospect_count follows the application's real
-- write paths before client_company_workspace_v2 treats it as authoritative.
-- The caller wraps this fixture in a transaction and rolls it back.
do $$ begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'Refusing stored-count fixture outside its disposable database.';
  end if;
end $$;

insert into public.clients(id, name, normalized_name) values
  ('stored-count-source', 'Stored Count Source', 'stored count source'),
  ('stored-count-destination', 'Stored Count Destination', 'stored count destination');

insert into public.companies(
  id, name, normalized_name, domain, normalized_domain, keywords, short_description
) values (
  'stored-count-company-b', 'Stored Count Company B', 'stored count company b',
  'stored-count-b.test', 'stored-count-b.test', array['software'], 'Complete fixture company'
);

insert into public.lists(id, client_id, name, source_file_name)
values ('stored-count-list', 'stored-count-source', 'Stored Count Import', 'stored-count.csv');
insert into public.imports(
  id, client_id, list_id, file_name, status, total_rows, processed_rows,
  ingestion_mode, import_protocol_version, committed_row_offset
) values (
  'stored-count-import', 'stored-count-source', 'stored-count-list',
  'stored-count.csv', 'processing', 1, 0, 'browser', 1, 0
);

-- The same public batch contract used by browser/protocol-1 imports.
select * from public.import_prospect_batch_v5(
  'stored-count-import', 'stored-count-list',
  jsonb_build_array(jsonb_build_object(
    'firstName', 'Stored', 'lastName', 'Import', 'fullName', 'Stored Import',
    'workEmail', 'stored-count-import@example.test', 'personalEmail', '',
    'mobileNumber', '', 'linkedinUrl', '', 'title', 'Tester', 'keywords', jsonb_build_array(),
    'seniority', '', 'department', '', 'city', '', 'state', '', 'country', '', 'location', '',
    'companyName', 'Stored Count Company A', 'companyDomain', 'stored-count-a.test',
    'companyId', 'stored-count-company-a', 'normalizedCompanyName', 'stored count company a',
    'raw', jsonb_build_object('fixture', true),
    'identifiers', jsonb_build_array(jsonb_build_object('type', 'work_email', 'value', 'stored-count-import@example.test')),
    'sourceRowNumber', 2
  )), 0
);

do $authority$
declare
  v_person text;
  v_company_a text;
  v_result jsonb;
  v_count integer;
  v_rows jsonb;
begin
  select id, company_id into v_person, v_company_a
  from public.prospects where work_email = 'stored-count-import@example.test';
  if v_person is null or v_company_a is null then
    raise exception 'real import path did not create a linked prospect';
  end if;

  select prospect_count into v_count from public.client_companies
  where client_id = 'stored-count-source' and company_id = v_company_a;
  if v_count is distinct from 1 then
    raise exception 'import count expected 1, got %', v_count;
  end if;

  v_result := public.push_prospects_to_client_v2(
    p_client_id => 'stored-count-destination',
    p_source_client_id => 'stored-count-source',
    p_prospect_ids => array[v_person],
    p_actor => 'stored-count-fixture', p_request_id => 'stored-count-push-1');
  if (v_result->>'added')::integer <> 1 then
    raise exception 'push path did not add its person: %', v_result;
  end if;
  select prospect_count into v_count from public.client_companies
  where client_id = 'stored-count-destination' and company_id = v_company_a;
  if v_count is distinct from 1 then
    raise exception 'push count expected 1, got %', v_count;
  end if;

  v_result := public.add_client_blocklist_batch_v2(
    'stored-count-destination', null, array['stored-count-import@example.test'],
    'Client Provided', 'stored-count-fixture', 'stored-count-block-1', 100);
  if (v_result->>'suppressed')::integer <> 1 then
    raise exception 'block path did not suppress its person: %', v_result;
  end if;
  select prospect_count into v_count from public.client_companies
  where client_id = 'stored-count-destination' and company_id = v_company_a;
  if v_count is distinct from 0 then
    raise exception 'block count expected 0, got %', v_count;
  end if;

  v_result := public.remove_client_blocklist_v1(
    'stored-count-destination',
    array(select id from public.client_blocklist
      where client_id = 'stored-count-destination'
        and value = 'stored-count-import@example.test'),
    'stored-count-fixture');
  select prospect_count into v_count from public.client_companies
  where client_id = 'stored-count-destination' and company_id = v_company_a;
  if v_count is distinct from 1 then
    raise exception 'unblock count expected 1, got % (result %)', v_count, v_result;
  end if;

  v_result := public.remove_prospects_from_client_v2(
    p_client_id => 'stored-count-destination', p_search => '', p_filters => '[]'::jsonb,
    p_prospect_ids => array[v_person], p_excluded_ids => null, p_actor => 'stored-count-fixture');
  if (v_result->>'removed')::integer <> 1 then
    raise exception 'remove path did not remove its person: %', v_result;
  end if;
  select prospect_count into v_count from public.client_companies
  where client_id = 'stored-count-destination' and company_id = v_company_a;
  if v_count is distinct from 0 then
    raise exception 'remove count expected 0, got %', v_count;
  end if;

  perform public.push_prospects_to_client_v2(
    p_client_id => 'stored-count-destination', p_source_client_id => 'stored-count-source',
    p_prospect_ids => array[v_person], p_actor => 'stored-count-fixture',
    p_request_id => 'stored-count-push-2');

  -- A supported enrichment/merge reassignment updates the canonical row, then
  -- reindexes it.  The statement trigger must decrement A and increment B for
  -- every active client in the projected row.
  update public.prospects set company_id = 'stored-count-company-b' where id = v_person;
  perform public.reindex_scope_v1(p_prospect_ids => array[v_person]);
  if exists (
    select 1 from public.client_companies
    where client_id in ('stored-count-source', 'stored-count-destination')
      and company_id = v_company_a and prospect_count <> 0
  ) then
    raise exception 'company reassignment did not decrement the old memberships';
  end if;
  if (select count(*) from public.client_companies
      where client_id in ('stored-count-source', 'stored-count-destination')
        and company_id = 'stored-count-company-b' and prospect_count = 1) <> 2 then
    raise exception 'company reassignment did not increment both new memberships';
  end if;

  select result_rows into v_rows from public.client_company_workspace_v2(
    'stored-count-destination', '', '[]'::jsonb, null, 50, 0);
  if not exists (
    select 1 from jsonb_array_elements(v_rows) row_value
    where row_value->>'id' = 'stored-count-company-b'
      and (row_value->>'prospect_count')::integer = 1
  ) then
    raise exception 'workspace did not return the authoritative reassigned count: %', v_rows;
  end if;
end;
$authority$;

