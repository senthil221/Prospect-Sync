-- Export what was asked for, a page at a time, and never hold the whole file.
--
-- Section 9.4. Three of the things it asks for are missing today, and this
-- migration is the database half of all three.
--
-- 1. REQUESTED COLUMNS ONLY. search_prospect_export_v4 returns to_jsonb of the
--    whole prospect_index row for every page, so an export of Full Name and
--    Work Email carries keywords, all_data, mx_records and thirty-odd other
--    columns across the wire and then throws them away in Node. v5 takes the
--    key list and projects in the database. That key list is not a second copy
--    of the column map: lib/prospect-export.ts derives it by running the
--    renderer itself against a recording proxy, so it cannot drift from what
--    the CSV actually reads.
--
-- 2. THE COMPANY EXPORT HAS NO KEYSET FUNCTION. It pages public.companies with
--    OFFSET, one thousand rows at a time, inside a single HTTP request, and
--    accumulates every row into one string before it writes a byte - the exact
--    "no whole-CSV accumulation in Next.js" the section rules out, on top of a
--    deep-OFFSET scan that re-reads and re-discards the whole prefix on every
--    page. search_company_export_v1 is the keyset function 9.4 asks for, and it
--    keeps the alphabetical order the current export produces, which is why
--    idx_companies_lower_name_id comes with it.
--
-- 3. A LARGE EXPORT NEEDS SOMEWHERE TO GO. prospect_exports is the background
--    half: a job naming a result set and a column list, and a file built from
--    it in bounded batches by the operations worker.
--
-- WHY IT READS A RESULT SET RATHER THAN RE-RUNNING THE SEARCH. The export
-- function's `matched` CTE is MATERIALIZED, so every keyset page rebuilds the
-- entire match set before taking its slice. That is the right shape for a page
-- or two and quadratic for fifty. A durable result set (20260902000120) has
-- already paid that cost once and stored the ids in order, so a background
-- export is an indexed walk of result_set_items with no filtering in it at all.
-- It also settles the count: an export whose size was "50,000+" now knows
-- exactly how many rows it is going to write.
--
-- WHY THE WORKER STILL CANNOT READ A PROSPECT. build_batch_v1 is SECURITY
-- DEFINER and returns counts, never rows. prospect_operator gets EXECUTE on
-- claim/build/fail/expire and nothing else - no SELECT on prospect_index, none
-- on job_parts, and no way to request a job or read one back. The assertions at
-- the bottom prove it, as 20260902000130 and 20260902000160 do for the two
-- queues already there.
--
-- WHY job_parts IS UNLOGGED. A 250,000-row export is on the order of 100 MB of
-- rows. Logging it would put that through WAL for a file that is deleted within
-- 24 hours and can be rebuilt from the result set by asking again. The cost of
-- the choice is that a crash truncates the table while jobs still say 'ready',
-- so parts_present_v1 exists and the download path asks it rather than serving
-- a file with holes in it.

begin;

-- 1. Requested columns only -------------------------------------------------

-- Mechanical projection: it knows nothing about what any key means, so nothing
-- here can disagree with the renderer about which column is which.
create or replace function public.jsonb_project_v1(p_row jsonb, p_keys text[])
returns jsonb
language sql
immutable
parallel safe
as $function$
  select case
    when p_keys is null or cardinality(p_keys) = 0 then p_row
    else coalesce(
      (select jsonb_object_agg(entry.key, entry.value)
       from jsonb_each(p_row) entry
       where entry.key = any (p_keys)),
      '{}'::jsonb)
  end;
$function$;

comment on function public.jsonb_project_v1(jsonb, text[]) is
  'Keep only the named keys of a jsonb object, so an export carries only the columns it asked for.';

create or replace function public.search_prospect_export_v5(
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null::text,
  p_company_scope jsonb default '{}'::jsonb,
  p_after_created_at timestamp with time zone default null::timestamp with time zone,
  p_after_id text default null::text,
  p_limit integer default 5000,
  p_with_total boolean default false,
  p_keys text[] default '{}'::text[]
)
returns table(result_rows jsonb, total_count bigint)
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '60s'
as $function$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_complete text := public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_scope_cte text;
  v_scope_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_keys text[] := coalesce(p_keys, '{}'::text[]);
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  else
    v_scope_cte := '';
    v_scope_join := '';
  end if;

  v_sql := format($q$
    with %1$s matched as materialized (
      select pi.id, pi.created_at
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched
      where %5$L::timestamptz is null or (matched.created_at, matched.id) < (%5$L::timestamptz, coalesce(%6$L, ''))
      order by matched.created_at desc, matched.id desc
      limit %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_index pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(
             public.jsonb_project_v1(to_jsonb(hydrated) - 'page_order', %9$L::text[])
             order by page_order) from hydrated), '[]'::jsonb),
      case when %8$L then (select count(*) from matched) else null end
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause,
       p_after_created_at, p_after_id, v_limit::text, p_with_total, v_keys);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.search_prospect_export_v5(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean, text[]) from public, anon, authenticated;
grant execute on function public.search_prospect_export_v5(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean, text[]) to service_role;

-- 2. The company export's own keyset function -------------------------------

-- Alphabetical, which is the order the current export produces, and now an
-- order a keyset can actually resume from. Without this index every page would
-- sort the whole table again, which is worse than the OFFSET loop it replaces.
create index if not exists idx_companies_lower_name_id
  on public.companies (lower(name), id);

create or replace function public.search_company_export_v1(
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_websites_only boolean default false,
  p_after_name text default null::text,
  p_after_id text default null::text,
  p_limit integer default 5000
)
returns table(result_rows jsonb)
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '60s'
as $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_scope_cte text := '';
  v_where text;
  v_sql text;
begin
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  v_where := format('(%s)', v_match_clause);
  if coalesce(p_websites_only, false) then
    v_where := v_where || $w$ and btrim(coalesce(c.domain, '')) <> ''$w$;
  end if;
  if p_people_scope is not null then
    v_scope_cte := format($s$with scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(null::text, %L::jsonb)
      ) $s$, p_people_scope::text);
    v_where := v_where || ' and c.id in (select company_id from scope_ids)';
  end if;

  -- Keyset on (lower(name), id): total, indexed, and stable across pages even
  -- while companies are being inserted underneath it.
  v_sql := format($q$
    %1$s select coalesce((select jsonb_agg(
      jsonb_build_object('id', page.id, 'name', page.name, 'domain', page.domain, 'sort_name', page.sort_name)
      order by page.sort_name, page.id) from (
      select c.id, c.name, c.domain, lower(c.name) as sort_name
      from public.companies c
      where %2$s
        and (%3$L::text is null or (lower(c.name), c.id) > (%3$L::text, coalesce(%4$L, '')))
      order by lower(c.name), c.id
      limit %5$s
    ) page), '[]'::jsonb)
  $q$, v_scope_cte, v_where, p_after_name, p_after_id, v_limit::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.search_company_export_v1(text, jsonb, jsonb, boolean, text, text, integer) from public, anon, authenticated;
grant execute on function public.search_company_export_v1(text, jsonb, jsonb, boolean, text, text, integer) to service_role;

-- 3. Background export jobs -------------------------------------------------

create schema if not exists prospect_exports;
revoke all on schema prospect_exports from public, anon, authenticated;

create table if not exists prospect_exports.jobs (
  id uuid primary key default gen_random_uuid(),
  owner_id text not null,
  -- Section 9.2: the client's request UUID, unique per actor. A retry of the
  -- same enqueue returns the same job rather than building the file twice.
  request_id text not null,
  entity_type text not null check (entity_type in ('prospect', 'company')),
  client_scope text not null default '',
  -- Deliberately NOT a foreign key. The set is an input, and a finished file has
  -- no further use for it - a job must not be deleted because retention
  -- collected the set it was built from.
  result_set_id uuid not null,
  -- The requested export field ids, and the row keys they read. Both are
  -- stored: the ids are what the download renders with, the keys are what the
  -- build fetched, and lib/prospect-export.ts derives the second from the first
  -- so they cannot disagree. Empty keys mean every column.
  fields text[] not null default '{}',
  keys text[] not null default '{}',
  excluded_ids text[] not null default '{}',
  file_base_name text not null default 'export',
  status text not null default 'queued'
    check (status in ('queued', 'building', 'ready', 'failed')),
  row_count bigint not null default 0,
  byte_count bigint not null default 0,
  part_count integer not null default 0,
  -- How far through result_set_items this job has read.
  next_ordinal bigint not null default 0,
  -- The link secret. Short-lived because the job is: expires_at collects both.
  download_token text not null,
  error text,
  worker_id text,
  lease_expires_at timestamptz,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  expires_at timestamptz not null
);
revoke all on prospect_exports.jobs from public, anon, authenticated;

create unique index if not exists uq_export_jobs_request
  on prospect_exports.jobs (owner_id, request_id);
create index if not exists idx_export_jobs_queued
  on prospect_exports.jobs (created_at) where status in ('queued', 'building');
create index if not exists idx_export_jobs_expires_at
  on prospect_exports.jobs (expires_at);

-- UNLOGGED on purpose; see the header. The rows are stored as jsonb rather than
-- as rendered CSV so that exactly one renderer exists: the download path runs
-- the same lib/prospect-export.ts the direct download does.
create unlogged table if not exists prospect_exports.job_parts (
  job_id uuid not null references prospect_exports.jobs(id) on delete cascade,
  part_index integer not null,
  row_count integer not null,
  rows jsonb not null,
  primary key (job_id, part_index)
);
revoke all on prospect_exports.job_parts from public, anon, authenticated;

-- Ask for a file, or get back the one this request already asked for.
create or replace function prospect_exports.request_v1(
  p_owner_id text,
  p_request_id text,
  p_entity_type text,
  p_client_scope text,
  p_result_set_id uuid,
  p_fields text[] default '{}'::text[],
  p_keys text[] default '{}'::text[],
  p_excluded_ids text[] default '{}'::text[],
  p_file_base_name text default 'export',
  p_ttl interval default interval '24 hours'
)
returns table(job_id uuid, status text, row_count bigint, download_token text, reused boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_exports, prospect_results
set statement_timeout = '15s'
as $function$
declare
  v_existing prospect_exports.jobs%rowtype;
  v_set prospect_results.result_sets%rowtype;
  v_id uuid;
  v_token text;
begin
  if coalesce(btrim(p_owner_id), '') = '' then
    raise exception 'An export needs an owner' using errcode = '22023';
  end if;
  if coalesce(btrim(p_request_id), '') = '' then
    raise exception 'An export needs a request id' using errcode = '22023';
  end if;

  select * into v_existing from prospect_exports.jobs j
  where j.owner_id = p_owner_id and j.request_id = p_request_id;
  if found then
    return query select v_existing.id, v_existing.status, v_existing.row_count, v_existing.download_token, true;
    return;
  end if;

  -- The result set is the authorization: a job may only be built from a set its
  -- own owner asked for. Without this check a guessed request would be enough
  -- to export somebody else's frozen list.
  select * into v_set from prospect_results.result_sets rs where rs.id = p_result_set_id;
  if not found then
    raise exception 'That result set does not exist' using errcode = 'P0002';
  end if;
  if v_set.owner_id is distinct from p_owner_id then
    raise exception 'That result set belongs to someone else' using errcode = '42501';
  end if;
  if v_set.entity_type is distinct from p_entity_type then
    raise exception 'That result set is not a % set', p_entity_type using errcode = '22023';
  end if;

  -- Two UUIDs rather than gen_random_bytes: that one lives in pgcrypto, which
  -- this database has never been asked to install, and a token generator is a
  -- poor reason to take a new extension dependency. gen_random_uuid is core and
  -- draws on the same strong RNG, so 64 hex characters here is 244 bits.
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into prospect_exports.jobs
    (owner_id, request_id, entity_type, client_scope, result_set_id, fields, keys, excluded_ids,
     file_base_name, download_token, expires_at)
  values (p_owner_id, p_request_id, p_entity_type, coalesce(p_client_scope, ''), p_result_set_id,
          coalesce(p_fields, '{}'::text[]), coalesce(p_keys, '{}'::text[]), coalesce(p_excluded_ids, '{}'::text[]),
          coalesce(nullif(btrim(p_file_base_name), ''), 'export'), v_token, now() + p_ttl)
  returning id into v_id;

  return query select v_id, 'queued'::text, 0::bigint, v_token, false;
end;
$function$;

-- Claim the next file to build. Only jobs whose result set is finished are
-- claimable, and that is the whole of the waiting logic: the same worker builds
-- the sets, so a job becomes claimable when its input is ready and nothing has
-- to spin waiting for it.
create or replace function prospect_exports.claim_next_v1(
  p_worker_id text,
  p_lease_seconds integer default 300
)
returns table(job_id uuid, entity_type text, result_set_id uuid, row_count bigint, next_ordinal bigint, set_rows bigint)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_exports, prospect_results
set statement_timeout = '15s'
as $function$
declare
  v_id uuid;
begin
  select j.id into v_id
  from prospect_exports.jobs j
  join prospect_results.result_sets rs on rs.id = j.result_set_id
  where j.expires_at > now()
    and rs.status = 'ready'
    and (j.status = 'queued'
         or (j.status = 'building' and coalesce(j.lease_expires_at, now()) <= now()))
  order by j.created_at
  for update of j skip locked
  limit 1;

  if v_id is null then return; end if;

  update prospect_exports.jobs j
  set status = 'building',
      worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds)),
      started_at = coalesce(j.started_at, now())
  where j.id = v_id;

  return query
  select j.id, j.entity_type, j.result_set_id, j.row_count, j.next_ordinal, rs.row_count
  from prospect_exports.jobs j
  join prospect_results.result_sets rs on rs.id = j.result_set_id
  where j.id = v_id;
end;
$function$;

-- One part, one transaction. Returns counts, never rows: the worker is not
-- allowed to see a prospect and does not need to.
create or replace function prospect_exports.build_batch_v1(
  p_job_id uuid,
  p_batch_size integer default 5000,
  p_lease_seconds integer default 300
)
returns table(appended integer, total_rows bigint, total_parts integer, done boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_exports, prospect_results
set statement_timeout = '120s'
as $function$
declare
  v_job prospect_exports.jobs%rowtype;
  v_set_status text;
  v_batch integer := greatest(500, least(coalesce(p_batch_size, 5000), 25000));
  v_rows jsonb;
  v_kept integer;
  v_scanned integer;
  v_last_ordinal bigint;
  v_part integer;
begin
  select * into v_job from prospect_exports.jobs where id = p_job_id for update;
  if not found then
    raise exception 'That export job does not exist' using errcode = 'P0002';
  end if;
  if v_job.status not in ('queued', 'building') then
    return query select 0, v_job.row_count, v_job.part_count, true;
    return;
  end if;

  select rs.status into v_set_status from prospect_results.result_sets rs where rs.id = v_job.result_set_id;
  if v_set_status is null then
    raise exception 'The result set this export was built from is gone; ask for the export again' using errcode = 'P0002';
  end if;
  if v_set_status <> 'ready' then
    raise exception 'That result set is not finished yet' using errcode = '22023';
  end if;

  -- Two numbers, deliberately separate. `scanned` and the last ordinal come from
  -- the ids in the set, so an excluded id and an id deleted since the set was
  -- frozen both advance the cursor; `kept` counts only what went into the file.
  -- Taking either from the hydrated rows would stall a job whose whole batch was
  -- excluded.
  if v_job.entity_type = 'prospect' then
    with batch as (
      select i.ordinal, i.entity_id
      from prospect_results.result_set_items i
      where i.result_set_id = v_job.result_set_id and i.ordinal > v_job.next_ordinal
      order by i.ordinal
      limit v_batch
    ), hydrated as (
      select b.ordinal, public.jsonb_project_v1(to_jsonb(pi), v_job.keys) as row_json
      from batch b
      join public.prospect_index pi on pi.id = b.entity_id
      where not (b.entity_id = any (v_job.excluded_ids))
    )
    select (select jsonb_agg(hydrated.row_json order by hydrated.ordinal) from hydrated),
           (select count(*)::integer from hydrated),
           (select count(*)::integer from batch),
           (select max(batch.ordinal) from batch)
    into v_rows, v_kept, v_scanned, v_last_ordinal;
  else
    with batch as (
      select i.ordinal, i.entity_id
      from prospect_results.result_set_items i
      where i.result_set_id = v_job.result_set_id and i.ordinal > v_job.next_ordinal
      order by i.ordinal
      limit v_batch
    ), hydrated as (
      select b.ordinal, public.jsonb_project_v1(to_jsonb(c), v_job.keys) as row_json
      from batch b
      join public.companies c on c.id = b.entity_id
      where not (b.entity_id = any (v_job.excluded_ids))
    )
    select (select jsonb_agg(hydrated.row_json order by hydrated.ordinal) from hydrated),
           (select count(*)::integer from hydrated),
           (select count(*)::integer from batch),
           (select max(batch.ordinal) from batch)
    into v_rows, v_kept, v_scanned, v_last_ordinal;
  end if;

  v_scanned := coalesce(v_scanned, 0);
  v_kept := coalesce(v_kept, 0);

  if v_scanned = 0 then
    update prospect_exports.jobs
    set status = 'ready', completed_at = now(), lease_expires_at = null, worker_id = null
    where id = p_job_id;
    return query select 0, v_job.row_count, v_job.part_count, true;
    return;
  end if;

  v_part := v_job.part_count + 1;
  if v_kept > 0 then
    insert into prospect_exports.job_parts (job_id, part_index, row_count, rows)
    values (p_job_id, v_part, v_kept, v_rows)
    on conflict (job_id, part_index) do nothing;
  end if;

  update prospect_exports.jobs
  set row_count = jobs.row_count + v_kept,
      byte_count = jobs.byte_count + case when v_kept > 0 then pg_column_size(v_rows) else 0 end,
      part_count = case when v_kept > 0 then v_part else jobs.part_count end,
      next_ordinal = v_last_ordinal,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds)),
      status = case when v_scanned < v_batch then 'ready' else jobs.status end,
      completed_at = case when v_scanned < v_batch then now() else jobs.completed_at end
  where jobs.id = p_job_id
  returning jobs.row_count, jobs.part_count, jobs.status = 'ready'
  into total_rows, total_parts, done;

  appended := v_kept;
  return next;
end;
$function$;

create or replace function prospect_exports.fail_v1(p_job_id uuid, p_error text)
returns void
language sql
security definer
set search_path = pg_catalog, prospect_exports
set statement_timeout = '15s'
as $function$
  update prospect_exports.jobs
  set status = 'failed', error = left(coalesce(p_error, 'Export failed'), 2000),
      lease_expires_at = null, worker_id = null, completed_at = now()
  where id = p_job_id;
$function$;

-- Retention. A TTL nothing enforces is not a TTL, and the parts are the bulk of
-- what an export costs, so they go with the job.
create or replace function prospect_exports.expire_jobs_v1()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, prospect_exports
set statement_timeout = '60s'
as $function$
declare
  v_removed integer;
begin
  delete from prospect_exports.jobs where expires_at <= now();
  get diagnostics v_removed = row_count;
  return v_removed;
end;
$function$;

-- How far along, and how far along the set underneath it is. Both, because
-- "building the list" and "writing the file" are different waits, and a progress
-- bar that cannot tell them apart sits at zero for the longer one.
create or replace function prospect_exports.status_v1(p_job_id uuid, p_owner_id text)
returns table(
  job_id uuid, status text, row_count bigint, byte_count bigint, part_count integer,
  set_status text, set_rows bigint, entity_type text, file_base_name text, fields text[],
  download_token text, error text, expires_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, prospect_exports, prospect_results
set statement_timeout = '15s'
as $function$
begin
  return query
  select j.id, j.status, j.row_count, j.byte_count, j.part_count,
         rs.status, rs.row_count, j.entity_type, j.file_base_name, j.fields,
         j.download_token, j.error, j.expires_at
  from prospect_exports.jobs j
  left join prospect_results.result_sets rs on rs.id = j.result_set_id
  where j.id = p_job_id and j.owner_id = p_owner_id;
  if not found then
    raise exception 'That export does not exist' using errcode = 'P0002';
  end if;
end;
$function$;

-- Are all the parts still there? UNLOGGED means a crash empties job_parts while
-- the jobs row still says 'ready'; serving that would be a file with holes in
-- it, so the download path asks first and the answer is a rebuild, not a gap.
create or replace function prospect_exports.parts_present_v1(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, prospect_exports
as $function$
  select (select j.part_count from prospect_exports.jobs j where j.id = p_job_id)
       = (select count(*)::integer from prospect_exports.job_parts p where p.job_id = p_job_id);
$function$;

-- One part, checked against owner and token every time.
create or replace function prospect_exports.part_v1(
  p_job_id uuid, p_owner_id text, p_token text, p_part_index integer
)
returns table(rows jsonb, row_count integer)
language plpgsql
security definer
set search_path = pg_catalog, prospect_exports
set statement_timeout = '30s'
as $function$
declare
  v_job prospect_exports.jobs%rowtype;
begin
  select * into v_job from prospect_exports.jobs j where j.id = p_job_id;
  if not found or v_job.owner_id is distinct from p_owner_id then
    raise exception 'That export does not exist' using errcode = 'P0002';
  end if;
  if v_job.download_token is distinct from p_token then
    raise exception 'That download link is not valid' using errcode = '42501';
  end if;
  if v_job.expires_at <= now() then
    raise exception 'That download has expired' using errcode = '22023';
  end if;
  if v_job.status <> 'ready' then
    raise exception 'That export is not finished yet' using errcode = '22023';
  end if;

  return query
  select p.rows, p.row_count from prospect_exports.job_parts p
  where p.job_id = p_job_id and p.part_index = p_part_index;
end;
$function$;

-- 4. The application's door -------------------------------------------------

create or replace function public.request_export_v1(
  p_owner_id text,
  p_request_id text,
  p_entity_type text,
  p_client_scope text,
  p_result_set_id uuid,
  p_fields text[] default '{}'::text[],
  p_keys text[] default '{}'::text[],
  p_excluded_ids text[] default '{}'::text[],
  p_file_base_name text default 'export'
)
returns table(job_id uuid, status text, row_count bigint, download_token text, reused boolean)
language sql
security definer
set search_path = pg_catalog, public, prospect_exports
set statement_timeout = '15s'
as $function$
  select * from prospect_exports.request_v1(
    p_owner_id, p_request_id, p_entity_type, p_client_scope, p_result_set_id,
    p_fields, p_keys, p_excluded_ids, p_file_base_name);
$function$;

create or replace function public.export_status_v1(p_job_id uuid, p_owner_id text)
returns table(
  job_id uuid, status text, row_count bigint, byte_count bigint, part_count integer,
  set_status text, set_rows bigint, entity_type text, file_base_name text, fields text[],
  download_token text, error text, expires_at timestamptz
)
language sql
security definer
set search_path = pg_catalog, public, prospect_exports
set statement_timeout = '15s'
as $function$
  select * from prospect_exports.status_v1(p_job_id, p_owner_id);
$function$;

create or replace function public.export_part_v1(
  p_job_id uuid, p_owner_id text, p_token text, p_part_index integer
)
returns table(rows jsonb, row_count integer)
language sql
security definer
set search_path = pg_catalog, public, prospect_exports
set statement_timeout = '30s'
as $function$
  select * from prospect_exports.part_v1(p_job_id, p_owner_id, p_token, p_part_index);
$function$;

create or replace function public.export_parts_present_v1(p_job_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, prospect_exports
as $function$
  select prospect_exports.parts_present_v1(p_job_id);
$function$;

revoke execute on function public.request_export_v1(text, text, text, text, uuid, text[], text[], text[], text) from public, anon, authenticated;
revoke execute on function public.export_status_v1(uuid, text) from public, anon, authenticated;
revoke execute on function public.export_part_v1(uuid, text, text, integer) from public, anon, authenticated;
revoke execute on function public.export_parts_present_v1(uuid) from public, anon, authenticated;
grant execute on function public.request_export_v1(text, text, text, text, uuid, text[], text[], text[], text) to service_role;
grant execute on function public.export_status_v1(uuid, text) to service_role;
grant execute on function public.export_part_v1(uuid, text, text, integer) to service_role;
grant execute on function public.export_parts_present_v1(uuid) to service_role;

-- 5. What the worker may do, and what it may not ----------------------------

-- REVOKE BEFORE GRANT, AND FROM PUBLIC FIRST. A new function is executable by
-- PUBLIC by default, so granting the worker USAGE on this schema without these
-- lines would hand it request_v1 and part_v1 as well - which is exactly what the
-- assertions below refuse, and exactly what a first dry run of this migration
-- caught. 20260902000120 and 20260902000140 revoke every function in their own
-- schemas the same way; this is not extra caution, it is the pattern.
revoke execute on function prospect_exports.request_v1(text, text, text, text, uuid, text[], text[], text[], text, interval) from public, anon, authenticated;
revoke execute on function prospect_exports.claim_next_v1(text, integer) from public, anon, authenticated;
revoke execute on function prospect_exports.build_batch_v1(uuid, integer, integer) from public, anon, authenticated;
revoke execute on function prospect_exports.fail_v1(uuid, text) from public, anon, authenticated;
revoke execute on function prospect_exports.expire_jobs_v1() from public, anon, authenticated;
revoke execute on function prospect_exports.status_v1(uuid, text) from public, anon, authenticated;
revoke execute on function prospect_exports.parts_present_v1(uuid) from public, anon, authenticated;
revoke execute on function prospect_exports.part_v1(uuid, text, text, integer) from public, anon, authenticated;

grant usage on schema prospect_exports to prospect_operator;
grant execute on function prospect_exports.claim_next_v1(text, integer) to prospect_operator;
grant execute on function prospect_exports.build_batch_v1(uuid, integer, integer) to prospect_operator;
grant execute on function prospect_exports.fail_v1(uuid, text) to prospect_operator;
grant execute on function prospect_exports.expire_jobs_v1() to prospect_operator;

-- array_append rather than `v_problems := v_problems || 'text'`. The || form
-- looks equivalent and is not: with an untyped literal on the right PostgreSQL
-- resolves it as array_cat and fails with "malformed array literal", so the
-- assertion block would report a parse error instead of the problem it found -
-- and only ever on the failure path, which is the one nobody exercises.
-- 20260902000090, 130, 140 and 160 carried the || form too. None had ever
-- fired, so none had ever been seen to be wrong; they were corrected in place
-- on 2026-09-03 rather than left as a trap for the first environment unlucky
-- enough to trip one of those assertions.
do $$
declare
  v_problems text[] := array[]::text[];
begin
  -- Allowed.
  if not has_function_privilege('prospect_operator', 'prospect_exports.claim_next_v1(text, integer)', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator cannot claim an export job');
  end if;
  if not has_function_privilege('prospect_operator', 'prospect_exports.build_batch_v1(uuid, integer, integer)', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator cannot build an export batch');
  end if;
  if not has_function_privilege('prospect_operator', 'prospect_exports.expire_jobs_v1()', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator cannot expire export jobs');
  end if;

  -- Denied. A worker that could request a job could export anything; one that
  -- could read a part would be reading prospects it has no privilege on.
  if has_function_privilege('prospect_operator', 'prospect_exports.request_v1(text, text, text, text, uuid, text[], text[], text[], text, interval)', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator can request an export, which it must not');
  end if;
  if has_function_privilege('prospect_operator', 'prospect_exports.part_v1(uuid, text, text, integer)', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator can read an export part, which it must not');
  end if;
  if has_table_privilege('prospect_operator', 'prospect_exports.job_parts', 'select') then
    v_problems := array_append(v_problems, 'prospect_operator can read job_parts directly');
  end if;
  if has_table_privilege('prospect_operator', 'prospect_exports.jobs', 'select') then
    v_problems := array_append(v_problems, 'prospect_operator can read export jobs directly');
  end if;
  if has_function_privilege('prospect_operator', 'public.search_prospect_export_v5(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean, text[])', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator can run the export search directly');
  end if;

  -- The public wrappers are the application door, and nobody else's.
  if has_function_privilege('authenticated', 'public.request_export_v1(text, text, text, text, uuid, text[], text[], text[], text)', 'execute') then
    v_problems := array_append(v_problems, 'authenticated can request an export directly');
  end if;
  if has_function_privilege('authenticated', 'public.export_part_v1(uuid, text, text, integer)', 'execute') then
    v_problems := array_append(v_problems, 'authenticated can read an export part directly');
  end if;
  if has_function_privilege('authenticated', 'public.search_company_export_v1(text, jsonb, jsonb, boolean, text, text, integer)', 'execute') then
    v_problems := array_append(v_problems, 'authenticated can run the company export directly');
  end if;

  if cardinality(v_problems) > 0 then
    raise exception using
      message = 'Export privileges are not what this migration intends',
      detail = array_to_string(v_problems, '; ');
  end if;
end $$;

commit;
