-- Durable, server-side prospect imports. The uploaded object is durable; the
-- worker is disposable and can reclaim an expired lease after any restart.
alter table public.imports
  add column if not exists ingestion_mode text not null default 'browser',
  add column if not exists storage_object_path text,
  add column if not exists source_headers jsonb not null default '[]'::jsonb,
  add column if not exists file_size_bytes bigint,
  add column if not exists processed_bytes bigint not null default 0,
  add column if not exists worker_id text,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists started_at timestamptz,
  add column if not exists heartbeat_at timestamptz,
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists attempt_count integer not null default 0,
  add column if not exists last_error text;

alter table public.imports
  drop constraint if exists imports_ingestion_mode_valid;
alter table public.imports
  add constraint imports_ingestion_mode_valid
  check (ingestion_mode in ('browser', 'background'));

alter table public.imports
  drop constraint if exists imports_background_object_required;
alter table public.imports
  add constraint imports_background_object_required
  check (ingestion_mode <> 'background' or nullif(storage_object_path, '') is not null);

alter table public.imports
  drop constraint if exists imports_background_counters_nonnegative;
alter table public.imports
  add constraint imports_background_counters_nonnegative
  check (processed_bytes >= 0 and attempt_count >= 0 and coalesce(file_size_bytes, 0) >= 0);

create index if not exists idx_imports_background_queue
  on public.imports (next_attempt_at, created_at)
  where ingestion_mode = 'background' and status in ('queued', 'processing');

create or replace function public.claim_next_prospect_import_v1(
  p_worker_id text,
  p_lease_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '5s'
as $function$
declare
  import_id_value text;
  result_value jsonb;
begin
  if nullif(btrim(p_worker_id), '') is null then
    raise exception 'worker id is required' using errcode = '22023';
  end if;
  if p_lease_seconds < 30 or p_lease_seconds > 1800 then
    raise exception 'lease must be between 30 and 1800 seconds' using errcode = '22023';
  end if;

  select i.id into import_id_value
  from public.imports i
  where i.ingestion_mode = 'background'
    and i.next_attempt_at <= now()
    and (
      i.status = 'queued'
      or (i.status = 'processing' and coalesce(i.lease_expires_at, '-infinity'::timestamptz) < now())
    )
  order by i.created_at, i.id
  for update skip locked
  limit 1;

  if import_id_value is null then
    return null;
  end if;

  update public.imports i
  set status = 'processing',
      worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      heartbeat_at = now(),
      started_at = coalesce(i.started_at, now()),
      attempt_count = i.attempt_count + 1
  where i.id = import_id_value
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
    'attemptCount', i.attempt_count
  ) into result_value;

  return result_value;
end;
$function$;

create or replace function public.heartbeat_prospect_import_v1(
  p_import_id text,
  p_worker_id text,
  p_lease_seconds integer default 300,
  p_total_rows integer default null,
  p_processed_bytes bigint default null
)
returns boolean
language plpgsql
security definer
set search_path = public
set statement_timeout = '5s'
as $function$
declare
  changed integer;
begin
  update public.imports
  set lease_expires_at = now() + make_interval(secs => greatest(30, least(p_lease_seconds, 1800))),
      heartbeat_at = now(),
      total_rows = coalesce(p_total_rows, total_rows),
      processed_bytes = greatest(processed_bytes, coalesce(p_processed_bytes, processed_bytes))
  where id = p_import_id
    and ingestion_mode = 'background'
    and status = 'processing'
    and worker_id = p_worker_id;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$function$;

create or replace function public.retry_prospect_import_v1(
  p_import_id text,
  p_worker_id text,
  p_error text,
  p_retry_seconds integer default 30,
  p_max_attempts integer default 10
)
returns text
language plpgsql
security definer
set search_path = public
set statement_timeout = '5s'
as $function$
declare
  next_status text;
begin
  update public.imports i
  set status = case when i.attempt_count >= greatest(1, p_max_attempts) then 'failed' else 'queued' end,
      next_attempt_at = now() + make_interval(secs => greatest(1, least(p_retry_seconds, 3600))),
      worker_id = null,
      lease_expires_at = null,
      last_error = left(coalesce(nullif(btrim(p_error), ''), 'Background import failed.'), 1000)
  where i.id = p_import_id
    and i.ingestion_mode = 'background'
    and i.status = 'processing'
    and i.worker_id = p_worker_id
  returning i.status into next_status;
  return next_status;
end;
$function$;

revoke execute on function public.claim_next_prospect_import_v1(text, integer) from public, anon, authenticated;
revoke execute on function public.heartbeat_prospect_import_v1(text, text, integer, integer, bigint) from public, anon, authenticated;
revoke execute on function public.retry_prospect_import_v1(text, text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.claim_next_prospect_import_v1(text, integer) to service_role;
grant execute on function public.heartbeat_prospect_import_v1(text, text, integer, integer, bigint) to service_role;
grant execute on function public.retry_prospect_import_v1(text, text, text, integer, integer) to service_role;
