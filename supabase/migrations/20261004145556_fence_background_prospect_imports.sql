-- Fence durable People imports by a rotating, database-owned claim token.
--
-- A worker may spend minutes downloading and normalising a CSV.  Its hostname
-- is not an ownership fence: after a lease expires another process can claim
-- the same job while the first process is still alive.  Protocol 2 admits a
-- write only while (worker_id, claim_token, status, lease) still match under an
-- import-row lock.  COPY lands in a connection-local temporary table; only a
-- fenced function may publish it into the durable v2 stage.

set local lock_timeout = '5s';

alter table public.imports
  add column if not exists import_protocol_version smallint not null default 1,
  add column if not exists claim_token uuid,
  add column if not exists completion_receipt uuid;

alter table public.imports
  drop constraint if exists imports_protocol_version_valid;
alter table public.imports
  add constraint imports_protocol_version_valid
  check (import_protocol_version in (1, 2));

create table if not exists prospect_import.staged_rows_v2 (
  import_id text not null references public.imports(id) on delete cascade,
  row_offset integer not null check (row_offset >= 0),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  source_fingerprint text not null,
  published_claim_token uuid not null,
  published_at timestamptz not null default clock_timestamp(),
  primary key (import_id, row_offset)
);

revoke all on prospect_import.staged_rows_v2 from public, anon, authenticated, service_role, prospect_importer;

create or replace function prospect_import.lock_active_claim_v2(
  p_import_id text,
  p_list_id text,
  p_worker_id text,
  p_claim_token uuid
)
returns public.imports
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, prospect_import
as $function$
declare
  v_import public.imports;
  v_now timestamptz;
begin
  if nullif(btrim(p_import_id), '') is null
     or nullif(btrim(p_list_id), '') is null
     or nullif(btrim(p_worker_id), '') is null
     or p_claim_token is null then
    raise exception 'IMPORT_CLAIM_LOST' using errcode = 'P0002';
  end if;

  select * into v_import
  from public.imports i
  where i.id = p_import_id and i.list_id = p_list_id
  for update;
  v_now := clock_timestamp();

  if v_import.id is null
     or v_import.ingestion_mode <> 'background'
     or v_import.import_protocol_version <> 2
     or v_import.status <> 'processing'
     or v_import.worker_id is distinct from p_worker_id
     or v_import.claim_token is distinct from p_claim_token then
    raise exception 'IMPORT_CLAIM_LOST' using errcode = 'P0002';
  end if;
  if v_import.lease_expires_at is null or v_import.lease_expires_at <= v_now then
    raise exception 'IMPORT_LEASE_EXPIRED' using errcode = '55000';
  end if;
  return v_import;
end;
$function$;

revoke execute on function prospect_import.lock_active_claim_v2(text,text,text,uuid)
  from public, anon, authenticated, service_role, prospect_importer;

create or replace function prospect_import.claim_next_v2(
  p_worker_id text,
  p_lease_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '5s'
as $function$
declare
  v_import_id text;
  v_token uuid := gen_random_uuid();
  v_now timestamptz;
  v_result jsonb;
begin
  if nullif(btrim(p_worker_id), '') is null then
    raise exception 'worker id is required' using errcode = '22023';
  end if;
  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 1800 then
    raise exception 'lease must be between 30 and 1800 seconds' using errcode = '22023';
  end if;
  v_now := clock_timestamp();

  select i.id into v_import_id
  from public.imports i
  where i.ingestion_mode = 'background'
    and i.next_attempt_at <= v_now
    and (
      i.status = 'queued'
      or (i.status = 'processing' and coalesce(i.lease_expires_at, '-infinity'::timestamptz) <= v_now)
    )
  order by i.created_at, i.id
  for update skip locked
  limit 1;

  if v_import_id is null then return null; end if;
  v_now := clock_timestamp();
  update public.imports i
  set status = 'processing',
      import_protocol_version = 2,
      worker_id = p_worker_id,
      claim_token = v_token,
      completion_receipt = null,
      lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
      heartbeat_at = v_now,
      started_at = coalesce(i.started_at, v_now),
      attempt_count = i.attempt_count + 1
  where i.id = v_import_id
  returning jsonb_build_object(
    'id', i.id,
    'listId', i.list_id,
    'fileName', i.file_name,
    'storageObjectPath', i.storage_object_path,
    'fileSizeBytes', i.file_size_bytes,
    'committedRowOffset', i.committed_row_offset,
    'totalRows', i.total_rows,
    'sourceHeaders', i.source_headers,
    'fieldMap', i.field_map,
    'attemptCount', i.attempt_count,
    'claimToken', i.claim_token,
    'leaseExpiresAt', i.lease_expires_at,
    'protocolVersion', i.import_protocol_version
  ) into v_result;
  return v_result;
end;
$function$;

create or replace function prospect_import.renew_claim_v2(
  p_import_id text,
  p_list_id text,
  p_worker_id text,
  p_claim_token uuid,
  p_lease_seconds integer default 300,
  p_total_rows integer default null,
  p_processed_bytes bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '10s'
as $function$
declare
  v_import public.imports;
  v_now timestamptz;
begin
  -- Completion is terminal but not a lost claim.  A heartbeat already queued
  -- behind completion must be able to observe that outcome without turning a
  -- confirmed completion into a retry.
  select * into v_import from public.imports i
  where i.id = p_import_id and i.list_id = p_list_id for update;
  v_now := clock_timestamp();
  if v_import.id is not null
     and v_import.import_protocol_version = 2
     and v_import.status = 'completed'
     and v_import.claim_token = p_claim_token then
    return jsonb_build_object('status','completed','committedRowOffset',v_import.committed_row_offset,
      'totalRows',v_import.total_rows,'completionReceipt',v_import.completion_receipt);
  end if;
  v_import := prospect_import.lock_active_claim_v2(p_import_id,p_list_id,p_worker_id,p_claim_token);
  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 1800 then
    raise exception 'lease must be between 30 and 1800 seconds' using errcode = '22023';
  end if;
  if p_total_rows is not null and p_total_rows < v_import.committed_row_offset then
    raise exception 'total rows cannot precede the committed cursor' using errcode = '22023';
  end if;
  update public.imports i
  set lease_expires_at = v_now + make_interval(secs => p_lease_seconds),
      heartbeat_at = v_now,
      total_rows = coalesce(p_total_rows, i.total_rows),
      processed_bytes = greatest(i.processed_bytes, coalesce(p_processed_bytes, i.processed_bytes))
  where i.id = p_import_id
  returning * into v_import;
  return jsonb_build_object('status',v_import.status,'committedRowOffset',v_import.committed_row_offset,
    'totalRows',v_import.total_rows,'leaseExpiresAt',v_import.lease_expires_at);
end;
$function$;

create or replace function prospect_import.claim_state_v2(
  p_import_id text,
  p_list_id text,
  p_worker_id text,
  p_claim_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '10s'
as $function$
declare v_import public.imports;
begin
  select * into v_import from public.imports i
  where i.id=p_import_id and i.list_id=p_list_id for update;
  if v_import.id is not null and v_import.import_protocol_version=2
     and v_import.status='completed' and v_import.claim_token=p_claim_token then
    return jsonb_build_object('status','completed','committedRowOffset',v_import.committed_row_offset,
      'totalRows',v_import.total_rows,'completionReceipt',v_import.completion_receipt);
  end if;
  v_import := prospect_import.lock_active_claim_v2(p_import_id,p_list_id,p_worker_id,p_claim_token);
  return jsonb_build_object('status',v_import.status,'committedRowOffset',v_import.committed_row_offset,
    'totalRows',v_import.total_rows,'leaseExpiresAt',v_import.lease_expires_at);
end;
$function$;

create or replace function prospect_import.stage_state_v2(
  p_import_id text,
  p_list_id text,
  p_worker_id text,
  p_claim_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '10s'
as $function$
declare
  v_import public.imports;
  v_count integer;
  v_min integer;
  v_max integer;
  v_fingerprint text;
begin
  v_import := prospect_import.lock_active_claim_v2(p_import_id,p_list_id,p_worker_id,p_claim_token);
  v_fingerprint := pg_catalog.md5(jsonb_build_object(
    'storageObjectPath',v_import.storage_object_path,
    'sourceHeaders',v_import.source_headers,
    'fieldMap',v_import.field_map
  )::text);
  select count(*)::integer,min(row_offset),max(row_offset)
    into v_count,v_min,v_max from prospect_import.staged_rows_v2 where import_id=p_import_id;
  if exists(select 1 from prospect_import.staged_rows_v2 s
    where s.import_id=p_import_id and s.source_fingerprint<>v_fingerprint) then
    raise exception 'Durable stage no longer matches the import source mapping' using errcode='P0002';
  end if;
  return jsonb_build_object('count',v_count,'minimum',v_min,'maximum',v_max,
    'committedRowOffset',v_import.committed_row_offset,'totalRows',v_import.total_rows);
end;
$function$;

create or replace function prospect_import.publish_temp_stage_v2(
  p_import_id text,
  p_list_id text,
  p_worker_id text,
  p_claim_token uuid,
  p_temp_table regclass,
  p_total_rows integer,
  p_processed_bytes bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '120s'
as $function$
declare
  v_import public.imports;
  v_rel record;
  v_count integer;
  v_min integer;
  v_max integer;
  v_valid boolean;
  v_sql text;
  v_fingerprint text;
begin
  v_import := prospect_import.lock_active_claim_v2(p_import_id,p_list_id,p_worker_id,p_claim_token);
  if p_temp_table is null then
    raise exception 'Publication source is required' using errcode='22023';
  end if;
  select c.relkind,c.relpersistence,c.relnamespace into v_rel from pg_class c where c.oid=p_temp_table;
  if v_rel.relkind <> 'r' or v_rel.relpersistence <> 't' or v_rel.relnamespace <> pg_my_temp_schema() then
    raise exception 'Publication source must be this connection''s temporary table' using errcode='22023';
  end if;
  if p_total_rows is null or p_total_rows < 1 or p_total_rows < v_import.committed_row_offset then
    raise exception 'Invalid total row count' using errcode='22023';
  end if;
  v_sql := format($sql$select count(*)::integer,min(row_offset),max(row_offset),
      coalesce(bool_and(row_offset >= 0 and jsonb_typeof(payload)='object'
        and jsonb_typeof(payload->'sourceRowNumber')='number'
        and coalesce(payload->>'sourceRowNumber','') ~ '^[0-9]+$'
        and (payload->>'sourceRowNumber')::integer=row_offset+2),true)
      from %s$sql$,p_temp_table);
  execute v_sql into v_count,v_min,v_max,v_valid;
  if not v_valid
     or v_count <> p_total_rows-v_import.committed_row_offset
     or (v_count > 0 and (v_min <> v_import.committed_row_offset or v_max <> p_total_rows-1)) then
    raise exception 'Temporary stage is not contiguous with the committed cursor' using errcode='P0002';
  end if;

  v_fingerprint := pg_catalog.md5(jsonb_build_object(
    'storageObjectPath',v_import.storage_object_path,
    'sourceHeaders',v_import.source_headers,
    'fieldMap',v_import.field_map
  )::text);
  delete from prospect_import.staged_rows_v2 where import_id=p_import_id;
  v_sql := format($sql$insert into prospect_import.staged_rows_v2(
      import_id,row_offset,payload,source_fingerprint,published_claim_token)
    select %L,row_offset,payload,%L,%L::uuid from %s order by row_offset$sql$,
    p_import_id,v_fingerprint,p_claim_token,p_temp_table);
  execute v_sql;
  update public.imports i set total_rows=p_total_rows,
    processed_bytes=greatest(i.processed_bytes,coalesce(p_processed_bytes,i.processed_bytes)),
    heartbeat_at=clock_timestamp()
  where i.id=p_import_id;
  return jsonb_build_object('count',v_count,'minimum',v_min,'maximum',v_max,
    'committedRowOffset',v_import.committed_row_offset,'totalRows',p_total_rows);
end;
$function$;

-- The proven merge core, private so only a fenced wrapper can invoke it for a
-- protocol-2 job.  Browser and legacy jobs keep their public v5 entry point.
create or replace function prospect_import.import_prospect_batch_core_v2(
  p_import_id text,
  p_list_id text,
  p_rows jsonb,
  p_row_offset integer
)
returns table(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '120s'
as $function$
declare
  v_base record;
  v_committed integer;
  v_size integer := jsonb_array_length(coalesce(p_rows,'[]'::jsonb));
begin
  if p_row_offset is null or p_row_offset < 0 then raise exception 'A non-negative row offset is required' using errcode='22023'; end if;
  select i.committed_row_offset into v_committed from public.imports i
  where i.id=p_import_id and i.list_id=p_list_id and i.status='processing' for update;
  if not found then raise exception 'Import not found or already completed' using errcode='P0002'; end if;
  if p_row_offset+v_size <= v_committed then return query select v_size,0,0,0; return; end if;
  select * into v_base from public.import_prospect_batch_v4(p_import_id,p_list_id,p_rows);
  perform public.reindex_prospects(array(
    select distinct lr.prospect_id from public.list_rows lr
    where lr.import_id=p_import_id and lr.prospect_id is not null
      and lr.source_row_number=any(select (elem->>'sourceRowNumber')::integer
        from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) elem
        where nullif(elem->>'sourceRowNumber','') is not null)));
  update public.imports set committed_row_offset=greatest(committed_row_offset,p_row_offset+v_size)
    where id=p_import_id and list_id=p_list_id;
  return query select v_base.processed,v_base.unique_added,v_base.duplicates_linked,v_base.skipped;
end;
$function$;
revoke execute on function prospect_import.import_prospect_batch_core_v2(text,text,jsonb,integer)
  from public, anon, authenticated, service_role, prospect_importer;

create or replace function prospect_import.process_staged_batch_v2(
  p_import_id text,
  p_list_id text,
  p_worker_id text,
  p_claim_token uuid,
  p_row_offset integer,
  p_expected_count integer
)
returns table(processed integer, unique_added integer, duplicates_linked integer, skipped integer, committed_row_offset integer)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '120s'
as $function$
declare
  v_import public.imports;
  v_payload jsonb;
  v_count integer;
  v_min integer;
  v_max integer;
  v_base record;
  v_fingerprint text;
  v_stage_fingerprint text;
begin
  if p_row_offset is null or p_row_offset<0 or p_expected_count is null
     or p_expected_count<1 or p_expected_count>5000 then
    raise exception 'Invalid staged batch bounds' using errcode='22023';
  end if;
  v_import := prospect_import.lock_active_claim_v2(p_import_id,p_list_id,p_worker_id,p_claim_token);
  if p_row_offset+p_expected_count <= v_import.committed_row_offset then
    return query select p_expected_count,0,0,0,v_import.committed_row_offset;
    return;
  end if;
  if p_row_offset <> v_import.committed_row_offset then
    raise exception 'Import cursor is a gap or partial replay' using errcode='P0002';
  end if;
  v_fingerprint := pg_catalog.md5(jsonb_build_object(
    'storageObjectPath',v_import.storage_object_path,
    'sourceHeaders',v_import.source_headers,
    'fieldMap',v_import.field_map
  )::text);
  select s.source_fingerprint into v_stage_fingerprint
  from prospect_import.staged_rows_v2 s
  where s.import_id=p_import_id and s.row_offset=p_row_offset;
  if v_stage_fingerprint is distinct from v_fingerprint then
    raise exception 'Durable stage no longer matches the import source mapping' using errcode='P0002';
  end if;
  select jsonb_agg(s.payload order by s.row_offset),count(*)::integer,min(s.row_offset),max(s.row_offset)
    into v_payload,v_count,v_min,v_max
  from (select row_offset,payload from prospect_import.staged_rows_v2
    where import_id=p_import_id and row_offset>=p_row_offset order by row_offset limit p_expected_count) s;
  if v_count<>p_expected_count or v_min<>p_row_offset or v_max<>p_row_offset+p_expected_count-1 then
    raise exception 'Durable stage is missing a contiguous batch' using errcode='P0002';
  end if;
  select * into v_base from prospect_import.import_prospect_batch_core_v2(p_import_id,p_list_id,v_payload,p_row_offset);
  delete from prospect_import.staged_rows_v2 where import_id=p_import_id
    and row_offset between p_row_offset and p_row_offset+p_expected_count-1;
  select i.committed_row_offset into committed_row_offset
  from public.imports i where i.id=p_import_id;
  processed:=v_base.processed; unique_added:=v_base.unique_added;
  duplicates_linked:=v_base.duplicates_linked; skipped:=v_base.skipped;
  return next;
end;
$function$;

create or replace function prospect_import.complete_core_v2(p_import_id text,p_list_id text)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare v_import public.imports; v_run_id uuid;
begin
  select * into v_import from public.imports where id=p_import_id and list_id=p_list_id for update;
  if v_import.id is null then raise exception 'Import not found' using errcode='P0002'; end if;
  if v_import.status='completed' then
    select id into v_run_id from prospect_verification.runs where source_import_id=p_import_id;
    return jsonb_build_object('summary',jsonb_build_object('processed_rows',v_import.processed_rows,
      'unique_added',v_import.unique_added,'duplicates_linked',v_import.duplicates_linked,
      'total_rows',v_import.total_rows,'status',v_import.status),'verificationRunId',v_run_id);
  end if;
  if v_import.status<>'processing' then raise exception 'Import is not processing' using errcode='40001'; end if;
  if v_import.total_rows is not null and v_import.processed_rows<>v_import.total_rows then raise exception 'Import has not committed every row' using errcode='40001'; end if;
  update public.imports set status='completed',completed_at=clock_timestamp(),worker_id=null,
    lease_expires_at=null,last_error=null where id=p_import_id returning * into v_import;
  update public.lists set uploaded_rows=v_import.processed_rows,unique_added=v_import.unique_added,
    duplicates_linked=v_import.duplicates_linked where id=p_list_id;
  if v_import.verify_work_emails then
    insert into prospect_verification.runs(request_id,payload_hash,source,source_import_id,scope,priority,status,started_at)
    values(gen_random_uuid(),pg_catalog.md5(jsonb_build_object('importId',p_import_id)::text),'import',p_import_id,'import',20,'preparing',clock_timestamp())
    on conflict(source_import_id) do update set source_import_id=excluded.source_import_id returning id into v_run_id;
    insert into prospect_verification.run_targets(run_id,prospect_id,normalized_email,email_revision,deletion_epoch,generation_floor)
    select v_run_id,p.id,prospect_verification.normalize_email(p.work_email),p.work_email_revision,
      coalesce(pd.deletion_epoch,0),coalesce((select max(ec.generation) from prospect_verification.email_checks ec
        where ec.normalized_email=prospect_verification.normalize_email(p.work_email) and ec.execution_state='completed'),0)
    from public.list_memberships lm join public.prospects p on p.id=lm.prospect_id
    left join prospect_verification.prospect_deletions pd on pd.prospect_id=p.id
    where lm.list_id=p_list_id and lm.import_id=p_import_id
      and nullif(prospect_verification.normalize_email(p.work_email),'') is not null on conflict do nothing;
    update prospect_verification.runs set total_count=(select count(*) from prospect_verification.run_targets where run_id=v_run_id),
      snapshot_complete=true,status=case when exists(select 1 from prospect_verification.run_targets where run_id=v_run_id) then 'running' else 'completed' end,
      completed_at=case when exists(select 1 from prospect_verification.run_targets where run_id=v_run_id) then null else clock_timestamp() end,
      updated_at=clock_timestamp() where id=v_run_id;
  end if;
  return jsonb_build_object('summary',jsonb_build_object('processed_rows',v_import.processed_rows,
    'unique_added',v_import.unique_added,'duplicates_linked',v_import.duplicates_linked,
    'total_rows',v_import.total_rows,'status',v_import.status),'verificationRunId',v_run_id);
end $function$;
revoke execute on function prospect_import.complete_core_v2(text,text)
  from public, anon, authenticated, service_role, prospect_importer;

create or replace function prospect_import.complete_claim_v2(
  p_import_id text,p_list_id text,p_worker_id text,p_claim_token uuid
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,prospect_import as $function$
declare v_import public.imports; v_payload jsonb; v_receipt uuid;
begin
  select * into v_import from public.imports i where i.id=p_import_id and i.list_id=p_list_id for update;
  if v_import.id is not null and v_import.import_protocol_version=2 and v_import.status='completed'
     and v_import.claim_token=p_claim_token then
    v_payload:=prospect_import.complete_core_v2(p_import_id,p_list_id);
    return v_payload || jsonb_build_object('completionReceipt',v_import.completion_receipt,'status','completed');
  end if;
  v_import:=prospect_import.lock_active_claim_v2(p_import_id,p_list_id,p_worker_id,p_claim_token);
  if v_import.total_rows is null or v_import.committed_row_offset<>v_import.total_rows then
    raise exception 'Import has not committed every staged row' using errcode='40001';
  end if;
  v_payload:=prospect_import.complete_core_v2(p_import_id,p_list_id);
  v_receipt:=gen_random_uuid();
  update public.imports set completion_receipt=v_receipt where id=p_import_id and claim_token=p_claim_token;
  return v_payload || jsonb_build_object('completionReceipt',v_receipt,'status','completed');
end $function$;

create or replace function prospect_import.retry_claim_v2(
  p_import_id text,p_list_id text,p_worker_id text,p_claim_token uuid,p_error text,
  p_retry_seconds integer default 30,p_max_attempts integer default 10
)
returns text language plpgsql security definer set search_path=pg_catalog,public,prospect_import as $function$
declare v_import public.imports; v_status text;
begin
  select * into v_import from public.imports i where i.id=p_import_id and i.list_id=p_list_id for update;
  if v_import.id is not null and v_import.status='completed' and v_import.claim_token=p_claim_token then return 'completed'; end if;
  v_import:=prospect_import.lock_active_claim_v2(p_import_id,p_list_id,p_worker_id,p_claim_token);
  update public.imports i set status=case when i.attempt_count>=greatest(1,p_max_attempts) then 'failed' else 'queued' end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_retry_seconds,3600))),
    worker_id=null,claim_token=null,lease_expires_at=null,
    last_error=left(coalesce(nullif(btrim(p_error),''),'Background import failed.'),1000)
  where i.id=p_import_id returning i.status into v_status;
  return v_status;
end $function$;

create or replace function prospect_import.analyze_after_import_v2()
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $function$
begin analyze public.prospect_index; return true; end $function$;

-- Legacy worker entry points may finish protocol 1, but cannot mutate a job
-- after a v2 claim has rotated ownership.
create or replace function public.claim_next_prospect_import_v1(p_worker_id text,p_lease_seconds integer default 300)
returns jsonb language plpgsql security definer set search_path=public set statement_timeout='5s' as $function$
declare v_id text; v_result jsonb;
begin
  if nullif(btrim(p_worker_id),'') is null then raise exception 'worker id is required' using errcode='22023'; end if;
  if p_lease_seconds<30 or p_lease_seconds>1800 then raise exception 'lease must be between 30 and 1800 seconds' using errcode='22023'; end if;
  select i.id into v_id from public.imports i where i.ingestion_mode='background' and i.import_protocol_version=1
    and i.next_attempt_at<=clock_timestamp() and (i.status='queued' or (i.status='processing' and coalesce(i.lease_expires_at,'-infinity'::timestamptz)<clock_timestamp()))
    order by i.created_at,i.id for update skip locked limit 1;
  if v_id is null then return null; end if;
  update public.imports i set status='processing',worker_id=p_worker_id,
    lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds),heartbeat_at=clock_timestamp(),
    started_at=coalesce(i.started_at,clock_timestamp()),attempt_count=i.attempt_count+1 where i.id=v_id
  returning jsonb_build_object('id',i.id,'listId',i.list_id,'fileName',i.file_name,'storageObjectPath',i.storage_object_path,
    'fileSizeBytes',i.file_size_bytes,'committedRowOffset',i.committed_row_offset,'totalRows',i.total_rows,
    'sourceHeaders',i.source_headers,'fieldMap',i.field_map,'attemptCount',i.attempt_count) into v_result;
  return v_result;
end $function$;

create or replace function public.heartbeat_prospect_import_v1(p_import_id text,p_worker_id text,p_lease_seconds integer default 300,p_total_rows integer default null,p_processed_bytes bigint default null)
returns boolean language plpgsql security definer set search_path=public set statement_timeout='5s' as $function$
declare changed integer;
begin
  update public.imports set lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(30,least(p_lease_seconds,1800))),
    heartbeat_at=clock_timestamp(),total_rows=coalesce(p_total_rows,total_rows),
    processed_bytes=greatest(processed_bytes,coalesce(p_processed_bytes,processed_bytes))
  where id=p_import_id and ingestion_mode='background' and import_protocol_version=1
    and status='processing' and worker_id=p_worker_id;
  get diagnostics changed=row_count; return changed=1;
end $function$;

create or replace function public.retry_prospect_import_v1(p_import_id text,p_worker_id text,p_error text,p_retry_seconds integer default 30,p_max_attempts integer default 10)
returns text language plpgsql security definer set search_path=public set statement_timeout='5s' as $function$
declare v_status text;
begin
  update public.imports i set status=case when i.attempt_count>=greatest(1,p_max_attempts) then 'failed' else 'queued' end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_retry_seconds,3600))),worker_id=null,
    lease_expires_at=null,last_error=left(coalesce(nullif(btrim(p_error),''),'Background import failed.'),1000)
  where i.id=p_import_id and i.ingestion_mode='background' and i.import_protocol_version=1
    and i.status='processing' and i.worker_id=p_worker_id returning i.status into v_status;
  return v_status;
end $function$;

-- Recreate the public cursor wrapper with a protocol guard.  Browser imports
-- and in-flight legacy background jobs retain exactly the old merge behavior.
create or replace function public.import_prospect_batch_v5(p_import_id text,p_list_id text,p_rows jsonb,p_row_offset integer)
returns table(processed integer,unique_added integer,duplicates_linked integer,skipped integer)
language plpgsql security definer set search_path=public set statement_timeout='15s' as $function$
declare v_base record; v_offset integer; v_protocol smallint; v_size integer:=jsonb_array_length(coalesce(p_rows,'[]'::jsonb));
begin
  if p_row_offset is null or p_row_offset<0 then raise exception 'A non-negative row offset is required' using errcode='22023'; end if;
  select i.committed_row_offset,i.import_protocol_version into v_offset,v_protocol from public.imports i
    where i.id=p_import_id and i.list_id=p_list_id and i.status='processing' for update;
  if not found then raise exception 'Import not found or already completed' using errcode='P0002'; end if;
  if v_protocol>=2 then raise exception 'Protocol 2 imports require a fenced batch' using errcode='P0002'; end if;
  if p_row_offset+v_size<=v_offset then return query select v_size,0,0,0; return; end if;
  select * into v_base from public.import_prospect_batch_v4(p_import_id,p_list_id,p_rows);
  perform public.reindex_prospects(array(select distinct lr.prospect_id from public.list_rows lr
    where lr.import_id=p_import_id and lr.prospect_id is not null and lr.source_row_number=any(
      select (elem->>'sourceRowNumber')::integer from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) elem
      where nullif(elem->>'sourceRowNumber','') is not null)));
  update public.imports set committed_row_offset=greatest(committed_row_offset,p_row_offset+v_size)
    where id=p_import_id and list_id=p_list_id;
  return query select v_base.processed,v_base.unique_added,v_base.duplicates_linked,v_base.skipped;
end $function$;

create or replace function prospect_import.process_staged_batch_v1(p_import_id text,p_list_id text,p_row_offset integer,p_batch_size integer default 1000)
returns table(processed integer,unique_added integer,duplicates_linked integer,skipped integer)
language plpgsql security definer set search_path=pg_catalog,public,prospect_import set statement_timeout='120s' as $function$
declare v_rows jsonb; v_count integer; v_first integer; v_last integer; v_base record;
begin
  if p_row_offset is null or p_row_offset<0 then raise exception 'A non-negative row offset is required' using errcode='22023'; end if;
  if p_batch_size<100 or p_batch_size>5000 then raise exception 'Batch size must be between 100 and 5000' using errcode='22023'; end if;
  if not exists(select 1 from public.imports i where i.id=p_import_id and i.list_id=p_list_id
    and i.status='processing' and i.import_protocol_version=1 and i.committed_row_offset=p_row_offset) then
    raise exception 'Import cursor does not match the requested staged batch' using errcode='P0002'; end if;
  select jsonb_agg(b.payload order by b.row_offset),count(*)::integer,min(b.row_offset),max(b.row_offset)
    into v_rows,v_count,v_first,v_last from (select row_offset,payload from prospect_import.staged_rows
      where import_id=p_import_id and row_offset>=p_row_offset order by row_offset limit p_batch_size)b;
  if v_count=0 then return query select 0,0,0,0; return; end if;
  if v_first<>p_row_offset or v_last<>p_row_offset+v_count-1 then raise exception 'Staged import rows are not contiguous at offset %',p_row_offset using errcode='P0002'; end if;
  select * into v_base from public.import_prospect_batch_v5(p_import_id,p_list_id,v_rows,p_row_offset);
  delete from prospect_import.staged_rows where import_id=p_import_id and row_offset between v_first and v_last;
  return query select v_base.processed,v_base.unique_added,v_base.duplicates_linked,v_base.skipped;
end $function$;

-- Keep the legacy completion name for browser and protocol-1 jobs.  It cannot
-- be used to finalize a fenced job through the old application slot.
create or replace function public.complete_prospect_import_v2(p_import_id text,p_list_id text)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare v_import public.imports;
begin
  select * into v_import from public.imports where id=p_import_id and list_id=p_list_id for update;
  if v_import.id is null then raise exception 'Import not found' using errcode='P0002'; end if;
  if v_import.ingestion_mode='background' and v_import.import_protocol_version>=2 then
    raise exception 'Protocol 2 imports require fenced completion' using errcode='P0002';
  end if;
  return prospect_import.complete_core_v2(p_import_id,p_list_id);
end $function$;

-- Keep the existing deletion function identity because both ordinary deletion
-- of a completed import and cancellation call it.  Taking the import lock
-- before the membership snapshot makes a concurrently admitted fenced batch
-- finish first; a later batch cannot start after cancellation removes the row.
create or replace function public.delete_import_and_reindex_v1(p_import_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_ids text[];
  v_result jsonb;
  v_reindex record;
begin
  perform 1 from public.imports i where i.id=p_import_id for update;
  if not found then
    raise exception 'Import not found' using errcode='P0002';
  end if;

  select coalesce(array_agg(distinct lr.prospect_id), array[]::text[]) into v_ids
  from public.list_rows lr
  where lr.import_id = p_import_id and lr.prospect_id is not null;

  v_result := public.delete_import_with_cleanup(p_import_id, false);
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  return v_result || jsonb_build_object('reindexed', v_reindex.reindexed, 'queued', v_reindex.queued);
end;
$function$;

create or replace function public.cancel_background_prospect_import_v2(p_import_id text)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare v_import public.imports; v_result jsonb;
begin
  select * into v_import from public.imports where id=p_import_id for update;
  if v_import.id is null then raise exception 'Import not found' using errcode='P0002'; end if;
  if v_import.ingestion_mode<>'background' or v_import.status not in ('queued','processing','failed') then
    raise exception 'Only an unfinished background import can be cancelled' using errcode='40001'; end if;
  select public.delete_import_and_reindex_v1(p_import_id) into v_result;
  return jsonb_build_object('result',v_result,'storageObjectPath',v_import.storage_object_path);
end $function$;

create or replace function public.requeue_background_prospect_import_v2(p_import_id text)
returns text language plpgsql security definer set search_path='' as $function$
declare v_status text;
begin
  perform 1 from public.imports where id=p_import_id for update;
  update public.imports set status='queued',import_protocol_version=2,attempt_count=0,
    next_attempt_at=clock_timestamp(),last_error=null,worker_id=null,claim_token=null,
    completion_receipt=null,lease_expires_at=null where id=p_import_id and ingestion_mode='background' and status='failed'
    returning status into v_status;
  if v_status is null then raise exception 'Only a failed background import can be retried' using errcode='40001'; end if;
  return v_status;
end $function$;

revoke execute on function prospect_import.claim_next_v2(text,integer) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.renew_claim_v2(text,text,text,uuid,integer,integer,bigint) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.claim_state_v2(text,text,text,uuid) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.stage_state_v2(text,text,text,uuid) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.publish_temp_stage_v2(text,text,text,uuid,regclass,integer,bigint) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.process_staged_batch_v2(text,text,text,uuid,integer,integer) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.complete_claim_v2(text,text,text,uuid) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.retry_claim_v2(text,text,text,uuid,text,integer,integer) from public,anon,authenticated,service_role;
revoke execute on function prospect_import.analyze_after_import_v2() from public,anon,authenticated,service_role;

grant execute on function prospect_import.claim_next_v2(text,integer) to prospect_importer;
grant execute on function prospect_import.renew_claim_v2(text,text,text,uuid,integer,integer,bigint) to prospect_importer;
grant execute on function prospect_import.claim_state_v2(text,text,text,uuid) to prospect_importer;
grant execute on function prospect_import.stage_state_v2(text,text,text,uuid) to prospect_importer;
grant execute on function prospect_import.publish_temp_stage_v2(text,text,text,uuid,regclass,integer,bigint) to prospect_importer;
grant execute on function prospect_import.process_staged_batch_v2(text,text,text,uuid,integer,integer) to prospect_importer;
grant execute on function prospect_import.complete_claim_v2(text,text,text,uuid) to prospect_importer;
grant execute on function prospect_import.retry_claim_v2(text,text,text,uuid,text,integer,integer) to prospect_importer;
grant execute on function prospect_import.analyze_after_import_v2() to prospect_importer;

revoke execute on function public.cancel_background_prospect_import_v2(text) from public,anon,authenticated;
revoke execute on function public.requeue_background_prospect_import_v2(text) from public,anon,authenticated;
grant execute on function public.cancel_background_prospect_import_v2(text) to service_role;
grant execute on function public.requeue_background_prospect_import_v2(text) to service_role;

-- Preserve the established legacy grants after CREATE OR REPLACE.
revoke execute on function public.claim_next_prospect_import_v1(text,integer) from public,anon,authenticated;
revoke execute on function public.heartbeat_prospect_import_v1(text,text,integer,integer,bigint) from public,anon,authenticated;
revoke execute on function public.retry_prospect_import_v1(text,text,text,integer,integer) from public,anon,authenticated;
revoke execute on function public.import_prospect_batch_v5(text,text,jsonb,integer) from public,anon,authenticated;
revoke execute on function public.complete_prospect_import_v2(text,text) from public,anon,authenticated;
revoke execute on function public.delete_import_and_reindex_v1(text) from public,anon,authenticated;
grant execute on function public.claim_next_prospect_import_v1(text,integer) to service_role;
grant execute on function public.heartbeat_prospect_import_v1(text,text,integer,integer,bigint) to service_role;
grant execute on function public.retry_prospect_import_v1(text,text,text,integer,integer) to service_role;
grant execute on function public.import_prospect_batch_v5(text,text,jsonb,integer) to service_role;
grant execute on function public.complete_prospect_import_v2(text,text) to service_role;
grant execute on function public.delete_import_and_reindex_v1(text) to service_role;
revoke execute on function prospect_import.process_staged_batch_v1(text,text,integer,integer) from public,anon,authenticated;
grant execute on function prospect_import.process_staged_batch_v1(text,text,integer,integer) to prospect_importer;

comment on column public.imports.import_protocol_version is
  'Background-import mutation protocol. Version 2 requires the rotating claim_token fence; browser imports remain version 1.';
comment on table prospect_import.staged_rows_v2 is
  'Private durable rows published atomically from a connection-local COPY buffer after validating a live protocol-2 claim.';

-- Bounded structural proof only. Runtime races and row behavior are exercised
-- against independent connections in the disposable CI database.
do $proof$
begin
  if has_table_privilege('prospect_importer','prospect_import.staged_rows_v2','SELECT')
     or has_table_privilege('prospect_importer','prospect_import.staged_rows_v2','INSERT')
     or has_table_privilege('prospect_importer','prospect_import.staged_rows_v2','UPDATE')
     or has_table_privilege('prospect_importer','prospect_import.staged_rows_v2','DELETE') then
    raise exception 'prospect_importer can bypass fenced durable-stage publication';
  end if;
  if has_function_privilege('prospect_importer','prospect_import.import_prospect_batch_core_v2(text,text,jsonb,integer)','EXECUTE')
     or has_function_privilege('prospect_importer','prospect_import.complete_core_v2(text,text)','EXECUTE')
     or has_function_privilege('prospect_importer','public.import_prospect_batch_v5(text,text,jsonb,integer)','EXECUTE') then
    raise exception 'prospect_importer can bypass a fenced protocol-2 mutation';
  end if;
  if not has_function_privilege('prospect_importer','prospect_import.claim_next_v2(text,integer)','EXECUTE')
     or not has_function_privilege('prospect_importer','prospect_import.publish_temp_stage_v2(text,text,text,uuid,regclass,integer,bigint)','EXECUTE')
     or not has_function_privilege('prospect_importer','prospect_import.process_staged_batch_v2(text,text,text,uuid,integer,integer)','EXECUTE')
     or not has_function_privilege('prospect_importer','prospect_import.complete_claim_v2(text,text,text,uuid)','EXECUTE') then
    raise exception 'prospect_importer is missing a required fenced protocol-2 function';
  end if;
  if has_function_privilege('anon','prospect_import.claim_next_v2(text,integer)','EXECUTE')
     or has_function_privilege('authenticated','prospect_import.claim_next_v2(text,integer)','EXECUTE')
     or has_function_privilege('service_role','prospect_import.claim_next_v2(text,integer)','EXECUTE') then
    raise exception 'an application role can claim private background imports';
  end if;
end;
$proof$;
