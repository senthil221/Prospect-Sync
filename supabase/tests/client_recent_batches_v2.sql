\set ON_ERROR_STOP on

-- Safe to replay: every fixture is contained in this transaction.
begin;

insert into public.clients (id, name, normalized_name)
values
  ('fixture-recent-client', 'Recent Destination', 'recent destination'),
  ('fixture-recent-source', 'Recent Source', 'recent source');

insert into public.client_addition_batches (
  id, client_id, entity_type, source_kind, source_label, source_client_id,
  outcome_kind, request_key, created_at, completed_at
)
values
  ('10000000-0000-4000-8000-000000000001', 'fixture-recent-client', 'people',
    'import', 'fresh-import.csv', null, 'new_memberships', 'fixture:recent:import',
    now() - interval '2 hours', now() - interval '2 hours'),
  ('10000000-0000-4000-8000-000000000003', 'fixture-recent-client', 'companies',
    'client', 'Recent Source', 'fixture-recent-source', 'new_memberships',
    'fixture:recent:client', now() - interval '3 hours', now() - interval '3 hours'),
  ('10000000-0000-4000-8000-000000000004', 'fixture-recent-client', 'companies',
    'master', 'Source unavailable', null, 'historical_source_unavailable',
    'fixture:recent:unavailable', now() - interval '4 hours', now() - interval '4 hours'),
  ('10000000-0000-4000-8000-000000000005', 'fixture-recent-client', 'people',
    'import', 'expired-import.csv', null, 'new_memberships', 'fixture:recent:expired',
    now() - interval '49 hours', now() - interval '49 hours'),
  ('10000000-0000-4000-8000-000000000006', 'fixture-recent-client', 'companies',
    'client', 'Recent Source', 'fixture-recent-source', 'new_memberships',
    'fixture:recent:exact-boundary', now() - interval '48 hours', now() - interval '48 hours'),
  ('10000000-0000-4000-8000-000000000007', 'fixture-recent-client', 'companies',
    'client', 'Recent Source', 'fixture-recent-source', 'new_memberships',
    'fixture:recent:outside-boundary',
    now() - interval '48 hours 1 microsecond', now() - interval '48 hours 1 microsecond'),
  ('10000000-0000-4000-8000-000000000008', 'fixture-recent-source', 'people',
    'import', 'wrong-client.csv', null, 'new_memberships', 'fixture:recent:wrong-client',
    now() - interval '30 minutes', now() - interval '30 minutes');

-- Sixty Master batches are newer than the one Import batch. This makes a
-- paginate-then-filter implementation fail the Import assertion below.
insert into public.client_addition_batches (
  id, client_id, entity_type, source_kind, source_label, outcome_kind,
  request_key, created_at, completed_at
)
select
  ('20000000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid,
  'fixture-recent-client', 'people', 'master', 'Master DB', 'new_memberships',
  'fixture:recent:master:' || g::text,
  now() - g * interval '1 minute', now() - g * interval '1 minute'
from generate_series(1, 60) g;

do $test$
declare
  v_rows jsonb;
  v_total bigint;
begin
  select result_rows, total_count into v_rows, v_total
  from public.client_recent_batches_v2(
    'fixture-recent-client', '', '', 'all', 48, 100, 0
  );
  if v_total <> 64 or jsonb_array_length(v_rows) <> 64 then
    raise exception 'All sources should include 64 recent destination batches, got % / %',
      v_total, jsonb_array_length(v_rows);
  end if;
  if v_rows->0->>'id' <> '20000000-0000-4000-8000-000000000001' then
    raise exception 'All sources must preserve newest-first SQL order: %', v_rows->0;
  end if;
  if not v_rows @> '[{"id":"10000000-0000-4000-8000-000000000006"}]'::jsonb then
    raise exception 'A batch created exactly 48 hours ago must remain visible.';
  end if;
  if v_rows @> '[{"id":"10000000-0000-4000-8000-000000000007"}]'::jsonb then
    raise exception 'A batch older than 48 hours by one microsecond must be excluded.';
  end if;
  if v_rows @> '[{"id":"10000000-0000-4000-8000-000000000008"}]'::jsonb then
    raise exception 'A batch from another client crossed the client boundary.';
  end if;

  select result_rows, total_count into v_rows, v_total
  from public.client_recent_batches_v2(
    'fixture-recent-client', '', '', 'master', 48, 50, 0
  );
  if v_total <> 60 or jsonb_array_length(v_rows) <> 50
     or v_rows->0->>'source_label' <> 'Master DB' then
    raise exception 'Master source must exclude source-unavailable history: %', v_rows;
  end if;

  select result_rows, total_count into v_rows, v_total
  from public.client_recent_batches_v2(
    'fixture-recent-client', 'fresh-import.csv', 'people', 'import', 48, 1, 0
  );
  if v_total <> 1 or jsonb_array_length(v_rows) <> 1
     or v_rows->0->>'source_label' <> 'fresh-import.csv' then
    raise exception 'Source, entity and search filters must run before pagination: % / %',
      v_total, jsonb_array_length(v_rows);
  end if;

  if has_function_privilege(
      'anon',
      'public.client_recent_batches_v2(text,text,text,text,integer,integer,integer)',
      'EXECUTE'
    )
    or has_function_privilege(
      'authenticated',
      'public.client_recent_batches_v2(text,text,text,text,integer,integer,integer)',
      'EXECUTE'
    )
    or not has_function_privilege(
      'service_role',
      'public.client_recent_batches_v2(text,text,text,text,integer,integer,integer)',
      'EXECUTE'
    ) then
    raise exception 'Recent-batch function grants are not server-only.';
  end if;
end
$test$;

set local role service_role;
do $service_role_probe$
declare v_total bigint;
begin
  select total_count into v_total
  from public.client_recent_batches_v2(
    'fixture-recent-client', '', '', 'all', 48, 50, 0
  );
  if v_total <> 64 then
    raise exception 'Service role could not read the expected recent batches.';
  end if;
end
$service_role_probe$;
reset role;

rollback;
