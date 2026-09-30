-- The Clients list, cached until its counts can have changed.
--
-- client_summaries subtracts people and companies with incomplete info from
-- each client's totals. Doing that means reading every company with no text
-- (63k), their prospects (81k) and every active membership (870k): 0.7s warm,
-- 4s cold on 2026-09-30, and pg_stat_statements has it peaking at 11.5s. The
-- single-client read (/api/clients/[id]) pays the same, because the view's
-- CTEs are materialized whatever the filter.
--
-- The counts only move when memberships, a company's text, or a prospect's
-- company change. Each of those statements now bumps data_version_client_counts
-- (statement-level, like data_version_company), and client_summaries_v1
-- reuses the last computed counts while that version is unchanged.
-- Verification, enrichment and the other writers that keep bumping the
-- prospect and company versions do not touch it.
--
-- Name, folder, archive state and list count are read live on every call, so
-- a rename or a new client never waits for the cache. The cached counts are
-- also recomputed after 5 minutes whatever the version says: a writer bumps
-- the version when its statement runs, before it commits, so a read landing
-- in that gap could cache the pre-commit counts under the new version.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create sequence if not exists public.data_version_client_counts;

create table if not exists public.client_summary_cache (
  id boolean primary key default true check (id),
  version bigint not null,
  computed_at timestamptz not null,
  counts jsonb not null
);

comment on table public.client_summary_cache is
  'One row: client_summaries'' per-client counts as of data_version_client_counts = version. Read through client_summaries_v1.';

alter table public.client_summary_cache enable row level security;
revoke all on public.client_summary_cache from public, anon, authenticated;
grant select, insert, update, delete on public.client_summary_cache to service_role;
revoke all on sequence public.data_version_client_counts from public, anon, authenticated;

create or replace function public.bump_data_version_client_counts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform nextval('public.data_version_client_counts');
  return null;
end;
$$;

revoke execute on function public.bump_data_version_client_counts() from public, anon, authenticated;

drop trigger if exists trg_client_counts_client_prospects on public.client_prospects;
create trigger trg_client_counts_client_prospects
  after insert or update or delete on public.client_prospects
  for each statement execute function public.bump_data_version_client_counts();

drop trigger if exists trg_client_counts_client_companies on public.client_companies;
create trigger trg_client_counts_client_companies
  after insert or update or delete on public.client_companies
  for each statement execute function public.bump_data_version_client_counts();

-- A company's text decides whether it (and its people) count as incomplete.
drop trigger if exists trg_client_counts_companies_text on public.companies;
create trigger trg_client_counts_companies_text
  after update of keywords, short_description on public.companies
  for each statement execute function public.bump_data_version_client_counts();
drop trigger if exists trg_client_counts_companies_rows on public.companies;
create trigger trg_client_counts_companies_rows
  after insert or delete on public.companies
  for each statement execute function public.bump_data_version_client_counts();

-- A prospect moving to another company (a merge) can move it in or out of
-- incomplete info.
drop trigger if exists trg_client_counts_prospects_company on public.prospects;
create trigger trg_client_counts_prospects_company
  after update of company_id or delete on public.prospects
  for each statement execute function public.bump_data_version_client_counts();

create or replace function public.client_summaries_v1(p_client_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  v_version bigint := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  v_cache public.client_summary_cache%rowtype;
  v_counts jsonb;
begin
  select * into v_cache from public.client_summary_cache where id;
  if found and v_cache.version = v_version and v_cache.computed_at > now() - interval '5 minutes'
     and not exists (select 1 from public.clients c where not (v_cache.counts ? c.id)) then
    v_counts := v_cache.counts;
  else
    select coalesce(jsonb_object_agg(s.id, jsonb_build_object(
             'prospect_count', s.prospect_count, 'icp_verified_count', s.icp_verified_count,
             'blocked_count', s.blocked_count, 'company_count', s.company_count)), '{}'::jsonb)
      into v_counts
      from public.client_summaries s;
    insert into public.client_summary_cache (id, version, computed_at, counts)
    values (true, v_version, now(), v_counts)
    on conflict (id) do update
      set version = excluded.version, computed_at = excluded.computed_at, counts = excluded.counts;
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'name', c.name, 'created_at', c.created_at,
             'list_count', (select count(*)::integer from public.lists l where l.client_id = c.id),
             'prospect_count', coalesce((v_counts->c.id->>'prospect_count')::integer, 0),
             'icp_verified_count', coalesce((v_counts->c.id->>'icp_verified_count')::integer, 0),
             'blocked_count', coalesce((v_counts->c.id->>'blocked_count')::integer, 0),
             'company_count', coalesce((v_counts->c.id->>'company_count')::integer, 0),
             'folder_id', c.folder_id, 'archived_at', c.archived_at)
           order by c.name), '[]'::jsonb)
      from public.clients c
     where p_client_id is null or c.id = p_client_id);
end;
$$;

revoke execute on function public.client_summaries_v1(text) from public, anon, authenticated;
grant execute on function public.client_summaries_v1(text) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: the function answers exactly what the view does, serves
-- the cache while nothing changed, and recomputes after a membership change.
do $$
declare
  v_fresh jsonb;
  v_view jsonb;
  v_version bigint;
  v_client text;
  v_company text;
begin
  begin
    delete from public.client_summary_cache;
    v_fresh := public.client_summaries_v1(null);
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', s.id, 'name', s.name, 'created_at', s.created_at, 'list_count', s.list_count,
             'prospect_count', s.prospect_count, 'icp_verified_count', s.icp_verified_count,
             'blocked_count', s.blocked_count, 'company_count', s.company_count,
             'folder_id', s.folder_id, 'archived_at', s.archived_at) order by s.name), '[]'::jsonb)
      into v_view from public.client_summaries s;
    if v_fresh <> v_view then
      raise exception 'Client summaries proof: the function and the view disagree';
    end if;

    -- A second read is served from the cache (same version, same answer).
    select version into v_version from public.client_summary_cache;
    if public.client_summaries_v1(null) <> v_fresh
       or (select version from public.client_summary_cache) <> v_version then
      raise exception 'Client summaries proof: the cache was not reused';
    end if;

    -- A membership change moves the version and the next read recomputes.
    select cc.client_id, cc.company_id into v_client, v_company
      from public.client_companies cc join public.companies c on c.id = cc.company_id
     where public.company_has_icp_text_v1(c.keywords, c.short_description)
     limit 1;
    if v_client is not null then
      delete from public.client_companies where client_id = v_client and company_id = v_company;
      if coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0) = v_version then
        raise exception 'Client summaries proof: removing a company did not move the version';
      end if;
      if (select (e->>'company_count')::int from jsonb_array_elements(public.client_summaries_v1(v_client)) e)
         <> (select (e->>'company_count')::int from jsonb_array_elements(v_fresh) e where e->>'id' = v_client) - 1 then
        raise exception 'Client summaries proof: the count did not follow the change';
      end if;
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'Client summaries proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
