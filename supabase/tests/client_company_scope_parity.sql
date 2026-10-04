\set ON_ERROR_STOP on

-- Disposable end-to-end contract for one client-origin company question. The
-- caller wraps this file in a transaction and rolls it back.
do $$ begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'Refusing client-company parity fixture outside its disposable database.';
  end if;
end; $$;

insert into public.clients(id, name, normalized_name) values
  ('scope-parity-a', 'Scope Parity A', 'scope parity a'),
  ('scope-parity-b', 'Scope Parity B', 'scope parity b');
insert into public.client_settings(client_id, seg_emails) values
  ('scope-parity-a', 'discard'), ('scope-parity-b', 'keep');

insert into public.companies(
  id, name, normalized_name, domain, normalized_domain, keywords,
  short_description, email_provider_type, prospect_count
) values
  ('scope-a-with', 'A With', 'a with', 'a-with.test', 'a-with.test', array['software'], 'complete', 'Mailbox provider', 1),
  ('scope-global-not-a', 'Global Not A', 'global not a', 'global-not-a.test', 'global-not-a.test', array['software'], 'complete', 'Mailbox provider', 1),
  ('scope-shared', 'Shared', 'shared', 'shared.test', 'shared.test', array['software'], 'complete', 'Mailbox provider', 1),
  ('scope-nobody', 'Nobody', 'nobody', 'nobody.test', 'nobody.test', array['software'], 'complete', 'Mailbox provider', 0),
  ('scope-outside-a', 'Outside A', 'outside a', 'outside-a.test', 'outside-a.test', array['software'], 'complete', 'Mailbox provider', 1),
  ('scope-incomplete', 'Incomplete', 'incomplete', 'incomplete.test', 'incomplete.test', '{}'::text[], '', 'Mailbox provider', 1),
  ('scope-seg', 'SEG', 'seg', 'seg.test', 'seg.test', array['software'], 'complete', 'SEG', 1);

insert into public.client_companies(client_id, company_id, added_by) values
  ('scope-parity-a', 'scope-a-with', 'parity-fixture'),
  ('scope-parity-a', 'scope-global-not-a', 'parity-fixture'),
  ('scope-parity-a', 'scope-shared', 'parity-fixture'),
  ('scope-parity-a', 'scope-nobody', 'parity-fixture'),
  ('scope-parity-a', 'scope-incomplete', 'parity-fixture'),
  ('scope-parity-a', 'scope-seg', 'parity-fixture'),
  ('scope-parity-b', 'scope-global-not-a', 'parity-fixture'),
  ('scope-parity-b', 'scope-shared', 'parity-fixture'),
  ('scope-parity-b', 'scope-outside-a', 'parity-fixture');

insert into public.prospects(id, full_name, work_email, company_id) values
  ('scope-person-a', 'Person A', 'a@scope.test', 'scope-a-with'),
  ('scope-person-a-2', 'Person A Two', 'a2@scope.test', 'scope-a-with'),
  ('scope-person-global-not-a', 'Person Global', 'global@scope.test', 'scope-global-not-a'),
  ('scope-person-shared', 'Person Shared', 'shared@scope.test', 'scope-shared'),
  ('scope-person-outside', 'Person Outside', 'outside@scope.test', 'scope-outside-a'),
  ('scope-person-incomplete', 'Person Incomplete', 'incomplete@scope.test', 'scope-incomplete'),
  ('scope-person-seg', 'Person SEG', 'seg@scope.test', 'scope-seg');
insert into public.client_prospects(client_id, prospect_id, status) values
  ('scope-parity-a', 'scope-person-a', 'active'),
  ('scope-parity-a', 'scope-person-a-2', 'active'),
  ('scope-parity-b', 'scope-person-global-not-a', 'active'),
  ('scope-parity-a', 'scope-person-shared', 'active'),
  ('scope-parity-b', 'scope-person-shared', 'active'),
  ('scope-parity-b', 'scope-person-outside', 'active'),
  ('scope-parity-a', 'scope-person-incomplete', 'active'),
  ('scope-parity-a', 'scope-person-seg', 'active');

select public.reindex_prospects(array[
  'scope-person-a', 'scope-person-a-2', 'scope-person-global-not-a', 'scope-person-shared',
  'scope-person-outside', 'scope-person-incomplete', 'scope-person-seg'
]);

do $parity$
declare
  v_base jsonb := jsonb_build_array(
    jsonb_build_object('field','__client_company_scope','operator','equals','values',jsonb_build_array('scope-parity-a')),
    jsonb_build_object('field','__incomplete_company_profile','operator','equals','values',jsonb_build_array('false')),
    jsonb_build_object('field','__client_seg_policy','operator','equals','values',jsonb_build_array('scope-parity-a'))
  );
  v_with jsonb;
  v_without jsonb;
  v_builder text[];
  v_matcher text[];
  v_prefilter text[];
  v_interactive text[];
  v_stream text[];
  v_pivot text[];
  v_selection text[];
  v_explicit text[];
  v_master text[];
  v_contradictory text[];
  v_people_filters jsonb := jsonb_build_array(
    jsonb_build_object('field','__incomplete_company_profile','operator','equals','values',jsonb_build_array('false')),
    jsonb_build_object('field','__client_seg_policy','operator','equals','values',jsonb_build_array('scope-parity-a')),
    jsonb_build_object('field','__max_people_per_company','operator','equals','values',jsonb_build_array('1'))
  );
  v_people_ids text[];
  v_people_export text[];
  v_people_frozen text[];
  v_company_frozen text[];
  v_company_scope jsonb;
  v_set uuid;
  v_total bigint;
  v_rows jsonb;
  v_workspace record;
begin
  v_with := v_base || jsonb_build_array(jsonb_build_object(
    'field','__company_coverage','operator','equals','values',jsonb_build_array('with')));
  v_without := v_base || jsonb_build_array(jsonb_build_object(
    'field','__company_coverage','operator','equals','values',jsonb_build_array('without')));

  -- The compiler, legacy matcher and candidate prefilter must partition this
  -- client's complete, non-SEG companies identically. In particular,
  -- scope-global-not-a has a person globally but none for A.
  foreach v_with in array array[v_with, v_without] loop
    execute format('select coalesce(array_agg(c.id order by c.id), array[]::text[]) from public.companies c where %s',
      public.company_filter_sql_v3('', v_with, false)) into v_builder;
    select coalesce(array_agg(c.id order by c.id), array[]::text[]) into v_matcher
      from public.companies c where public.company_matches_filters_v1(c, '', v_with);
    execute format('select coalesce(array_agg(c.id order by c.id), array[]::text[]) from public.companies c where %s',
      public.company_prefilter_sql('', v_with)) into v_prefilter;
    if v_builder is distinct from v_matcher or v_builder is distinct from v_prefilter then
      raise exception 'company filter paths disagree: builder %, matcher %, prefilter %', v_builder, v_matcher, v_prefilter;
    end if;
  end loop;

  execute format('select coalesce(array_agg(c.id order by c.id), array[]::text[]) from public.companies c where %s',
    public.company_filter_sql_v3('', v_base || jsonb_build_array(jsonb_build_object(
      'field','__company_coverage','operator','equals','values',jsonb_build_array('with'))), false)) into v_builder;
  if v_builder is distinct from array['scope-a-with','scope-shared']::text[] then
    raise exception 'client with-coverage mismatch: %', v_builder;
  end if;
  execute format('select coalesce(array_agg(c.id order by c.id), array[]::text[]) from public.companies c where %s',
    public.company_filter_sql_v3('', v_base || jsonb_build_array(jsonb_build_object(
      'field','__company_coverage','operator','equals','values',jsonb_build_array('without'))), false)) into v_builder;
  if v_builder is distinct from array['scope-global-not-a','scope-nobody']::text[] then
    raise exception 'client without-coverage mismatch: %', v_builder;
  end if;

  select * into v_workspace from public.client_company_workspace_v2(
    'scope-parity-a', '', v_without, null, 50, 0);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_interactive from jsonb_array_elements(v_workspace.result_rows);
  if v_workspace.total_count <> 2 or v_interactive is distinct from array['scope-global-not-a','scope-nobody']::text[] then
    raise exception 'interactive client workspace mismatch: total %, ids %', v_workspace.total_count, v_interactive;
  end if;

  select result_rows into v_rows from public.search_company_export_v2(
    '', v_without, null, false, null, null, 50, array['name']);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_stream from jsonb_array_elements(v_rows);
  if v_stream is distinct from v_interactive then
    raise exception 'stream/listing mismatch: stream %, listing %', v_stream, v_interactive;
  end if;

  select coalesce(array_agg(company_id order by company_id), array[]::text[])
    into v_pivot from public.company_scope_ids_v2('scope-parity-a',
      jsonb_build_object('search','', 'filters',v_without, 'limit',250000));
  if v_pivot is distinct from v_interactive then
    raise exception 'Company-to-People pivot mismatch: pivot %, listing %', v_pivot, v_interactive;
  end if;

  -- A genuine client filter intersects the server-owned origin rather than
  -- replacing it: shared-by-A-and-B with A coverage leaves only scope-shared.
  select coalesce(array_agg(company_id order by company_id), array[]::text[])
    into v_contradictory from public.company_scope_ids_v2('scope-parity-a',
      jsonb_build_object('search','', 'filters',v_base
        || jsonb_build_array(
          jsonb_build_object('field','__company_client_ids','operator','contains','values',jsonb_build_array('scope-parity-b')),
          jsonb_build_object('field','__company_coverage','operator','equals','values',jsonb_build_array('with'))),
        'limit',250000));
  if v_contradictory is distinct from array['scope-shared']::text[] then
    raise exception 'ordinary client filter did not intersect the origin: %', v_contradictory;
  end if;

  select coalesce(array_agg(company_id order by company_id), array[]::text[])
    into v_selection from public.resolve_company_action_selection_v1(
      'scope-parity-a', null, '', v_without, null, null, 250000);
  if v_selection is distinct from v_interactive then
    raise exception 'all-matching selection mismatch: selection %, listing %', v_selection, v_interactive;
  end if;
  select coalesce(array_agg(company_id order by company_id), array[]::text[])
    into v_explicit from public.resolve_company_action_selection_v1(
      'scope-parity-a', array['scope-a-with','scope-outside-a'], '', '[]'::jsonb, null, null, 250000);
  if v_explicit is distinct from array['scope-a-with']::text[] then
    raise exception 'explicit selection crossed client membership: %', v_explicit;
  end if;

  -- Real People listing, streamed export and frozen selection consume the same
  -- normalized nested company scope. Two A people share scope-a-with; the cap
  -- deliberately keeps one, while scope-shared contributes one more.
  v_company_scope := jsonb_build_object('search','', 'filters',v_base
    || jsonb_build_array(jsonb_build_object(
      'field','__company_coverage','operator','equals','values',jsonb_build_array('with'))),
    'limit',250000);
  select result_rows, total_count into v_rows, v_total
    from public.search_prospect_workspace_v13(
      '', v_people_filters, 'created_at', 'desc', 50, 0,
      'scope-parity-a', v_company_scope, true, null);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_people_ids from jsonb_array_elements(v_rows);
  if v_total <> 2 or cardinality(v_people_ids) <> 2
     or not ('scope-person-shared' = any(v_people_ids))
     or cardinality(v_people_ids) <> cardinality(array(
       select distinct pi.company_id from public.prospect_index pi where pi.id = any(v_people_ids))) then
    raise exception 'capped People listing mismatch: total %, ids %', v_total, v_people_ids;
  end if;

  select result_rows, total_count into v_rows, v_total
    from public.search_prospect_export_v6(
      '', v_people_filters, 'scope-parity-a', v_company_scope,
      null, null, 50, true, array['id']);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_people_export from jsonb_array_elements(v_rows);
  if v_total <> 2 or v_people_export is distinct from v_people_ids then
    raise exception 'People stream/listing mismatch: total %, export %, listing %', v_total, v_people_export, v_people_ids;
  end if;

  select set_id into v_set from public.request_result_set_v1(
    'scope-parity-owner', 'prospect', 'scope-parity-a', '', v_people_filters,
    md5('scope parity capped people'), null, v_company_scope);
  perform * from prospect_results.build_batch_v1(v_set, 1000);
  select coalesce(array_agg(entity_id order by entity_id), array[]::text[])
    into v_people_frozen from prospect_results.result_set_items where result_set_id = v_set;
  if v_people_frozen is distinct from v_people_ids then
    raise exception 'People frozen/listing mismatch: frozen %, listing %', v_people_frozen, v_people_ids;
  end if;

  select set_id into v_set from public.request_result_set_v1(
    'scope-parity-owner', 'company', 'scope-parity-a', '', v_without,
    md5('scope parity client companies'), null, '{}'::jsonb);
  perform * from prospect_results.build_batch_v1(v_set, 1000);
  select coalesce(array_agg(entity_id order by entity_id), array[]::text[])
    into v_company_frozen from prospect_results.result_set_items where result_set_id = v_set;
  if v_company_frozen is distinct from v_interactive then
    raise exception 'Company frozen/listing mismatch: frozen %, listing %', v_company_frozen, v_interactive;
  end if;

  -- Enrichment promotes the incomplete row automatically; changing the same
  -- client's SEG policy makes its complete SEG row visible without changing
  -- membership or any caller filter.
  update public.companies set short_description = 'enriched' where id = 'scope-incomplete';
  select * into v_workspace from public.client_company_workspace_v2(
    'scope-parity-a', '', v_base, null, 50, 0);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_builder from jsonb_array_elements(v_workspace.result_rows);
  if not ('scope-incomplete' = any(v_builder)) or 'scope-seg' = any(v_builder) then
    raise exception 'interactive enrichment/SEG discard transition mismatch: %', v_builder;
  end if;
  update public.client_settings set seg_emails = 'keep' where client_id = 'scope-parity-a';
  select * into v_workspace from public.client_company_workspace_v2(
    'scope-parity-a', '', v_base, null, 50, 0);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_builder from jsonb_array_elements(v_workspace.result_rows);
  if not ('scope-incomplete' = any(v_builder)) or not ('scope-seg' = any(v_builder)) then
    raise exception 'interactive SEG keep transition mismatch: %', v_builder;
  end if;

  -- No internal scope preserves Master coverage: every row whose stored global
  -- count is positive remains in the with arm, including global-not-A.
  execute format($sql$select coalesce(array_agg(c.id order by c.id), array[]::text[])
      from public.companies c where c.id like 'scope-%%' and %s$sql$,
    public.company_filter_sql_v3('', '[{"field":"__company_coverage","operator":"equals","values":["with"]}]'::jsonb, false))
    into v_master;
  if v_master is distinct from array[
      'scope-a-with','scope-global-not-a','scope-incomplete','scope-outside-a','scope-seg','scope-shared'
    ]::text[] then
    raise exception 'Master coverage semantics changed: %', v_master;
  end if;
end;
$parity$;
