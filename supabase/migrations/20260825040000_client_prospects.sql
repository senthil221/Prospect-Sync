-- The membership table the client features have all been blocked on.
--
-- Until now a prospect belonged to a client only transitively:
-- list_memberships -> lists -> clients. That records provenance well, but it is
-- the wrong place to hang state. There was no row anywhere meaning "this
-- prospect, for this client", so there was nowhere to store an ICP-verified
-- flag, a client-scoped tag, or a blocklist decision — and pushing a master
-- record into a client was impossible without fabricating a list to hold it.
--
-- client_prospects is that row. Lists keep doing exactly what they do now.
-- Membership becomes the union of list memberships and pushed records, kept in
-- step by trigger so the two can never drift.

-- ---------------------------------------------------------------------------
-- 1. Membership
-- ---------------------------------------------------------------------------

create table if not exists public.client_prospects (
  client_id text not null references public.clients(id) on delete cascade,
  prospect_id text not null references public.prospects(id) on delete cascade,
  -- The user enters this by hand; it is never inferred. Default no, as asked.
  icp_verified boolean not null default false,
  verified_at timestamptz,
  verified_by text not null default '',
  -- 'active' | 'blocked'. Blocklisting suppresses, it never deletes.
  status text not null default 'active' check (status in ('active', 'blocked')),
  blocked_reason text not null default '',
  blocked_at timestamptz,
  -- 'import' when a list brought the record in, 'push' when it came from the
  -- master database, 'manual' for a one-off addition.
  added_via text not null default 'import' check (added_via in ('import', 'push', 'manual')),
  added_at timestamptz not null default now(),
  notes text not null default '',
  primary key (client_id, prospect_id)
);

create index if not exists idx_client_prospects_prospect on public.client_prospects (prospect_id);
create index if not exists idx_client_prospects_verified on public.client_prospects (client_id, icp_verified);
create index if not exists idx_client_prospects_status on public.client_prospects (client_id, status);

alter table public.client_prospects enable row level security;
revoke all on public.client_prospects from anon, authenticated;

-- Backfill from the existing list memberships. added_via 'import' is correct for
-- every one of them: they all arrived through an uploaded list.
insert into public.client_prospects (client_id, prospect_id, added_via, added_at)
select l.client_id, lm.prospect_id, 'import', min(lm.imported_at)
from public.list_memberships lm
join public.lists l on l.id = lm.list_id
where lm.prospect_id is not null
group by l.client_id, lm.prospect_id
on conflict (client_id, prospect_id) do nothing;

-- Keep membership in step with list changes. A prospect stays in the client
-- while ANY list still links it, or while it was pushed there directly — a push
-- must survive the deletion of an unrelated list.
create or replace function public.sync_client_prospects_from_lists()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    insert into public.client_prospects (client_id, prospect_id, added_via)
    select l.client_id, n.prospect_id, 'import'
    from new_rows n
    join public.lists l on l.id = n.list_id
    where n.prospect_id is not null
    on conflict (client_id, prospect_id) do nothing;
  end if;

  if tg_op in ('DELETE', 'UPDATE') then
    delete from public.client_prospects cp
    using (
      select distinct l.client_id, o.prospect_id
      from old_rows o
      join public.lists l on l.id = o.list_id
      where o.prospect_id is not null
    ) removed
    where cp.client_id = removed.client_id
      and cp.prospect_id = removed.prospect_id
      and cp.added_via = 'import'
      and not exists (
        select 1
        from public.list_memberships lm
        join public.lists l2 on l2.id = lm.list_id
        where l2.client_id = cp.client_id and lm.prospect_id = cp.prospect_id
      );
  end if;

  return null;
end;
$$;

drop trigger if exists trg_client_prospects_insert on public.list_memberships;
drop trigger if exists trg_client_prospects_update on public.list_memberships;
drop trigger if exists trg_client_prospects_delete on public.list_memberships;

create trigger trg_client_prospects_insert
after insert on public.list_memberships
referencing new table as new_rows
for each statement execute function public.sync_client_prospects_from_lists();

create trigger trg_client_prospects_update
after update on public.list_memberships
referencing new table as new_rows old table as old_rows
for each statement execute function public.sync_client_prospects_from_lists();

create trigger trg_client_prospects_delete
after delete on public.list_memberships
referencing old table as old_rows
for each statement execute function public.sync_client_prospects_from_lists();

-- ---------------------------------------------------------------------------
-- 2. Per-client blocklist
-- ---------------------------------------------------------------------------
-- Domains and emails, scoped to one client. Suppression, never deletion: a
-- blocked record stays visible with a badge so the reason survives.

create table if not exists public.client_blocklist (
  id text primary key default gen_random_uuid()::text,
  client_id text not null references public.clients(id) on delete cascade,
  kind text not null check (kind in ('domain', 'email')),
  value text not null,
  reason text not null default '',
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  unique (client_id, kind, value)
);

create index if not exists idx_client_blocklist_lookup on public.client_blocklist (client_id, kind, value);

alter table public.client_blocklist enable row level security;
revoke all on public.client_blocklist from anon, authenticated;

-- Apply the blocklist to a client's memberships. Values arrive already
-- normalized by lib/bulk-values.ts, which is the same normalization the import
-- path uses — so a pasted "https://www.acme.com/careers" matches acme.com.
create or replace function public.apply_client_blocklist_v1(p_client_id text)
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_blocked integer;
begin
  update public.client_prospects cp set
    status = 'blocked',
    blocked_at = coalesce(cp.blocked_at, now()),
    blocked_reason = coalesce(nullif(cp.blocked_reason, ''), matched.reason)
  from (
    select distinct cp2.prospect_id, first_value(b.reason) over (partition by cp2.prospect_id order by b.created_at) as reason
    from public.client_prospects cp2
    join public.prospect_index pi on pi.id = cp2.prospect_id
    join public.client_blocklist b on b.client_id = p_client_id
    where cp2.client_id = p_client_id
      and (
        (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
        or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
      )
  ) matched
  where cp.client_id = p_client_id
    and cp.prospect_id = matched.prospect_id
    and cp.status <> 'blocked';

  get diagnostics v_blocked = row_count;
  return v_blocked;
end;
$$;

-- Prospect ids suppressed for a client — one predicate, joined by every
-- client-scoped read so it cannot be forgotten in the export path.
create or replace function public.client_blocked_prospect_ids(p_client_id text)
returns table(prospect_id text)
language sql
stable
security definer
set search_path = public
as $$
  select cp.prospect_id
  from public.client_prospects cp
  where cp.client_id = p_client_id and cp.status = 'blocked';
$$;

-- ---------------------------------------------------------------------------
-- 3. Client-scoped tags
-- ---------------------------------------------------------------------------
-- prospect_tags.name was globally unique with no client column, so tagging a
-- prospect inside one client's workspace changed it for every other client and
-- in the master. A null client_id keeps a tag agency-wide, which is the old
-- behaviour and still useful.

alter table public.prospect_tags add column if not exists client_id text references public.clients(id) on delete cascade;

do $$
begin
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.prospect_tags'::regclass and conname = 'prospect_tags_name_key'
  ) then
    alter table public.prospect_tags drop constraint prospect_tags_name_key;
  end if;
end;
$$;

-- One name per client, and one name agency-wide. Two partial indexes rather
-- than a unique constraint, because null client_id must not defeat uniqueness.
create unique index if not exists idx_prospect_tags_client_name
  on public.prospect_tags (client_id, lower(name)) where client_id is not null;
create unique index if not exists idx_prospect_tags_global_name
  on public.prospect_tags (lower(name)) where client_id is null;

-- ---------------------------------------------------------------------------
-- 4. Reads: membership, ICP status, and blocklist in the flat index
-- ---------------------------------------------------------------------------

alter table public.prospect_index
  add column if not exists icp_verified_client_ids text[] not null default '{}'::text[],
  add column if not exists blocked_client_ids text[] not null default '{}'::text[];

create index if not exists idx_prospect_index_icp_verified on public.prospect_index using gin (icp_verified_client_ids);
create index if not exists idx_prospect_index_blocked on public.prospect_index using gin (blocked_client_ids);

create or replace function public.reindex_prospects(p_ids text[])
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  affected integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return 0;
  end if;

  with computed as (
    select
      p.id,
      p.first_name, p.last_name, p.full_name, p.work_email, p.personal_email,
      p.mobile_number, p.linkedin_url, p.title, p.seniority, p.department,
      p.city, p.state, p.country, p.company_id, p.all_data, p.created_at, p.updated_at,
      coalesce(nullif(p.location, ''), concat_ws(', ', nullif(p.city, ''), nullif(p.state, ''), nullif(p.country, ''))) as location,
      coalesce(co.name, '') as company_name,
      coalesce(co.domain, '') as company_domain,
      count(distinct lm.list_id)::integer as list_count,
      -- Client membership now comes from client_prospects, so a pushed record
      -- counts even though no list references it.
      (select count(*)::integer from public.client_prospects cp where cp.prospect_id = p.id) as client_count,
      coalesce(array_agg(distinct l.name order by l.name) filter (where l.id is not null), '{}'::text[]) as list_names,
      coalesce((select array_agg(distinct cl2.name order by cl2.name)
        from public.client_prospects cp join public.clients cl2 on cl2.id = cp.client_id
        where cp.prospect_id = p.id), '{}'::text[]) as client_names,
      coalesce(array_agg(distinct l.id order by l.id) filter (where l.id is not null), '{}'::text[]) as list_ids,
      coalesce((select array_agg(distinct cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id), '{}'::text[]) as client_ids,
      coalesce((select array_agg(cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.icp_verified), '{}'::text[]) as icp_verified_client_ids,
      coalesce((select array_agg(cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'blocked'), '{}'::text[]) as blocked_client_ids,
      coalesce(jsonb_agg(distinct jsonb_build_object(
        'listId', l.id, 'listName', l.name, 'clientId', cl.id, 'clientName', cl.name
      )) filter (where l.id is not null), '[]'::jsonb) as list_memberships,
      coalesce(co.esp, '') as esp,
      coalesce(co.email_provider_type, 'Unknown') as email_provider_type,
      coalesce(co.mx_records, '{}'::text[]) as mx_records,
      co.mx_status, co.mx_checked_at,
      coalesce(p.keywords, '{}'::text[]) as keywords,
      co.employee_count_min, co.employee_count_max,
      coalesce(co.location, '') as company_location,
      coalesce(co.city, '') as company_city,
      coalesce(co.state, '') as company_state,
      coalesce(co.country, '') as company_country,
      coalesce((
        select jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'color', pt.color, 'clientId', pt.client_id) order by pt.name)
        from public.prospect_tag_links ptl join public.prospect_tags pt on pt.id = ptl.tag_id
        where ptl.prospect_id = p.id
      ), '[]'::jsonb) as tags,
      coalesce((
        select string_agg(pt.name, ' ' order by pt.name)
        from public.prospect_tag_links ptl join public.prospect_tags pt on pt.id = ptl.tag_id
        where ptl.prospect_id = p.id
      ), '') as tag_text,
      (select max(ce.contacted_at) from public.contact_events ce where ce.prospect_id = p.id) as last_contacted_at,
      coalesce((select count(*) from public.contact_events ce where ce.prospect_id = p.id), 0)::integer as contact_count
    from public.prospects p
    left join public.companies co on co.id = p.company_id
    left join public.list_memberships lm on lm.prospect_id = p.id
    left join public.lists l on l.id = lm.list_id
    left join public.clients cl on cl.id = l.client_id
    where p.id = any(p_ids)
    group by p.id, co.id
  ), upserted as (
    insert into public.prospect_index (
      id, first_name, last_name, full_name, work_email, personal_email, mobile_number,
      linkedin_url, title, seniority, department, city, state, country, location, company_id,
      company_name, company_domain, all_data, created_at, updated_at, list_count, client_count,
      list_names, client_names, list_ids, client_ids, list_memberships, esp, email_provider_type,
      mx_records, mx_status, mx_checked_at, keywords, employee_count_min, employee_count_max,
      company_location, company_city, company_state, company_country, tags, tag_text,
      last_contacted_at, contact_count, icp_verified_client_ids, blocked_client_ids, search_text
    )
    select
      c.id, c.first_name, c.last_name, c.full_name, c.work_email, c.personal_email, c.mobile_number,
      c.linkedin_url, c.title, c.seniority, c.department, c.city, c.state, c.country, c.location, c.company_id,
      c.company_name, c.company_domain, c.all_data, c.created_at, c.updated_at, c.list_count, c.client_count,
      c.list_names, c.client_names, c.list_ids, c.client_ids, c.list_memberships, c.esp, c.email_provider_type,
      c.mx_records, c.mx_status, c.mx_checked_at, c.keywords, c.employee_count_min, c.employee_count_max,
      c.company_location, c.company_city, c.company_state, c.company_country, c.tags, c.tag_text,
      c.last_contacted_at, c.contact_count, c.icp_verified_client_ids, c.blocked_client_ids,
      concat_ws(' ',
        c.full_name, c.work_email, c.personal_email, c.mobile_number,
        c.title, c.seniority, c.department, array_to_string(c.keywords, ' '),
        c.company_name, c.company_domain, c.linkedin_url,
        c.location, c.city, c.state, c.country,
        c.company_location, c.company_city, c.company_state, c.company_country,
        c.esp, c.email_provider_type,
        array_to_string(c.list_names, ' '), array_to_string(c.client_names, ' '), c.tag_text
      )
    from computed c
    on conflict (id) do update set
      first_name = excluded.first_name, last_name = excluded.last_name, full_name = excluded.full_name,
      work_email = excluded.work_email, personal_email = excluded.personal_email, mobile_number = excluded.mobile_number,
      linkedin_url = excluded.linkedin_url, title = excluded.title, seniority = excluded.seniority,
      department = excluded.department, city = excluded.city, state = excluded.state, country = excluded.country,
      location = excluded.location,
      company_id = excluded.company_id, company_name = excluded.company_name, company_domain = excluded.company_domain,
      all_data = excluded.all_data, created_at = excluded.created_at, updated_at = excluded.updated_at,
      list_count = excluded.list_count, client_count = excluded.client_count, list_names = excluded.list_names,
      client_names = excluded.client_names, list_ids = excluded.list_ids, client_ids = excluded.client_ids,
      list_memberships = excluded.list_memberships, esp = excluded.esp, email_provider_type = excluded.email_provider_type,
      mx_records = excluded.mx_records, mx_status = excluded.mx_status, mx_checked_at = excluded.mx_checked_at,
      keywords = excluded.keywords, employee_count_min = excluded.employee_count_min, employee_count_max = excluded.employee_count_max,
      company_location = excluded.company_location, company_city = excluded.company_city, company_state = excluded.company_state,
      company_country = excluded.company_country, tags = excluded.tags, tag_text = excluded.tag_text,
      last_contacted_at = excluded.last_contacted_at, contact_count = excluded.contact_count,
      icp_verified_client_ids = excluded.icp_verified_client_ids,
      blocked_client_ids = excluded.blocked_client_ids,
      search_text = excluded.search_text
    returning 1
  )
  select count(*)::integer into affected from upserted;

  return affected;
end;
$$;

revoke execute on function public.reindex_prospects(text[]) from public, anon, authenticated;
revoke execute on function public.sync_client_prospects_from_lists() from public, anon, authenticated;
revoke execute on function public.apply_client_blocklist_v1(text) from public, anon, authenticated;
revoke execute on function public.client_blocked_prospect_ids(text) from public, anon, authenticated;
grant execute on function public.reindex_prospects(text[]) to service_role;
grant execute on function public.apply_client_blocklist_v1(text) to service_role;
grant execute on function public.client_blocked_prospect_ids(text) to service_role;

-- Backfill the two new index columns without re-deriving the other 40.
update public.prospect_index pi set
  icp_verified_client_ids = coalesce((select array_agg(cp.client_id order by cp.client_id)
    from public.client_prospects cp where cp.prospect_id = pi.id and cp.icp_verified), '{}'::text[]),
  blocked_client_ids = coalesce((select array_agg(cp.client_id order by cp.client_id)
    from public.client_prospects cp where cp.prospect_id = pi.id and cp.status = 'blocked'), '{}'::text[]),
  client_ids = coalesce((select array_agg(distinct cp.client_id order by cp.client_id)
    from public.client_prospects cp where cp.prospect_id = pi.id), '{}'::text[]),
  client_count = (select count(*)::integer from public.client_prospects cp where cp.prospect_id = pi.id);

-- client_summaries now counts real memberships, so a pushed prospect is included.
create or replace view public.client_summaries as
select c.id, c.name, c.created_at,
  (select count(*)::integer from public.lists l where l.client_id = c.id) as list_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id) as prospect_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.icp_verified) as icp_verified_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.status = 'blocked') as blocked_count
from public.clients c;

revoke all on public.client_summaries from anon, authenticated;

analyze public.client_prospects;
analyze public.prospect_index;

-- ---------------------------------------------------------------------------
-- 5. Smoke test
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_row record;
  v_before bigint;
  v_after bigint;
begin
  -- The backfill must agree with the list-derived membership it replaced.
  select count(*) into v_before from (
    select distinct l.client_id, lm.prospect_id
    from public.list_memberships lm join public.lists l on l.id = lm.list_id
    where lm.prospect_id is not null
  ) derived;
  select count(*) into v_after from public.client_prospects where added_via = 'import';
  if v_after < v_before then
    raise exception 'client_prospects backfill lost rows: % derived vs % stored', v_before, v_after;
  end if;

  -- Membership, ICP and blocklist reads.
  perform * from public.client_summaries limit 1;
  perform * from public.client_blocked_prospect_ids((select id from public.clients limit 1));
  perform public.apply_client_blocklist_v1((select id from public.clients limit 1));

  -- The index must still build with the two new columns.
  select * into v_row from public.reindex_scope_v1(p_prospect_ids => array(select id from public.prospects limit 3));
  select * into v_row from public.search_prospect_workspace_v12(
    p_client_id => (select id from public.clients limit 1), p_with_total => false);
end;
$smoke$;
