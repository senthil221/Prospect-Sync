-- Client workspace feature pack: folders/archive, durable provenance batches,
-- blocklist shares/bulk operations, and one canonical per-company people cap.
-- All tables in public are server-only: the browser reaches them through
-- authenticated route handlers, or through a hashed revocable share token.

begin;

-- 1. Client folders and archive ------------------------------------------------

create table if not exists public.client_folders (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  normalized_name text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint client_folders_name_present check (btrim(name) <> '')
);

alter table public.clients
  add column if not exists folder_id uuid references public.client_folders(id) on delete set null,
  add column if not exists archived_at timestamptz;

create index if not exists idx_clients_folder_active
  on public.clients (folder_id, name) where archived_at is null;
create index if not exists idx_clients_archived
  on public.clients (archived_at desc, name) where archived_at is not null;

alter table public.client_folders enable row level security;
revoke all on public.client_folders from public, anon, authenticated;
grant select, insert, update, delete on public.client_folders to service_role;

-- 5. Durable provenance batches ----------------------------------------------

create table if not exists public.client_addition_batches (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references public.clients(id) on delete cascade,
  entity_type text not null check (entity_type in ('people', 'companies')),
  source_kind text not null check (source_kind in ('import', 'master', 'client')),
  source_label text not null default '',
  source_client_id text references public.clients(id) on delete set null,
  outcome_kind text not null default 'new_memberships'
    check (outcome_kind in ('new_memberships','historical_import_rows','historical_source_unavailable')),
  request_key text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  created_by text not null default '',
  constraint client_addition_batches_source_client check (
    (source_kind = 'client' and (source_client_id is not null or btrim(source_label) <> ''))
    or (source_kind <> 'client' and source_client_id is null)
  )
);

create unique index if not exists uq_client_addition_batch_request
  on public.client_addition_batches (client_id, entity_type, request_key)
  where request_key is not null and request_key <> '';
create index if not exists idx_client_addition_batches_recent
  on public.client_addition_batches (client_id, created_at desc, id);

create table if not exists public.client_addition_batch_items (
  batch_id uuid not null references public.client_addition_batches(id) on delete cascade,
  entity_id text not null,
  added_at timestamptz not null default now(),
  primary key (batch_id, entity_id)
);
create index if not exists idx_client_addition_batch_items_entity
  on public.client_addition_batch_items (entity_id, batch_id);

alter table public.client_addition_batches enable row level security;
alter table public.client_addition_batch_items enable row level security;
revoke all on public.client_addition_batches, public.client_addition_batch_items from public, anon, authenticated;
grant select, insert, update, delete on public.client_addition_batches, public.client_addition_batch_items to service_role;

-- 11/12. Fixed block reasons and submission-only revocable links --------------

create or replace function public.enforce_client_blocklist_reason_v1()
returns trigger
language plpgsql
security invoker
set search_path = public
as $function$
begin
  -- Historical free-text reasons remain readable and removable. Only a new
  -- value, or a reason change, must use the current product vocabulary.
  if (tg_op = 'INSERT' or new.reason is distinct from old.reason)
     and new.reason not in ('Client Provided', 'ICP Invalid', 'Campaign Reply') then
    raise exception 'Choose Client Provided, ICP Invalid, or Campaign Reply.' using errcode = '22023';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_client_blocklist_reason on public.client_blocklist;
create trigger trg_client_blocklist_reason
  before insert or update of reason on public.client_blocklist
  for each row execute function public.enforce_client_blocklist_reason_v1();
revoke execute on function public.enforce_client_blocklist_reason_v1() from public, anon, authenticated;

create table if not exists public.client_blocklist_shares (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references public.clients(id) on delete cascade,
  token_hash text not null unique,
  label text not null default '',
  created_by text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  last_submitted_at timestamptz
);
create index if not exists idx_client_blocklist_shares_client
  on public.client_blocklist_shares (client_id, created_at desc);

create table if not exists public.client_blocklist_share_limits (
  share_id uuid not null references public.client_blocklist_shares(id) on delete cascade,
  requester_hash text not null,
  window_started_at timestamptz not null,
  attempts integer not null default 0,
  primary key (share_id, requester_hash)
);

create table if not exists public.client_blocklist_share_submissions (
  id uuid primary key default gen_random_uuid(),
  share_id uuid not null references public.client_blocklist_shares(id) on delete cascade,
  client_id text not null references public.clients(id) on delete cascade,
  request_key uuid not null,
  domains text[] not null default array[]::text[],
  emails text[] not null default array[]::text[],
  reason text not null,
  status text not null default 'queued' check (status in ('queued','running','completed','failed')),
  attempts integer not null default 0,
  worker_id text,
  lease_expires_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (share_id, request_key)
);
create index if not exists idx_client_blocklist_share_submissions_queue
  on public.client_blocklist_share_submissions (created_at)
  where status in ('queued','running');

alter table public.client_blocklist_shares enable row level security;
alter table public.client_blocklist_share_limits enable row level security;
alter table public.client_blocklist_share_submissions enable row level security;
revoke all on public.client_blocklist_shares, public.client_blocklist_share_limits,
  public.client_blocklist_share_submissions from public, anon, authenticated;
grant select, insert, update, delete on public.client_blocklist_shares, public.client_blocklist_share_limits,
  public.client_blocklist_share_submissions to service_role;

create or replace function public.consume_blocklist_share_rate_v1(
  p_share_id uuid,
  p_requester_hash text,
  p_limit integer default 20,
  p_window interval default interval '1 hour'
)
returns boolean
language plpgsql
security definer
set search_path = public
set statement_timeout = '5s'
as $function$
declare
  v_attempts integer;
begin
  insert into public.client_blocklist_share_limits
    (share_id, requester_hash, window_started_at, attempts)
  values (p_share_id, left(coalesce(p_requester_hash, ''), 128), now(), 1)
  on conflict (share_id, requester_hash) do update set
    window_started_at = case
      when client_blocklist_share_limits.window_started_at <= now() - p_window then now()
      else client_blocklist_share_limits.window_started_at
    end,
    attempts = case
      when client_blocklist_share_limits.window_started_at <= now() - p_window then 1
      else client_blocklist_share_limits.attempts + 1
    end
  returning attempts into v_attempts;
  return v_attempts <= greatest(1, least(coalesce(p_limit, 20), 100));
end;
$function$;

revoke execute on function public.consume_blocklist_share_rate_v1(uuid, text, integer, interval)
  from public, anon, authenticated;
grant execute on function public.consume_blocklist_share_rate_v1(uuid, text, integer, interval)
  to service_role;

create or replace function public.enqueue_blocklist_share_submission_v1(
  p_token_hash text,
  p_requester_hash text,
  p_request_key uuid,
  p_domains text[],
  p_emails text[],
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
set statement_timeout = '10s'
as $function$
declare v_share public.client_blocklist_shares%rowtype; v_id uuid;
begin
  select * into v_share from public.client_blocklist_shares
  where token_hash = p_token_hash and revoked_at is null
    and (expires_at is null or expires_at > now()) for update;
  if not found then raise exception 'Share unavailable' using errcode = 'P0002'; end if;
  select id into v_id from public.client_blocklist_share_submissions
    where share_id = v_share.id and request_key = p_request_key;
  if v_id is not null then return v_id; end if;
  if p_reason not in ('Client Provided', 'ICP Invalid', 'Campaign Reply') then
    raise exception 'Invalid reason' using errcode = '22023';
  end if;
  if cardinality(coalesce(p_domains, array[]::text[])) + cardinality(coalesce(p_emails, array[]::text[])) > 200 then
    raise exception 'Too many entries' using errcode = '22023';
  end if;
  if not public.consume_blocklist_share_rate_v1(v_share.id, 'requester:' || p_requester_hash, 20, interval '1 hour')
     or not public.consume_blocklist_share_rate_v1(v_share.id, 'global', 200, interval '1 hour') then
    raise exception 'Rate limit' using errcode = 'P0003';
  end if;
  insert into public.client_blocklist_share_submissions
    (share_id, client_id, request_key, domains, emails, reason)
  values (v_share.id, v_share.client_id, p_request_key,
    coalesce(p_domains, array[]::text[]), coalesce(p_emails, array[]::text[]), p_reason)
  returning id into v_id;
  update public.client_blocklist_shares set last_submitted_at = now() where id = v_share.id;
  return v_id;
end;
$function$;

create or replace function public.run_blocklist_share_submission_unit_v1(
  p_worker text,
  p_match_limit integer default 5000
)
returns table(job_id uuid, done boolean)
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare v_job public.client_blocklist_share_submissions%rowtype; v_result jsonb; v_done boolean;
begin
  if coalesce(btrim(p_worker), '') = '' or length(p_worker) > 200 then
    raise exception 'Invalid worker' using errcode = '22023';
  end if;
  if not pg_try_advisory_xact_lock(hashtextextended('prospect-background-unit-v1', 0)) then return; end if;
  delete from public.client_blocklist_share_limits where window_started_at < now() - interval '2 hours';
  delete from public.client_blocklist_share_submissions
    where status in ('completed','failed') and coalesce(completed_at, created_at) < now() - interval '30 days';
  select * into v_job from public.client_blocklist_share_submissions s
  where s.status = 'queued' or (s.status = 'running' and s.lease_expires_at <= now())
  order by s.created_at for update skip locked limit 1;
  if not found then return; end if;
  update public.client_blocklist_share_submissions set status = 'running', worker_id = p_worker,
    lease_expires_at = now() + interval '5 minutes' where id = v_job.id;
  begin
    v_result := public.add_client_blocklist_batch_v2(v_job.client_id, v_job.domains, v_job.emails,
      v_job.reason, 'client-share:' || v_job.share_id,
      v_job.request_key::text || ':' || v_job.attempts::text, p_match_limit);
    v_done := not coalesce((v_result ->> 'remaining')::boolean, false);
    update public.client_blocklist_share_submissions set attempts = attempts + 1,
      status = case when v_done then 'completed' else 'queued' end,
      worker_id = null, lease_expires_at = null,
      completed_at = case when v_done then now() else null end, last_error = null
    where id = v_job.id;
  exception when others or query_canceled then
    update public.client_blocklist_share_submissions set attempts = attempts + 1,
      status = case when attempts >= 4 then 'failed' else 'queued' end,
      worker_id = null, lease_expires_at = null,
      last_error = 'Submission processing failed (SQLSTATE ' || sqlstate || ').'
    where id = v_job.id;
    v_done := (v_job.attempts >= 4);
  end;
  return query select v_job.id, v_done;
end;
$function$;

revoke execute on function public.enqueue_blocklist_share_submission_v1(text, text, uuid, text[], text[], text)
  from public, anon, authenticated;
revoke execute on function public.run_blocklist_share_submission_unit_v1(text, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.enqueue_blocklist_share_submission_v1(text, text, uuid, text[], text[], text)
  to service_role;
grant execute on function public.run_blocklist_share_submission_unit_v1(text, integer)
  to prospect_operator;

-- One retry-safe entry point for imports and both push paths. The request key
-- is unique inside a client/entity pair, and item insertion is idempotent.
create or replace function public.record_client_addition_batch_v1(
  p_client_id text,
  p_entity_type text,
  p_source_kind text,
  p_source_label text,
  p_source_client_id text,
  p_request_key text,
  p_entity_ids text[],
  p_actor text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
set statement_timeout = '30s'
as $function$
declare
  v_batch_id uuid;
  v_key text := nullif(left(btrim(coalesce(p_request_key, '')), 200), '');
begin
  if p_entity_type not in ('people', 'companies') then
    raise exception 'Unknown batch entity type' using errcode = '22023';
  end if;
  if p_source_kind not in ('import', 'master', 'client') then
    raise exception 'Unknown batch source' using errcode = '22023';
  end if;
  if p_source_kind = 'client' and (p_source_client_id is null or p_source_client_id = p_client_id) then
    raise exception 'A client push needs a different source client' using errcode = '22023';
  end if;

  if v_key is not null then
    insert into public.client_addition_batches
      (client_id, entity_type, source_kind, source_label, source_client_id,
       request_key, created_by)
    values
      (p_client_id, p_entity_type, p_source_kind,
       left(coalesce(p_source_label, ''), 300),
       case when p_source_kind = 'client' then p_source_client_id else null end,
       v_key, left(coalesce(p_actor, ''), 200))
    on conflict (client_id, entity_type, request_key)
      where request_key is not null and request_key <> ''
    do update set source_label = excluded.source_label
    returning id into v_batch_id;
  else
    insert into public.client_addition_batches
      (client_id, entity_type, source_kind, source_label, source_client_id, created_by)
    values
      (p_client_id, p_entity_type, p_source_kind,
       left(coalesce(p_source_label, ''), 300),
       case when p_source_kind = 'client' then p_source_client_id else null end,
       left(coalesce(p_actor, ''), 200))
    returning id into v_batch_id;
  end if;

  insert into public.client_addition_batch_items (batch_id, entity_id)
  select v_batch_id, selected.id
  from unnest(coalesce(p_entity_ids, array[]::text[])) selected(id)
  where btrim(selected.id) <> ''
  on conflict (batch_id, entity_id) do nothing;

  update public.client_addition_batches
  set completed_at = coalesce(completed_at, now())
  where id = v_batch_id;
  return v_batch_id;
end;
$function$;

revoke execute on function public.record_client_addition_batch_v1(text, text, text, text, text, text, text[], text)
  from public, anon, authenticated;
grant execute on function public.record_client_addition_batch_v1(text, text, text, text, text, text, text[], text)
  to service_role;

-- Persist import provenance when a relationship is actually inserted. The
-- import worker commits at most 5,000 rows per chunk, so the transition-table
-- array below is bounded. ON CONFLICT updates are deliberately absent from the
-- transition table: importing someone already in this client is not a new
-- Recently Added record.
alter table public.client_prospects
  add column if not exists source_import_id text references public.imports(id) on delete set null;
alter table public.client_prospects
  add column if not exists source_push_request_id text,
  add column if not exists source_push_client_id text references public.clients(id) on delete set null,
  add column if not exists source_push_label text,
  add column if not exists source_push_actor text;

create or replace function public.sync_client_prospects_from_lists()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    with incoming as (
      select l.client_id, n.prospect_id, min(i.prospect_date_added) as date_added,
        (array_agg(n.import_id order by n.import_id) filter (where n.import_id is not null))[1] as source_import_id
      from new_rows n
      join public.lists l on l.id = n.list_id
      left join public.imports i on i.id = n.import_id
      where n.prospect_id is not null
      group by l.client_id, n.prospect_id
    )
    insert into public.client_prospects (
      client_id, prospect_id, added_via, date_added, source_import_id,
      status, blocked_reason, blocked_at
    )
    select incoming.client_id, incoming.prospect_id, 'import', incoming.date_added,
      incoming.source_import_id,
      case when block.reason is null then 'active' else 'blocked' end,
      coalesce(block.reason, ''), case when block.reason is null then null else now() end
    from incoming
    left join lateral (
      select public.client_block_reason_v1(incoming.client_id, incoming.prospect_id) as reason
    ) block on true
    on conflict (client_id, prospect_id) do update set
      date_added = case
        when excluded.date_added is null then public.client_prospects.date_added
        when public.client_prospects.date_added is null then excluded.date_added
        else least(public.client_prospects.date_added, excluded.date_added)
      end,
      status = case when excluded.status = 'blocked' then 'blocked' else public.client_prospects.status end,
      blocked_reason = case when excluded.status = 'blocked' then excluded.blocked_reason else public.client_prospects.blocked_reason end,
      blocked_at = case when excluded.status = 'blocked' then coalesce(public.client_prospects.blocked_at, excluded.blocked_at) else public.client_prospects.blocked_at end;
  end if;
  if tg_op in ('DELETE', 'UPDATE') then
    delete from public.client_prospects cp
    using (
      select distinct l.client_id, o.prospect_id from old_rows o
      join public.lists l on l.id = o.list_id where o.prospect_id is not null
    ) removed
    where cp.client_id = removed.client_id and cp.prospect_id = removed.prospect_id
      and cp.added_via = 'import'
      and not exists (
        select 1 from public.list_memberships lm join public.lists l2 on l2.id = lm.list_id
        where l2.client_id = cp.client_id and lm.prospect_id = cp.prospect_id
      );
  end if;
  return null;
end;
$function$;

create or replace function public.record_new_import_people_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare v_group record;
begin
  for v_group in
    select i.id as import_id, i.client_id, i.file_name,
      array_agg(n.prospect_id order by n.prospect_id) as ids
    from new_client_rows n join public.imports i on i.id = n.source_import_id
    where n.source_import_id is not null
    group by i.id, i.client_id, i.file_name
  loop
    perform public.record_client_addition_batch_v1(
      v_group.client_id, 'people', 'import', v_group.file_name, null,
      'import:' || v_group.import_id, v_group.ids, 'import-worker');
  end loop;
  return null;
end;
$function$;
drop trigger if exists client_prospects_record_import_people_v1 on public.client_prospects;
create trigger client_prospects_record_import_people_v1
after insert on public.client_prospects
referencing new table as new_client_rows
for each statement execute function public.record_new_import_people_v1();
revoke execute on function public.record_new_import_people_v1() from public, anon, authenticated;

-- The existing row trigger creates a client-company membership as soon as a
-- person is added. Record only the company INSERT that succeeds, using the same
-- import request key, so a many-person company appears once in one logical
-- company batch and retries stay idempotent.
create or replace function public.sync_client_company_membership_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare v_company_id text; v_added text; v_import public.imports%rowtype;
begin
  select p.company_id into v_company_id from public.prospects p where p.id = new.prospect_id;
  if v_company_id is not null then
    insert into public.client_companies (client_id, company_id, added_by)
    values (new.client_id, v_company_id, 'prospect-membership')
    on conflict (client_id, company_id) do nothing
    returning company_id into v_added;
    if v_added is not null and new.source_import_id is not null then
      select * into v_import from public.imports where id = new.source_import_id;
      if found then
        perform public.record_client_addition_batch_v1(
          new.client_id, 'companies', 'import', v_import.file_name, null,
          'import:' || v_import.id, array[v_added], 'import-worker');
      end if;
    end if;
    if v_added is not null and new.source_push_request_id is not null then
      perform public.record_client_addition_batch_v1(
        new.client_id, 'companies',
        case when new.source_push_client_id is null then 'master' else 'client' end,
        coalesce(nullif(new.source_push_label, ''), 'Master DB'),
        new.source_push_client_id,
        new.source_push_request_id || ':companies', array[v_added],
        coalesce(new.source_push_actor, ''));
    end if;
  end if;
  return new;
end;
$function$;

-- Completion performs O(1) updates. All item capture happened transactionally
-- in bounded import chunks; no completion-time array aggregation can roll a
-- large import back.
create or replace function public.record_completed_import_batch_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if new.status = 'completed' and old.status is distinct from new.status then
    update public.client_addition_batches
      set completed_at = coalesce(new.completed_at, now())
      where client_id = new.client_id and request_key = 'import:' || new.id
        and source_kind = 'import';
  end if;
  return new;
end;
$function$;
drop trigger if exists imports_record_completed_batch_v1 on public.imports;
create trigger imports_record_completed_batch_v1
after update of status on public.imports
for each row execute function public.record_completed_import_batch_v1();
revoke execute on function public.record_completed_import_batch_v1()
  from public, anon, authenticated;

-- Batches, filtered by both source label and the records inside them. Search is
-- applied before pagination; one row is one batch rather than one prospect.
create or replace function public.client_recent_batches_v1(
  p_client_id text,
  p_search text default '',
  p_entity text default '',
  p_hours integer default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $function$
  with matched as materialized (
    select b.id, b.entity_type, b.source_kind, b.source_label, b.outcome_kind,
      b.source_client_id, source_client.name as source_client_name,
      b.created_at, b.completed_at,
      count(i.entity_id)::bigint as record_count
    from public.client_addition_batches b
    left join public.client_addition_batch_items i on i.batch_id = b.id
    left join public.clients source_client on source_client.id = b.source_client_id
    where b.client_id = p_client_id
      and (coalesce(p_entity, '') = '' or b.entity_type = p_entity)
      and (p_hours is null or b.created_at >= now() - make_interval(hours => greatest(1, least(p_hours, 24 * 3650))))
      and (
        btrim(coalesce(p_search, '')) = ''
        or b.source_label ilike '%' || p_search || '%'
        or source_client.name ilike '%' || p_search || '%'
        or exists (
          select 1
          from public.client_addition_batch_items searched
          left join public.prospect_index pi
            on b.entity_type = 'people' and pi.id = searched.entity_id
          left join public.companies co
            on b.entity_type = 'companies' and co.id = searched.entity_id
          where searched.batch_id = b.id
            and (pi.search_text ilike '%' || p_search || '%'
              or co.name ilike '%' || p_search || '%'
              or co.domain ilike '%' || p_search || '%')
        )
      )
    group by b.id, source_client.name
  ), page_rows as (
    select * from matched
    order by created_at desc, id desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows) order by created_at desc, id desc)
    from page_rows), '[]'::jsonb), (select count(*) from matched);
$function$;

revoke execute on function public.client_recent_batches_v1(text, text, text, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.client_recent_batches_v1(text, text, text, integer, integer, integer)
  to service_role;

create or replace function public.client_addition_batch_records_v1(
  p_client_id text,
  p_batch_id uuid,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $function$
declare v_entity text;
begin
  select entity_type into v_entity from public.client_addition_batches
  where id = p_batch_id and client_id = p_client_id;
  if v_entity is null then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if v_entity = 'people' then
    return query with matched as materialized (
      select pi.id as record_id, pi.full_name as display_name,
        coalesce(pi.company_name, pi.work_email) as secondary_text, i.added_at
      from public.client_addition_batch_items i
      join public.prospect_index pi on pi.id = i.entity_id
      where i.batch_id = p_batch_id
    ), page_rows as (
      select * from matched order by added_at desc, record_id
      limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
    ) select coalesce((select jsonb_agg(to_jsonb(page_rows) order by added_at desc, record_id) from page_rows), '[]'::jsonb),
      (select count(*) from matched);
  else
    return query with matched as materialized (
      select co.id as record_id, co.name as display_name,
        co.domain as secondary_text, i.added_at
      from public.client_addition_batch_items i
      join public.companies co on co.id = i.entity_id
      where i.batch_id = p_batch_id
    ), page_rows as (
      select * from matched order by added_at desc, record_id
      limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
    ) select coalesce((select jsonb_agg(to_jsonb(page_rows) order by added_at desc, record_id) from page_rows), '[]'::jsonb),
      (select count(*) from matched);
  end if;
end;
$function$;
revoke execute on function public.client_addition_batch_records_v1(text, uuid, integer, integer)
  from public, anon, authenticated;
grant execute on function public.client_addition_batch_records_v1(text, uuid, integer, integer)
  to service_role;

-- Backfill one batch per historical import, then retain older push membership
-- in explicit "Source unavailable" batches. No historical row is relabelled as
-- a master/client push when the source cannot be proved.
insert into public.client_addition_batches
  (client_id, entity_type, source_kind, source_label, outcome_kind, request_key, created_at, completed_at)
select i.client_id, 'people', 'import', coalesce(nullif(i.file_name, ''), l.name),
  'historical_import_rows', 'import:' || i.id, i.created_at, coalesce(i.completed_at, i.created_at)
from public.imports i join public.lists l on l.id = i.list_id
where i.status = 'completed'
on conflict (client_id, entity_type, request_key)
  where request_key is not null and request_key <> '' do nothing;

insert into public.client_addition_batch_items (batch_id, entity_id, added_at)
select b.id, lm.prospect_id, lm.imported_at
from public.imports i
join public.client_addition_batches b on b.request_key = 'import:' || i.id
  and b.client_id = i.client_id and b.entity_type = 'people'
join public.list_memberships lm on lm.import_id = i.id
on conflict (batch_id, entity_id) do nothing;

insert into public.client_addition_batches
  (client_id, entity_type, source_kind, source_label, outcome_kind, request_key, created_at, completed_at)
select cp.client_id, 'people', 'master', 'Source unavailable',
  'historical_source_unavailable', 'legacy:people', min(cp.added_at), max(cp.added_at)
from public.client_prospects cp
where cp.added_via <> 'import'
group by cp.client_id
on conflict (client_id, entity_type, request_key)
  where request_key is not null and request_key <> '' do nothing;

insert into public.client_addition_batch_items (batch_id, entity_id, added_at)
select b.id, cp.prospect_id, cp.added_at
from public.client_addition_batches b
join public.client_prospects cp on cp.client_id = b.client_id and cp.added_via <> 'import'
where b.entity_type = 'people' and b.request_key = 'legacy:people'
on conflict (batch_id, entity_id) do nothing;

insert into public.client_addition_batches
  (client_id, entity_type, source_kind, source_label, outcome_kind, request_key, created_at, completed_at)
select cc.client_id, 'companies', 'master', 'Source unavailable',
  'historical_source_unavailable', 'legacy:companies', min(cc.added_at), max(cc.added_at)
from public.client_companies cc
group by cc.client_id
on conflict (client_id, entity_type, request_key)
  where request_key is not null and request_key <> '' do nothing;

insert into public.client_addition_batch_items (batch_id, entity_id, added_at)
select b.id, cc.company_id, cc.added_at
from public.client_addition_batches b
join public.client_companies cc on cc.client_id = b.client_id
where b.entity_type = 'companies' and b.request_key = 'legacy:companies'
on conflict (batch_id, entity_id) do nothing;

-- Blocklist filtering and all-result bulk mutations share this resolver.
create or replace function public.client_blocklist_selection_v1(
  p_client_id text,
  p_ids text[] default null,
  p_all_matching boolean default false,
  p_search text default '',
  p_kind text default '',
  p_date_from date default null,
  p_date_to date default null,
  p_excluded_ids text[] default null,
  p_selected_before timestamptz default null,
  p_limit integer default 250000
)
returns table(entry_id text)
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $function$
  select b.id
  from public.client_blocklist b
  where b.client_id = p_client_id
    and (
      (not coalesce(p_all_matching, false) and p_ids is not null and b.id = any(p_ids))
      or (coalesce(p_all_matching, false)
        and (btrim(coalesce(p_search, '')) = '' or b.value ilike '%' || p_search || '%')
        and (btrim(coalesce(p_kind, '')) = '' or b.kind = p_kind)
        and (p_date_from is null or b.created_at >= (p_date_from::text || 'T00:00:00Z')::timestamptz)
        and (p_date_to is null or b.created_at < ((p_date_to + 1)::text || 'T00:00:00Z')::timestamptz)
        and (p_selected_before is null or b.created_at <= p_selected_before))
    )
    and not (b.id = any(coalesce(p_excluded_ids, array[]::text[])))
  order by b.created_at desc, b.id
  limit greatest(1, least(coalesce(p_limit, 250001), 250001));
$function$;

create or replace function public.client_blocklist_selection_count_v1(
  p_client_id text,
  p_ids text[] default null,
  p_all_matching boolean default false,
  p_search text default '',
  p_kind text default '',
  p_date_from date default null,
  p_date_to date default null,
  p_excluded_ids text[] default null,
  p_selected_before timestamptz default null
)
returns integer
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $function$
  select count(*)::integer
  from public.client_blocklist_selection_v1(
    p_client_id, p_ids, p_all_matching, p_search, p_kind, p_date_from,
    p_date_to, p_excluded_ids, p_selected_before, 250001
  );
$function$;

create or replace function public.client_blocklist_export_page_v1(
  p_client_id text,
  p_ids text[] default null,
  p_all_matching boolean default false,
  p_search text default '',
  p_kind text default '',
  p_date_from date default null,
  p_date_to date default null,
  p_excluded_ids text[] default null,
  p_selected_before timestamptz default null,
  p_after_created_at timestamptz default null,
  p_after_id text default null,
  p_limit integer default 1000
)
returns table(id text, value text, kind text, reason text, created_at timestamptz)
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $function$
  select b.id, b.value::text, b.kind::text, b.reason::text, b.created_at
  from public.client_blocklist_selection_v1(
    p_client_id, p_ids, p_all_matching, p_search, p_kind, p_date_from,
    p_date_to, p_excluded_ids, p_selected_before, 250001
  ) selected
  join public.client_blocklist b on b.id = selected.entry_id and b.client_id = p_client_id
  where p_after_created_at is null
     or b.created_at < p_after_created_at
     or (b.created_at = p_after_created_at and b.id > coalesce(p_after_id, ''))
  order by b.created_at desc, b.id
  limit greatest(1, least(coalesce(p_limit, 1000), 1000));
$function$;

create or replace function public.update_client_blocklist_reason_v1(
  p_client_id text,
  p_reason text,
  p_ids text[] default null,
  p_all_matching boolean default false,
  p_search text default '',
  p_kind text default '',
  p_date_from date default null,
  p_date_to date default null,
  p_excluded_ids text[] default null,
  p_selected_before timestamptz default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $function$
declare v_ids text[]; v_updated integer := 0;
begin
  if p_reason not in ('Client Provided', 'ICP Invalid', 'Campaign Reply') then
    raise exception 'Choose an allowed blocklist reason' using errcode = '22023';
  end if;
  select coalesce(array_agg(entry_id), array[]::text[]) into v_ids
  from public.client_blocklist_selection_v1(p_client_id, p_ids, p_all_matching,
    p_search, p_kind, p_date_from, p_date_to, p_excluded_ids, p_selected_before, 250001);
  if cardinality(v_ids) > 250000 then
    raise exception 'More than 250,000 blocklist entries match. Narrow the filters before changing their reason.' using errcode = '54000';
  end if;
  update public.client_blocklist set reason = p_reason where client_id = p_client_id and id = any(v_ids);
  get diagnostics v_updated = row_count;
  perform public.record_operation('blocklist_reason_update', p_client_id, p_actor,
    format('Updated %s blocklist reasons', v_updated), v_updated, null);
  return jsonb_build_object('updated', v_updated);
end;
$function$;

create or replace function public.remove_client_blocklist_selection_v1(
  p_client_id text,
  p_ids text[] default null,
  p_all_matching boolean default false,
  p_search text default '',
  p_kind text default '',
  p_date_from date default null,
  p_date_to date default null,
  p_excluded_ids text[] default null,
  p_selected_before timestamptz default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare v_ids text[];
begin
  select coalesce(array_agg(entry_id), array[]::text[]) into v_ids
  from public.client_blocklist_selection_v1(p_client_id, p_ids, p_all_matching,
    p_search, p_kind, p_date_from, p_date_to, p_excluded_ids, p_selected_before, 250001);
  if cardinality(v_ids) > 250000 then
    raise exception 'More than 250,000 blocklist entries match. Narrow the filters before removing them.' using errcode = '54000';
  end if;
  if cardinality(v_ids) = 0 then
    return jsonb_build_object('removed', 0, 'restored', 0, 'companiesRestored', 0);
  end if;
  return public.remove_client_blocklist_v1(p_client_id, v_ids, p_actor);
end;
$function$;

revoke execute on function public.client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamptz, integer)
  from public, anon, authenticated;
revoke execute on function public.client_blocklist_selection_count_v1(text, text[], boolean, text, text, date, date, text[], timestamptz)
  from public, anon, authenticated;
revoke execute on function public.client_blocklist_export_page_v1(text, text[], boolean, text, text, date, date, text[], timestamptz, timestamptz, text, integer)
  from public, anon, authenticated;
revoke execute on function public.update_client_blocklist_reason_v1(text, text, text[], boolean, text, text, date, date, text[], timestamptz, text)
  from public, anon, authenticated;
revoke execute on function public.remove_client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamptz, text)
  from public, anon, authenticated;
grant execute on function public.client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamptz, integer)
  to service_role;
grant execute on function public.client_blocklist_selection_count_v1(text, text[], boolean, text, text, date, date, text[], timestamptz)
  to service_role;
grant execute on function public.client_blocklist_export_page_v1(text, text[], boolean, text, text, date, date, text[], timestamptz, timestamptz, text, integer)
  to service_role;
grant execute on function public.update_client_blocklist_reason_v1(text, text, text[], boolean, text, text, date, date, text[], timestamptz, text)
  to service_role;
grant execute on function public.remove_client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamptz, text)
  to service_role;

-- 3/5. Source-scoped client-to-client pushes with durable provenance ----------

create or replace function public.push_prospects_to_client_v2(
  p_client_id text,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_source_client_id text default null,
  p_prospect_ids text[] default null,
  p_excluded_ids text[] default null,
  p_actor text default '',
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_ids text[];
  v_requested text[] := coalesce(p_prospect_ids, array[]::text[]);
  v_blocked integer := 0;
  v_present integer := 0;
  v_added_ids text[] := array[]::text[];
  v_reindex record;
  v_source_name text;
  v_request_id text := coalesce(nullif(left(btrim(coalesce(p_request_id, '')), 180), ''), gen_random_uuid()::text);
begin
  v_requested := array(select requested.id from unnest(v_requested) requested(id)
    where not (requested.id = any(coalesce(p_excluded_ids, array[]::text[]))));
  if not exists (select 1 from public.clients where id = p_client_id and archived_at is null) then
    raise exception 'Destination client not found or archived.' using errcode = 'P0002';
  end if;
  if p_source_client_id is not null then
    if p_source_client_id = p_client_id then
      raise exception 'Choose a different destination client.' using errcode = '22023';
    end if;
    select name into v_source_name from public.clients where id = p_source_client_id;
    if v_source_name is null then raise exception 'Source client not found.' using errcode = 'P0002'; end if;
  end if;

  if cardinality(v_requested) > 0 then
    if p_source_client_id is not null and exists (
      select 1 from unnest(v_requested) requested(id)
      where not exists (select 1 from public.client_prospects cp
        where cp.client_id = p_source_client_id and cp.prospect_id = requested.id and cp.status = 'active')
    ) then
      raise exception 'One or more selected people are not in the source client.' using errcode = '42501';
    end if;
    v_ids := v_requested;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_source_client_id, p_excluded_ids, 250001);
    if cardinality(v_ids) > 250000 then
      raise exception 'More than 250,000 people match. Narrow the filters before pushing.' using errcode = '54000';
    end if;
  end if;

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('added', 0, 'alreadyPresent', 0, 'blocked', 0, 'queued', 0);
  end if;

  select count(*)::integer into v_blocked
  from public.prospect_index pi
  where pi.id = any(v_ids) and exists (
    select 1 from public.client_blocklist b where b.client_id = p_client_id
      and ((b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
        or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value)))
  );
  select count(*)::integer into v_present from public.client_prospects cp
    where cp.client_id = p_client_id and cp.prospect_id = any(v_ids);

  with eligible as (
    select pi.id from public.prospect_index pi where pi.id = any(v_ids)
      and not exists (select 1 from public.client_blocklist b where b.client_id = p_client_id
        and ((b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
          or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))))
  ), inserted as (
    insert into public.client_prospects (
      client_id, prospect_id, added_via, source_push_request_id,
      source_push_client_id, source_push_label, source_push_actor
    )
    select p_client_id, eligible.id, 'push', v_request_id,
      p_source_client_id, coalesce(v_source_name, 'Master DB'), p_actor
    from eligible
    on conflict (client_id, prospect_id) do nothing returning prospect_id
  ) select coalesce(array_agg(prospect_id), array[]::text[]) into v_added_ids from inserted;

  if cardinality(v_added_ids) > 0 then
    perform public.record_client_addition_batch_v1(
      p_client_id, 'people', case when p_source_client_id is null then 'master' else 'client' end,
      coalesce(v_source_name, 'Master DB'), p_source_client_id,
      v_request_id, v_added_ids, p_actor);
  end if;
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);
  perform public.record_operation('push_to_client', p_client_id, p_actor,
    format('Pushed %s prospects into the client', cardinality(v_added_ids)), cardinality(v_added_ids), v_ids);
  return jsonb_build_object('added', cardinality(v_added_ids), 'alreadyPresent', v_present,
    'blocked', v_blocked, 'queued', v_reindex.queued);
end;
$function$;

create or replace function public.push_companies_to_client_v2(
  p_client_id text,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_actor text default '',
  p_source_client_id text default null,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_requested text[] := coalesce(p_company_ids, array[]::text[]);
  v_ids text[] := array[]::text[];
  v_added_ids text[] := array[]::text[];
  v_existing integer := 0;
  v_blocked integer := 0;
  v_source_name text;
begin
  v_requested := array(select requested.id from unnest(v_requested) requested(id)
    where not (requested.id = any(coalesce(p_excluded_ids, array[]::text[]))));
  if not exists (select 1 from public.clients where id = p_client_id and archived_at is null) then
    raise exception 'Destination client not found or archived.' using errcode = 'P0002';
  end if;
  if p_source_client_id is not null then
    if p_source_client_id = p_client_id then raise exception 'Choose a different destination client.' using errcode = '22023'; end if;
    select name into v_source_name from public.clients where id = p_source_client_id;
    if v_source_name is null then raise exception 'Source client not found.' using errcode = 'P0002'; end if;
    if cardinality(v_requested) > 0 and exists (
      select 1 from unnest(v_requested) requested(id)
      where not exists (select 1 from public.client_companies cc
        where cc.client_id = p_source_client_id and cc.company_id = requested.id)
    ) then
      raise exception 'One or more selected companies are not in the source client.' using errcode = '42501';
    end if;
  end if;

  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(
    p_source_client_id, case when cardinality(v_requested) > 0 then v_requested else null end,
    p_search, p_filters, p_people_scope, p_excluded_ids, 250001);
  if cardinality(v_ids) > 250000 then
    raise exception 'More than 250,000 companies match. Narrow the filters before pushing.' using errcode = '54000';
  end if;
  select count(*)::integer into v_existing from public.client_companies
    where client_id = p_client_id and company_id = any(v_ids);

  with inserted as (
    insert into public.client_companies (client_id, company_id, added_by)
    select p_client_id, company_id,
      case when p_source_client_id is null then 'push:master' else 'push:client:' || p_source_client_id end
    from unnest(v_ids) selected(company_id)
    on conflict (client_id, company_id) do nothing
    returning company_id
  ) select coalesce(array_agg(company_id), array[]::text[]) into v_added_ids from inserted;

  select count(*)::integer into v_blocked from public.client_companies_blocked
    where client_id = p_client_id and company_id = any(v_ids);
  if cardinality(v_added_ids) > 0 then
    perform public.record_client_addition_batch_v1(
      p_client_id, 'companies', case when p_source_client_id is null then 'master' else 'client' end,
      coalesce(v_source_name, 'Master DB'), p_source_client_id,
      coalesce(nullif(p_request_id, ''), gen_random_uuid()::text), v_added_ids, p_actor);
  end if;
  return jsonb_build_object('selected', cardinality(v_ids), 'added', cardinality(v_added_ids),
    'alreadyPresent', v_existing, 'blocked', v_blocked);
end;
$function$;

revoke execute on function public.push_prospects_to_client_v2(text, text, jsonb, text, text[], text[], text, text)
  from public, anon, authenticated;
revoke execute on function public.push_companies_to_client_v2(text, text[], text, jsonb, jsonb, text[], text, text, text)
  from public, anon, authenticated;
grant execute on function public.push_prospects_to_client_v2(text, text, jsonb, text, text[], text[], text, text)
  to service_role;
grant execute on function public.push_companies_to_client_v2(text, text[], text, jsonb, jsonb, text[], text, text, text)
  to service_role;

-- Frozen all-matching pushes are applied by the operations worker. Teach its
-- existing definer function to use v2 and carry the source/request identity;
-- all other action arms remain byte-for-byte as deployed.
do $patch_worker$
declare
  v_def text;
  v_old constant text := $old$v_batch := public.push_prospects_to_client_v1(
      p_client_id => v_job.client_scope,
      p_search => '', p_filters => '[]'::jsonb,
      p_source_client_id => nullif(v_job.payload ->> 'sourceClientId', ''),
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);$old$;
  v_new constant text := $new$v_batch := public.push_prospects_to_client_v2(
      p_client_id => v_job.client_scope,
      p_search => '', p_filters => '[]'::jsonb,
      p_source_client_id => nullif(v_job.payload ->> 'sourceClientId', ''),
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor,
      p_request_id => v_job.request_id::text);$new$;
begin
  select pg_get_functiondef('prospect_operations.apply_batch_v1(uuid,integer,integer)'::regprocedure) into v_def;
  if position('public.push_prospects_to_client_v2(' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then
    raise exception 'apply_batch_v1 push dispatch changed; refusing to patch source provenance blindly';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$patch_worker$;

do $assert_worker$
declare v_def text;
begin
  select pg_get_functiondef('prospect_operations.apply_batch_v1(uuid,integer,integer)'::regprocedure) into v_def;
  if position('public.push_prospects_to_client_v2(' in v_def) = 0
     or position('p_request_id => v_job.request_id::text' in v_def) = 0 then
    raise exception 'The operations worker did not retain v2 push provenance.';
  end if;
end;
$assert_worker$;

-- A completed company import is a navigable collection just like a People
-- list. company_import_rows is resumable staging and is purged after
-- completion, so retain only the narrow import/company relationship.
create table if not exists public.company_import_memberships (
  import_id text not null references public.company_imports(id) on delete cascade,
  company_id text not null references public.companies(id) on delete cascade,
  first_seen_at timestamptz not null default now(),
  primary key (import_id, company_id)
);
create index if not exists idx_company_import_memberships_company
  on public.company_import_memberships(company_id, import_id);
alter table public.company_import_memberships enable row level security;
revoke all on table public.company_import_memberships from public, anon, authenticated;
grant select, insert, update, delete on table public.company_import_memberships to service_role;

insert into public.company_import_memberships(import_id, company_id, first_seen_at)
select cir.import_id, cir.company_id, min(cir.imported_at)
from public.company_import_rows cir
where cir.company_id is not null
group by cir.import_id, cir.company_id
on conflict (import_id, company_id) do nothing;

create or replace function public.capture_company_import_membership_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if new.company_id is not null then
    insert into public.company_import_memberships(import_id, company_id, first_seen_at)
    values (new.import_id, new.company_id, coalesce(new.imported_at, now()))
    on conflict (import_id, company_id) do nothing;
  end if;
  return new;
end;
$function$;
drop trigger if exists company_import_rows_capture_membership_v1 on public.company_import_rows;
create trigger company_import_rows_capture_membership_v1
after insert or update of company_id on public.company_import_rows
for each row execute function public.capture_company_import_membership_v1();
revoke execute on function public.capture_company_import_membership_v1()
  from public, anon, authenticated;

-- Keep its internal id filter in the canonical company compiler so the
-- listing, counts, exports and durable selections all resolve the same rows.
-- The pseudo-filter is removed before the current v3 compiler sees it.
create or replace function public.company_effective_filter_sql_v1(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $function$
declare
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_clean jsonb;
  v_import_count integer;
  v_import_id text;
  v_prefilter text;
  v_complete text;
  v_base text;
begin
  select count(*), min(item->'values'->>0) into v_import_count, v_import_id
  from jsonb_array_elements(v_filters) item
  where item->>'field' = '__company_import_id';
  if v_import_count > 1 or (v_import_count = 1 and coalesce(btrim(v_import_id), '') = '') then
    raise exception 'Choose one company import.' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(item order by ordinal), '[]'::jsonb) into v_clean
  from jsonb_array_elements(v_filters) with ordinality entries(item, ordinal)
  where item->>'field' <> '__company_import_id';
  v_prefilter := public.company_prefilter_sql(p_search, v_clean);
  v_complete := public.company_filter_sql_v3(p_search, v_clean, false);
  if v_complete is null then return null; end if;
  v_base := case
    when v_prefilter <> 'true' and v_prefilter is distinct from v_complete
      then '(' || v_prefilter || ') and (' || v_complete || ')'
    else v_complete end;
  if v_import_count = 1 then
    v_base := '(' || v_base || ') and exists (select 1 from public.company_import_memberships cim'
      || ' where cim.company_id = c.id and cim.import_id = ' || quote_literal(v_import_id) || ')';
  end if;
  return v_base;
end;
$function$;

-- A per-company people limit is part of the selection, not a presentation
-- filter. Build the complete authorized candidate set once, rank that set once,
-- and only then paginate it. This function is shared by the grid, direct CSV
-- export and durable result-set builder so those three paths cannot disagree.
create index if not exists idx_prospect_index_company_created_id
  on public.prospect_index (company_id, created_at desc, id desc);

create or replace function public.prospect_capped_candidate_ids_v1(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb
)
returns table(prospect_id text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_clean_filters jsonb;
  v_cap_items integer;
  v_cap_text text;
  v_cap integer;
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean;
  v_prefilter text;
  v_complete text;
  v_match text;
  v_scope_cte text := '';
  v_scope_join text := '';
  v_sql text;
begin
  if jsonb_typeof(v_filters) <> 'array' then
    raise exception 'Filters must be an array.' using errcode = '22023';
  end if;

  select count(*), min(item->'values'->>0)
    into v_cap_items, v_cap_text
  from jsonb_array_elements(v_filters) item
  where item->>'field' = '__max_people_per_company';

  if v_cap_items <> 1 or coalesce(v_cap_text, '') !~ '^[1-9][0-9]{0,3}$' then
    raise exception 'Max people per company must be one integer from 1 to 1000.' using errcode = '22023';
  end if;
  v_cap := v_cap_text::integer;
  if v_cap > 1000 then
    raise exception 'Max people per company must be one integer from 1 to 1000.' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(item order by ordinal), '[]'::jsonb)
    into v_clean_filters
  from jsonb_array_elements(v_filters) with ordinality entries(item, ordinal)
  where item->>'field' <> '__max_people_per_company';

  v_prefilter := public.prospect_prefilter_sql(coalesce(p_search, ''), v_clean_filters);
  v_complete := public.prospect_filter_sql_v1(coalesce(p_search, ''), v_clean_filters);
  v_match := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || '(' || coalesce(v_complete, format(
      'public.prospect_index_matches_v1(pi, %L, %L::jsonb)',
      coalesce(p_search, ''), v_clean_filters::text)) || ')';

  v_has_scope := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  if v_has_scope then
    v_scope_cte := format(
      'eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  end if;

  v_sql := format($sql$
    with %1$s matched as materialized (
      select pi.id, pi.created_at, pi.company_id
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L])
        and (%4$s)
    ), ranked as (
      select matched.id, matched.created_at,
        row_number() over (
          partition by coalesce(matched.company_id, '__person__:' || matched.id)
          order by matched.created_at desc, matched.id desc
        ) as company_rank
      from matched
    )
    select ranked.id, ranked.created_at
    from ranked
    where ranked.company_rank <= %5$s
  $sql$, v_scope_cte, v_scope_join, p_client_id, v_match, v_cap::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.prospect_capped_candidate_ids_v1(text, jsonb, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.prospect_capped_candidate_ids_v1(text, jsonb, text, jsonb)
  to service_role;

-- People -> Company pivots must resolve the same capped people set. Without
-- this branch the legacy compiler sees the internal cap field as an ordinary
-- filter and the Company workspace can widen or empty unexpectedly.
create or replace function public.people_scope_company_ids_v1(p_client_id text, p_scope jsonb)
returns table(company_id text)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_search text := coalesce(p_scope->>'search', '');
  v_filters jsonb := coalesce(p_scope->'filters', '[]'::jsonb);
  v_limit integer := case
    when coalesce(p_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((p_scope->>'limit')::bigint, 250000))::integer
    else 250000 end;
  v_has_cap boolean := exists (
    select 1 from jsonb_array_elements(v_filters) item
    where item->>'field' = '__max_people_per_company');
  v_prefilter text;
  v_complete text;
  v_sql text := 'select distinct pi.company_id from public.prospect_index pi where pi.company_id is not null';
begin
  if p_scope is null then return; end if;
  if v_has_cap then
    return query
      select distinct pi.company_id
      from public.prospect_capped_candidate_ids_v1(v_search, v_filters, p_client_id, '{}'::jsonb) candidate
      join public.prospect_index pi on pi.id = candidate.prospect_id
      where pi.company_id is not null
      order by pi.company_id
      limit v_limit;
    return;
  end if;
  v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
  if p_client_id is not null then
    v_sql := v_sql || format(' and pi.client_ids @> array[%L]', p_client_id);
  end if;
  if v_prefilter <> 'true' then v_sql := v_sql || ' and (' || v_prefilter || ')'; end if;
  if btrim(v_search) <> '' or v_filters <> '[]'::jsonb then
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_sql := v_sql || ' and (' || coalesce(v_complete,
      format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  end if;
  v_sql := v_sql || format(' order by pi.company_id limit %s', v_limit);
  return query execute v_sql;
end;
$function$;

revoke execute on function public.people_scope_company_ids_v1(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.people_scope_company_ids_v1(text, jsonb)
  to service_role;

-- Master-db all-matching delete is the remaining direct bulk consumer. Keep
-- its established path for ordinary filters, but never hand the internal cap
-- field to the legacy compiler or widen a destructive selection.
create or replace function public.delete_prospects_matching_v2(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_excluded_ids text[] default null
)
returns bigint
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare v_deleted bigint;
begin
  if not exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company'
  ) then
    return public.delete_prospects_matching_v1(p_search, p_filters, p_excluded_ids);
  end if;
  with doomed as materialized (
    select candidate.prospect_id
    from public.prospect_capped_candidate_ids_v1(p_search, p_filters, null, '{}'::jsonb) candidate
    where not (candidate.prospect_id = any(coalesce(p_excluded_ids, array[]::text[])))
  ), deleted as (
    delete from public.prospects p using doomed
    where p.id = doomed.prospect_id
    returning p.id
  )
  select count(*)::bigint into v_deleted from deleted;
  return v_deleted;
end;
$function$;

revoke execute on function public.delete_prospects_matching_v2(text, jsonb, text[])
  from public, anon, authenticated;
grant execute on function public.delete_prospects_matching_v2(text, jsonb, text[])
  to service_role;

create or replace function public.search_prospect_workspace_v13(
  p_search text default '', p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at', p_direction text default 'desc',
  p_limit integer default 50, p_offset integer default 0,
  p_client_id text default null, p_company_scope jsonb default '{}'::jsonb,
  p_with_total boolean default true, p_known_versions jsonb default null
)
returns table(result_rows jsonb, total_count bigint, scope_capped boolean,
  total_capped boolean, data_versions jsonb)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $function$
declare
  v_has_cap boolean := exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company');
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean;
  v_scope_limit integer;
  v_scope_capped boolean := false;
  v_versions jsonb;
  v_want_total boolean;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_sort_expr text;
  v_sort_dir text;
  v_sort_nulls text := '';
  v_order text;
  v_sql text;
begin
  if not v_has_cap then
    return query select * from public.search_prospect_workspace_v12(
      p_search, p_filters, p_sort, p_direction, p_limit, p_offset,
      p_client_id, p_company_scope, p_with_total, p_known_versions);
    return;
  end if;

  v_has_scope := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  v_scope_limit := case when coalesce(v_scope->>'limit', '') ~ '^[0-9]+$'
    then greatest(1000, least((v_scope->>'limit')::bigint, 250000))::integer
    else 250000 end;
  if v_has_scope then
    select count(*) >= v_scope_limit into v_scope_capped
    from public.company_scope_ids_v2(p_client_id, v_scope);
  end if;

  v_versions := public.data_versions_v1(
    case when v_has_scope then array['prospect', 'company'] else array['prospect'] end);
  v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;
  v_sort_dir := case when lower(coalesce(p_direction, 'desc')) = 'asc' then 'asc' else 'desc' end;
  case coalesce(p_sort, 'created_at')
    when 'name' then v_sort_expr := 'lower(pi.full_name)';
    when 'company' then v_sort_expr := 'lower(pi.company_name)';
    when 'title' then v_sort_expr := 'lower(pi.title)';
    when 'last_contacted' then
      v_sort_expr := 'pi.last_contacted_at';
      v_sort_nulls := case when v_sort_dir = 'asc' then ' nulls first' else ' nulls last' end;
    else v_sort_expr := 'pi.created_at';
  end case;
  v_order := format('%s %s%s, pi.id', v_sort_expr, v_sort_dir, v_sort_nulls);

  v_sql := format($sql$
    with candidates as materialized (
      select * from public.prospect_capped_candidate_ids_v1(%1$L, %2$L::jsonb, %3$L, %4$L::jsonb)
    ), ordered as (
      select pi.id, %5$s as sort_key
      from candidates candidate
      join public.prospect_index pi on pi.id = candidate.prospect_id
      order by %6$s
      limit %7$s offset %8$s
    ), page as (
      select ordered.id,
        row_number() over (order by ordered.sort_key %9$s%10$s, ordered.id) as page_order
      from ordered
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %3$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order)
      from hydrated), '[]'::jsonb),
      case when %11$L then (select count(*)::bigint from candidates) else null::bigint end,
      %12$L::boolean, false, %13$L::jsonb
  $sql$, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text,
    p_client_id, v_scope::text, v_sort_expr, v_order, v_limit::text, v_offset::text,
    v_sort_dir, v_sort_nulls, v_want_total, v_scope_capped, v_versions::text);
  return query execute v_sql;
end;
$function$;

revoke execute on function public.search_prospect_workspace_v13(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb)
  from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v13(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb)
  to service_role;

create or replace function public.search_prospect_export_v6(
  p_search text default '', p_filters jsonb default '[]'::jsonb,
  p_client_id text default null, p_company_scope jsonb default '{}'::jsonb,
  p_after_created_at timestamptz default null, p_after_id text default null,
  p_limit integer default 5000, p_with_total boolean default false,
  p_keys text[] default '{}'::text[]
)
returns table(result_rows jsonb, total_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_has_cap boolean := exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company');
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
begin
  if not v_has_cap then
    return query select * from public.search_prospect_export_v5(
      p_search, p_filters, p_client_id, p_company_scope, p_after_created_at,
      p_after_id, p_limit, p_with_total, p_keys);
    return;
  end if;

  return query
  with candidates as materialized (
    select * from public.prospect_capped_candidate_ids_v1(
      p_search, p_filters, p_client_id, p_company_scope)
  ), ordered_page as (
    select candidate.prospect_id as id, candidate.created_at
    from candidates candidate
    where p_after_created_at is null
      or (candidate.created_at, candidate.prospect_id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by candidate.created_at desc, candidate.prospect_id desc
    limit v_limit
  ), page as (
    select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order
    from ordered_page
  ), hydrated as (
    select pi.*, page.page_order
    from page join public.prospect_index pi on pi.id = page.id
  )
  select coalesce((select jsonb_agg(
      public.jsonb_project_v1(to_jsonb(hydrated) - 'page_order', coalesce(p_keys, '{}'::text[]))
      order by page_order) from hydrated), '[]'::jsonb),
    case when p_with_total then (select count(*)::bigint from candidates) else null::bigint end;
end;
$function$;

revoke execute on function public.search_prospect_export_v6(text, jsonb, text, jsonb, timestamptz, text, integer, boolean, text[])
  from public, anon, authenticated;
grant execute on function public.search_prospect_export_v6(text, jsonb, text, jsonb, timestamptz, text, integer, boolean, text[])
  to service_role;

-- Durable selections use the same ranked candidates. Non-capped People and all
-- Company sets retain the proven v1 implementation byte-for-byte.
create or replace function prospect_results.build_regular_batch_v2(
  p_set_id uuid, p_batch_size integer default 25000
)
returns table(inserted integer, total bigint, done boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '120s'
as $function$
declare
  v_row prospect_results.result_sets%rowtype;
  v_has_cap boolean;
  v_sql text;
  v_inserted integer;
begin
  select * into v_row from prospect_results.result_sets where id = p_set_id for update;
  if not found then raise exception 'Result set does not exist' using errcode = 'P0002'; end if;
  v_has_cap := v_row.entity_type = 'prospect' and exists (
    select 1 from jsonb_array_elements(coalesce(v_row.filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company');
  if not v_has_cap then
    return query select * from prospect_results.build_regular_batch_v1(p_set_id, p_batch_size);
    return;
  end if;
  if v_row.status not in ('pending', 'building') then
    return query select 0, v_row.row_count, true;
    return;
  end if;

  -- A capped result is frozen in one database snapshot. Re-running the ranking
  -- in later chunks could admit person N+1 after person N from the same company
  -- stopped matching, violating the chosen quota. The normal result-set cap is
  -- 250,000 ids and the statement has its own 120-second safety boundary.
  v_sql := format($sql$
    with candidates as materialized (
      select * from public.prospect_capped_candidate_ids_v1(%1$L, %2$L::jsonb, %3$L, %4$L::jsonb)
    ), numbered as (
      select candidate.prospect_id as id,
        row_number() over (order by candidate.created_at desc, candidate.prospect_id desc) as ordinal
      from candidates candidate
    ), stored as (
      insert into prospect_results.result_set_items(result_set_id, ordinal, entity_id)
      select %5$L::uuid, numbered.ordinal, numbered.id from numbered
      on conflict do nothing returning 1
    )
    select (select count(*) from stored)::integer
  $sql$, v_row.search, v_row.filters::text, nullif(v_row.client_scope, ''),
    coalesce(v_row.company_scope, '{}'::jsonb)::text, p_set_id);
  execute v_sql into v_inserted;
  v_inserted := coalesce(v_inserted, 0);
  update prospect_results.result_sets
    set row_count = v_inserted, status = 'ready', completed_at = now(),
      lease_expires_at = null, worker_id = null
    where id = p_set_id
    returning row_count into total;
  inserted := v_inserted;
  done := true;
  return next;
end;
$function$;

revoke execute on function prospect_results.build_regular_batch_v2(uuid, integer)
  from public, anon, authenticated;

do $patch_result_builder$
declare v_def text;
begin
  select pg_get_functiondef('prospect_results.build_batch_v1(uuid,integer)'::regprocedure) into v_def;
  if position('prospect_results.build_regular_batch_v2(' in v_def) > 0 then return; end if;
  if position('prospect_results.build_regular_batch_v1(p_set_id,p_batch_size)' in v_def) = 0 then
    raise exception 'build_batch_v1 regular dispatch changed; refusing to patch it blindly';
  end if;
  execute replace(v_def,
    'prospect_results.build_regular_batch_v1(p_set_id,p_batch_size)',
    'prospect_results.build_regular_batch_v2(p_set_id,p_batch_size)');
end;
$patch_result_builder$;

do $assert_result_builder$
declare v_def text;
begin
  select pg_get_functiondef('prospect_results.build_batch_v1(uuid,integer)'::regprocedure) into v_def;
  if position('prospect_results.build_regular_batch_v2(' in v_def) = 0 then
    raise exception 'Durable result sets did not retain the capped candidate dispatch.';
  end if;
end;
$assert_result_builder$;

-- Client directory counts/folder/archive are read together. client_companies is
-- authoritative for the client Company DB, including explicitly pushed rows.
create or replace view public.client_summaries as
select c.id, c.name, c.created_at,
  (select count(*)::integer from public.lists l where l.client_id = c.id) as list_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.status = 'active') as prospect_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.status = 'active' and cp.icp_verified) as icp_verified_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.status = 'blocked') as blocked_count,
  (select count(*)::integer from public.client_companies cc where cc.client_id = c.id) as company_count,
  c.folder_id, c.archived_at
from public.clients c;
revoke all on public.client_summaries from public, anon, authenticated;
grant select on public.client_summaries to service_role;

commit;
