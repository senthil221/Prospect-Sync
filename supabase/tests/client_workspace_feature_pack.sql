\set ON_ERROR_STOP on

-- This fixture deliberately inserts synthetic rows and must never run against
-- the application database. The validation workflow creates this named,
-- disposable, schema-only database in a tmpfs container.
do $$
begin
  if current_database() <> 'schema_check' then
    raise exception 'Refusing to run destructive feature-pack fixture outside schema_check.';
  end if;
end $$;

set session_replication_role = replica;

-- People without a linked company are each independent for quota purposes;
-- they must not all collapse into one synthetic "null company" bucket.
insert into public.prospect_index(id, full_name, company_id, company_name, client_ids, created_at, updated_at)
select 'cap-unlinked-' || n, 'Cap Unlinked ' || n, null, '', array['cap-client'],
  timestamptz '2026-01-03 00:00:00+00' + n * interval '1 second',
  timestamptz '2026-01-03 00:00:00+00' + n * interval '1 second'
from generate_series(1, 5) n;

do $$
declare v_count integer;
begin
  select count(*) into v_count
  from public.prospect_capped_candidate_ids_v1('',
    '[{"field":"__max_people_per_company","operator":"equals","values":["3"]},{"field":"__company","operator":"empty","values":[]}]'::jsonb,
    'cap-client', '{}'::jsonb);
  if v_count <> 5 then
    raise exception 'Expected all 5 unlinked people to survive the company cap, got %', v_count;
  end if;
end $$;

truncate table public.prospect_index, public.companies cascade;

insert into public.companies(id, name, normalized_name, short_description)
select 'cap-company-' || n, 'Cap Company ' || n, 'cap company ' || n,
  case when n % 2 = 0 then '' else 'Included by company scope' end
from generate_series(1, 100) n;

-- 100,000 people gives every company 1,000 candidates. Every tenth person is
-- outside the authorized client scope and is intentionally interleaved with
-- newer candidates so it would consume the quota if ranking happened before
-- client membership was applied.
insert into public.prospect_index(
  id, full_name, company_id, company_name, client_ids, created_at, updated_at
)
select 'cap-person-' || n, 'Cap Person ' || n,
  'cap-company-' || (((n - 1) % 100) + 1),
  'Cap Company ' || (((n - 1) % 100) + 1),
  case when ((n - 1) / 100) % 10 = 0 then array['other-client']::text[] else array['cap-client']::text[] end,
  timestamptz '2026-01-01 00:00:00+00' + n * interval '1 second',
  timestamptz '2026-01-01 00:00:00+00' + n * interval '1 second'
from generate_series(1, 100000) n;

set session_replication_role = origin;
analyze public.companies;
analyze public.prospect_index;

do $$
declare
  v_filters jsonb := '[{"id":"cap","field":"__max_people_per_company","operator":"equals","values":["3"]}]'::jsonb;
  v_scope jsonb := '{"search":"","filters":[{"id":"scope","field":"__short_description","operator":"not_empty","values":[]}],"limit":250000}'::jsonb;
  v_count bigint;
  v_max bigint;
  v_workspace record;
  v_export record;
begin
  select count(*) into v_count
  from public.prospect_capped_candidate_ids_v1('', v_filters, 'cap-client', v_scope);
  if v_count <> 150 then
    raise exception 'Expected 150 capped candidates (50 scoped companies x 3), got %', v_count;
  end if;

  select max(per_company) into v_max from (
    select pi.company_id, count(*) per_company
    from public.prospect_capped_candidate_ids_v1('', v_filters, 'cap-client', v_scope) candidate
    join public.prospect_index pi on pi.id = candidate.prospect_id
    group by pi.company_id
  ) grouped;
  if v_max <> 3 then raise exception 'Expected a per-company maximum of 3, got %', v_max; end if;

  if exists (
    select 1
    from public.prospect_capped_candidate_ids_v1('', v_filters, 'cap-client', v_scope) candidate
    join public.prospect_index pi on pi.id = candidate.prospect_id
    join public.companies c on c.id = pi.company_id
    where not (pi.client_ids @> array['cap-client']) or c.short_description = ''
  ) then
    raise exception 'The cap admitted a person outside the authorized client/company scope.';
  end if;

  select * into v_workspace from public.search_prospect_workspace_v13(
    '', v_filters, 'created_at', 'desc', 50, 0, 'cap-client', v_scope, true, null);
  if v_workspace.total_count <> 150 or jsonb_array_length(v_workspace.result_rows) <> 50 then
    raise exception 'Workspace cap mismatch: total %, page %',
      v_workspace.total_count, jsonb_array_length(v_workspace.result_rows);
  end if;

  select * into v_export from public.search_prospect_export_v6(
    '', v_filters, 'cap-client', v_scope, null, null, 500, true, array['id']);
  if v_export.total_count <> 150 or jsonb_array_length(v_export.result_rows) <> 150 then
    raise exception 'Export cap mismatch: total %, rows %',
      v_export.total_count, jsonb_array_length(v_export.result_rows);
  end if;

  begin
    perform * from public.prospect_capped_candidate_ids_v1('',
      '[{"field":"__max_people_per_company","operator":"equals","values":["1001"]}]'::jsonb,
      'cap-client', '{}'::jsonb);
    raise exception 'A cap above 1000 was accepted.';
  exception when sqlstate '22023' then null;
  end;
end $$;

-- Export resolves the exact same frozen selection as edit/delete, including
-- explicit ids, a captured all-matching cutoff, and exclusions.
insert into public.clients(id, name, normalized_name)
values ('fixture-block-client', 'Fixture Block Client', 'fixture block client');
insert into public.client_blocklist(id, client_id, kind, value, reason, created_at)
values
  ('fixture-export-a', 'fixture-block-client', 'domain', 'export-a.example', 'Client Provided', '2026-01-03 00:00:00+00'),
  ('fixture-export-b', 'fixture-block-client', 'domain', 'export-b.example', 'Client Provided', '2026-01-04 00:00:00+00'),
  ('fixture-export-late', 'fixture-block-client', 'domain', 'export-late.example', 'Client Provided', '2026-01-05 00:00:00+00');

do $$
declare v_count integer; v_ids text[]; v_next text;
begin
  select public.client_blocklist_selection_count_v1(
    'fixture-block-client', null, true, 'export', 'domain', null, null,
    array['fixture-export-b'], '2026-01-04 12:00:00+00') into v_count;
  if v_count <> 1 then raise exception 'Frozen export count expected 1, got %', v_count; end if;
  select array_agg(id order by created_at desc, id) into v_ids
  from public.client_blocklist_export_page_v1(
    'fixture-block-client', null, true, 'export', 'domain', null, null,
    array['fixture-export-b'], '2026-01-04 12:00:00+00', null, null, 1000);
  if v_ids is distinct from array['fixture-export-a']::text[] then
    raise exception 'Frozen all-matching export disagreed with selection: %', v_ids;
  end if;
  select id into v_next from public.client_blocklist_export_page_v1(
    'fixture-block-client', array['fixture-export-a','fixture-export-late'], false,
    '', '', null, null, null, null, '2026-01-05 00:00:00+00', 'fixture-export-late', 1);
  if v_next <> 'fixture-export-a' then
    raise exception 'Explicit export keyset page expected fixture-export-a, got %', v_next;
  end if;
end $$;

-- Submission-only links accept idempotently, reject revoked/expired shares,
-- remain scoped to their client, and are processed by the durable retry queue.
insert into public.client_blocklist_shares(id, client_id, token_hash, label, created_by)
values ('11111111-1111-4111-8111-111111111111', 'fixture-block-client', 'fixture-active-token', 'Fixture active', 'fixture');
insert into public.client_blocklist_shares(id, client_id, token_hash, label, created_by, revoked_at)
values ('22222222-2222-4222-8222-222222222222', 'fixture-block-client', 'fixture-revoked-token', 'Fixture revoked', 'fixture', now());
insert into public.client_blocklist_shares(id, client_id, token_hash, label, created_by, expires_at)
values ('33333333-3333-4333-8333-333333333333', 'fixture-block-client', 'fixture-expired-token', 'Fixture expired', 'fixture', now() - interval '1 minute');

do $$
declare
  v_first uuid;
  v_replay uuid;
  v_job record;
  v_attempt integer;
begin
  v_first := public.enqueue_blocklist_share_submission_v1(
    'fixture-active-token', 'fixture-requester', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    array['shared-only.example'], array[]::text[], 'Client Provided');
  v_replay := public.enqueue_blocklist_share_submission_v1(
    'fixture-active-token', 'fixture-requester', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    array['shared-only.example'], array[]::text[], 'Client Provided');
  if v_first <> v_replay then raise exception 'Share replay created a different durable job.'; end if;
  if (select count(*) from public.client_blocklist_share_submissions where share_id = '11111111-1111-4111-8111-111111111111') <> 1 then
    raise exception 'Share replay created more than one durable job.';
  end if;
  if (select coalesce(sum(attempts), 0) from public.client_blocklist_share_limits where share_id = '11111111-1111-4111-8111-111111111111') <> 2 then
    raise exception 'Replay consumed another requester/global rate allowance.';
  end if;

  begin
    perform public.enqueue_blocklist_share_submission_v1(
      'fixture-revoked-token', 'fixture-requester', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      array['revoked.example'], array[]::text[], 'Client Provided');
    raise exception 'Revoked share was accepted.';
  exception when sqlstate 'P0002' then null;
  end;
  begin
    perform public.enqueue_blocklist_share_submission_v1(
      'fixture-expired-token', 'fixture-requester', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      array['expired.example'], array[]::text[], 'Client Provided');
    raise exception 'Expired share was accepted.';
  exception when sqlstate 'P0002' then null;
  end;

  select * into v_job from public.run_blocklist_share_submission_unit_v1('fixture-worker', 100);
  if v_job.job_id <> v_first or not v_job.done then
    raise exception 'Valid share job did not complete: %', row_to_json(v_job);
  end if;
  if not exists (select 1 from public.client_blocklist where client_id = 'fixture-block-client' and value = 'shared-only.example') then
    raise exception 'Completed share job was not applied to its client.';
  end if;
  if exists (select 1 from public.client_blocklist where client_id <> 'fixture-block-client' and value = 'shared-only.example') then
    raise exception 'Completed share job escaped its client scope.';
  end if;

  insert into public.client_blocklist_share_submissions(
    id, share_id, client_id, request_key, domains, emails, reason, status)
  values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '11111111-1111-4111-8111-111111111111',
    'fixture-block-client', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', array['retry.example'],
    array[]::text[], 'Invalid legacy reason', 'queued');
  for v_attempt in 1..5 loop
    perform * from public.run_blocklist_share_submission_unit_v1('fixture-worker', 100);
  end loop;
  if (select status from public.client_blocklist_share_submissions where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd') <> 'failed'
     or (select attempts from public.client_blocklist_share_submissions where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd') <> 5 then
    raise exception 'Failed share job did not follow the bounded retry lifecycle.';
  end if;

  if has_function_privilege('anon', 'public.enqueue_blocklist_share_submission_v1(text,text,uuid,text[],text[],text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.enqueue_blocklist_share_submission_v1(text,text,uuid,text[],text[],text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.enqueue_blocklist_share_submission_v1(text,text,uuid,text[],text[],text)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.run_blocklist_share_submission_unit_v1(text,integer)', 'EXECUTE')
     or not has_function_privilege('prospect_operator', 'public.run_blocklist_share_submission_unit_v1(text,integer)', 'EXECUTE') then
    raise exception 'Submission functions have unsafe role grants.';
  end if;
end $$;

-- Incomplete Info: both company fields are empty, and the people side is
-- constrained by a real linked company id. A same-named unlinked person must
-- not leak into the locked view.
set session_replication_role = replica;
insert into public.prospect_index(id, full_name, company_id, company_name, client_ids, created_at, updated_at)
values ('incomplete-unlinked', 'Unlinked lookalike', null, 'Cap Company 2', array['cap-client'], now(), now());
set session_replication_role = origin;

do $$
declare
  v_company_filters jsonb := '[{"field":"__keywords","operator":"empty","values":[]},{"field":"__short_description","operator":"empty","values":[]}]'::jsonb;
  v_people_filters jsonb := '[{"field":"__company_keywords","operator":"empty","values":[]},{"field":"__company_description","operator":"empty","values":[]},{"field":"__max_people_per_company","operator":"equals","values":["1000"]}]'::jsonb;
  v_scope jsonb;
  v_company_count bigint;
  v_people_count bigint;
begin
  v_scope := jsonb_build_object('search', '', 'filters', v_company_filters, 'limit', 250000);
  select count(*) into v_company_count from public.company_scope_ids_v2(null, v_scope);
  if v_company_count <> 50 then
    raise exception 'Incomplete company filters expected 50 companies, got %', v_company_count;
  end if;
  select count(*) into v_people_count
  from public.prospect_capped_candidate_ids_v1('', v_people_filters, 'cap-client', v_scope);
  if v_people_count <> 45000 then
    raise exception 'Incomplete people view expected 45000 linked people, got %', v_people_count;
  end if;
  if exists (
    select 1 from public.prospect_capped_candidate_ids_v1('', v_people_filters, 'cap-client', v_scope)
    where prospect_id = 'incomplete-unlinked'
  ) then
    raise exception 'Incomplete people view admitted an unlinked company-name lookalike.';
  end if;
end $$;

-- A durable capped set is materialized once. Later changes to the live source
-- neither remove an old member nor admit a replacement into that frozen set.
do $$
declare
  v_set uuid := gen_random_uuid();
  v_before text;
  v_after text;
  v_result record;
  v_existing text;
  v_replacement text;
begin
  insert into prospect_results.result_sets(
    id, owner_id, entity_type, client_scope, content_hash, version_vector,
    search, filters, company_scope, status, expires_at)
  values (v_set, 'fixture-owner', 'prospect', 'cap-client', 'fixture-frozen-cap', '{}'::jsonb,
    '', '[{"field":"__max_people_per_company","operator":"equals","values":["3"]}]'::jsonb,
    '{"search":"","filters":[{"field":"__short_description","operator":"not_empty","values":[]}],"limit":250000}'::jsonb,
    'pending', now() + interval '1 hour');
  select * into v_result from prospect_results.build_regular_batch_v2(v_set, 1);
  if not v_result.done or v_result.total <> 150 then
    raise exception 'Capped result set was not atomically frozen: %', row_to_json(v_result);
  end if;
  select md5(string_agg(entity_id, ',' order by entity_id)), min(entity_id)
    into v_before, v_existing
  from prospect_results.result_set_items where result_set_id = v_set;
  select pi.id into v_replacement from public.prospect_index pi
  where pi.client_ids @> array['other-client'] and pi.company_id = (
    select company_id from public.prospect_index where id = v_existing)
  order by pi.created_at desc limit 1;
  if v_replacement is null then
    raise exception 'Frozen-set fixture could not find a real out-of-scope replacement candidate.';
  end if;
  update public.prospect_index set client_ids = array['other-client'] where id = v_existing;
  update public.prospect_index set client_ids = array['cap-client'] where id = v_replacement;
  perform * from prospect_results.build_regular_batch_v2(v_set, 1);
  select md5(string_agg(entity_id, ',' order by entity_id)) into v_after
  from prospect_results.result_set_items where result_set_id = v_set;
  if v_after is distinct from v_before then
    raise exception 'Frozen capped set changed after its live source changed.';
  end if;
end $$;

-- Imported company collections survive staging cleanup and retain all current
-- v3 compiler semantics when combined with ordinary filters.
insert into public.company_imports(id, file_name, data_source, status, total_rows, processed_rows)
values ('fixture-company-import', 'fixture-companies.csv', 'Fixture', 'completed', 1, 1);
insert into public.company_import_rows(import_id, source_row_number, company_id)
values ('fixture-company-import', 2, 'cap-company-2');
delete from public.company_import_rows where import_id = 'fixture-company-import';

do $$
declare v_predicate text; v_count bigint; v_regular bigint;
begin
  v_predicate := public.company_effective_filter_sql_v1('',
    '[{"field":"__company_import_id","operator":"equals","values":["fixture-company-import"]},{"field":"__short_description","operator":"empty","values":[]}]'::jsonb);
  execute 'select count(*) from public.companies c where ' || v_predicate into v_count;
  if v_count <> 1 then
    raise exception 'Durable imported company collection expected 1 row after staging purge, got %', v_count;
  end if;
  v_predicate := public.company_effective_filter_sql_v1('',
    '[{"field":"__short_description","operator":"empty","values":[]}]'::jsonb);
  execute 'select count(*) from public.companies c where ' || v_predicate into v_regular;
  if v_regular <> 50 then
    raise exception 'Ordinary v3 company filter regressed; expected 50 rows, got %', v_regular;
  end if;
end $$;

-- Select-all is a frozen cutoff. A later matching row is never included in the
-- update even when the search/type/date filters still match it.
insert into public.clients(id, name, normalized_name)
values ('fixture-block-client', 'Fixture Block Client', 'fixture block client')
on conflict (id) do nothing;
insert into public.client_blocklist(id, client_id, kind, value, reason, created_at)
values
  ('fixture-block-old', 'fixture-block-client', 'domain', 'old.example', 'Client Provided', '2026-01-01 00:00:00+00'),
  ('fixture-block-new', 'fixture-block-client', 'domain', 'new.example', 'Campaign Reply', '2026-01-02 00:00:00+00');

do $$
declare v_result jsonb;
begin
  v_result := public.update_client_blocklist_reason_v1(
    'fixture-block-client', 'ICP Invalid', null, true, 'example', 'domain', null, null,
    null, '2026-01-01 12:00:00+00', 'fixture');
  if (v_result->>'updated')::integer <> 1 then
    raise exception 'Blocklist cutoff expected one updated row, got %', v_result;
  end if;
  if (select reason from public.client_blocklist where id = 'fixture-block-new') <> 'Campaign Reply' then
    raise exception 'Blocklist cutoff widened to a row inserted after selection.';
  end if;
end $$;

-- Actual-new provenance: one import insert and one cross-client push each
-- create exactly one people item and one company item. Replaying the push does
-- not add another logical batch.
insert into public.clients(id, name, normalized_name) values
  ('fixture-source-client', 'Fixture Source', 'fixture source'),
  ('fixture-destination-client', 'Fixture Destination', 'fixture destination'),
  ('fixture-import-client', 'Fixture Import Client', 'fixture import client');
insert into public.prospects(id, full_name, work_email, company_id) values
  ('fixture-push-person', 'Push Person', 'push.person@example.test', 'cap-company-2'),
  ('fixture-import-person', 'Import Person', 'import.person@example.test', 'cap-company-4');
select public.reindex_prospects(array['fixture-push-person', 'fixture-import-person']);
insert into public.client_prospects(client_id, prospect_id, added_via)
values ('fixture-source-client', 'fixture-push-person', 'manual');
insert into public.lists(id, client_id, name, data_source)
values ('fixture-import-list', 'fixture-import-client', 'Fixture import list', 'Fixture');
insert into public.imports(id, client_id, list_id, file_name, data_source, status, total_rows, processed_rows)
values ('fixture-people-import', 'fixture-import-client', 'fixture-import-list', 'fixture-people.csv', 'Fixture', 'completed', 1, 1);
insert into public.client_prospects(client_id, prospect_id, added_via, source_import_id)
values ('fixture-import-client', 'fixture-import-person', 'import', 'fixture-people-import');

do $$
declare v_result jsonb; v_batch_count integer;
begin
  v_result := public.push_prospects_to_client_v2(
    'fixture-destination-client', '', '[]'::jsonb, 'fixture-source-client',
    array['fixture-push-person'], null, 'fixture', 'fixture-push-request');
  if (v_result->>'added')::integer <> 1 then raise exception 'Fixture push did not add its person: %', v_result; end if;
  perform public.push_prospects_to_client_v2(
    'fixture-destination-client', '', '[]'::jsonb, 'fixture-source-client',
    array['fixture-push-person'], null, 'fixture', 'fixture-push-request');
  select count(*) into v_batch_count from public.client_addition_batches
  where client_id = 'fixture-destination-client'
    and request_key in ('fixture-push-request', 'fixture-push-request:companies');
  if v_batch_count <> 2 then raise exception 'Push retry expected exactly two logical entity batches, got %', v_batch_count; end if;
  if (select count(*) from public.client_addition_batch_items i join public.client_addition_batches b on b.id = i.batch_id
      where b.client_id = 'fixture-destination-client' and b.request_key = 'fixture-push-request:companies') <> 1 then
    raise exception 'Push company provenance did not record the actually-added company once.';
  end if;
  if (select count(*) from public.client_addition_batches
      where client_id = 'fixture-import-client' and request_key = 'import:fixture-people-import') <> 2 then
    raise exception 'Import expected one people and one company provenance batch.';
  end if;
end $$;

-- Large-company performance proof. The function is set-based; its definition
-- must contain one window ranking and no per-candidate call to itself.
do $$
declare v_def text := pg_get_functiondef('public.prospect_capped_candidate_ids_v1(text,jsonb,text,jsonb)'::regprocedure);
begin
  if position('row_number() over' in lower(v_def)) = 0 then
    raise exception 'Canonical cap no longer contains one set-based window rank.';
  end if;
end $$;
explain (analyze, buffers, costs off, summary on)
select count(*)
from public.prospect_capped_candidate_ids_v1(
  '',
  '[{"id":"cap","field":"__max_people_per_company","operator":"equals","values":["3"]}]'::jsonb,
  'cap-client',
  '{"search":"","filters":[{"id":"scope","field":"__short_description","operator":"not_empty","values":[]}],"limit":250000}'::jsonb
);

select 'client_workspace_feature_pack_ok' as result;
