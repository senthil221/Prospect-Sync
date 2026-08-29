begin;

-- Keep company-import duplicate lookups on narrow, ordered indexes. The API also
-- commits smaller chunks and splits timed-out chunks, so this improves the common
-- path without removing the function's 15 second safety boundary.
create index if not exists idx_companies_normalized_domain_created
  on public.companies (normalized_domain, created_at)
  where normalized_domain <> '';
create index if not exists idx_companies_blank_domain_name_created
  on public.companies (normalized_name, created_at)
  where coalesce(normalized_domain, '') = '' and normalized_name <> '';

-- A client company is a first-class membership. It may be created from an
-- existing prospect relationship or pushed directly from the master directory.
create table if not exists public.client_companies (
  client_id text not null references public.clients(id) on delete cascade,
  company_id text not null references public.companies(id) on delete cascade,
  added_at timestamptz not null default now(),
  added_by text not null default '',
  primary key (client_id, company_id)
);
create index if not exists idx_client_companies_company
  on public.client_companies (company_id, client_id);
alter table public.client_companies enable row level security;
revoke all on public.client_companies from anon, authenticated;
grant select, insert, update, delete on public.client_companies to service_role;

insert into public.client_companies (client_id, company_id, added_by)
select distinct cp.client_id, p.company_id, 'membership-backfill'
from public.client_prospects cp
join public.prospects p on p.id = cp.prospect_id
where p.company_id is not null
on conflict (client_id, company_id) do nothing;

create or replace function public.sync_client_company_membership_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_company_id text;
begin
  select p.company_id into v_company_id from public.prospects p where p.id = new.prospect_id;
  if v_company_id is not null then
    insert into public.client_companies (client_id, company_id, added_by)
    values (new.client_id, v_company_id, 'prospect-membership')
    on conflict (client_id, company_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_client_company_membership on public.client_prospects;
create trigger sync_client_company_membership
after insert or update of client_id, prospect_id on public.client_prospects
for each row execute function public.sync_client_company_membership_v1();

create or replace function public.sync_changed_prospect_company_memberships_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.company_id is not null and new.company_id is distinct from old.company_id then
    insert into public.client_companies (client_id, company_id, added_by)
    select cp.client_id, new.company_id, 'prospect-company-change'
    from public.client_prospects cp
    where cp.prospect_id = new.id
    on conflict (client_id, company_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists sync_changed_prospect_company_memberships on public.prospects;
create trigger sync_changed_prospect_company_memberships
after update of company_id on public.prospects
for each row execute function public.sync_changed_prospect_company_memberships_v1();

create or replace function public.client_company_workspace_v2(
  p_client_id text,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
  with matched as materialized (
    select c.id, c.name, c.domain, c.created_at,
      coalesce(counts.prospect_count, 0)::integer as prospect_count,
      coalesce(coverage.client_count, 0)::integer as client_count
    from public.client_companies membership
    join public.companies c on c.id = membership.company_id
    left join lateral (
      select count(distinct pi.id)::integer as prospect_count
      from public.prospect_index pi
      where pi.company_id = c.id and pi.client_ids @> array[p_client_id]
    ) counts on true
    left join lateral (
      select count(*)::integer as client_count
      from public.client_companies all_memberships
      where all_memberships.company_id = c.id
    ) coverage on true
    where membership.client_id = p_client_id
      and public.company_matches_filters_v1(c, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb))
      and (p_people_scope is null or c.id in (
        select company_id from public.people_scope_company_ids_v1(p_client_id, p_people_scope)
      ))
  ), page_rows as (
    select * from matched
    order by prospect_count desc, lower(name), id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id) from page_rows), '[]'::jsonb),
    (select count(*) from matched),
    (select count(*) from matched where matched.prospect_count > 0),
    (select coalesce(sum(matched.prospect_count), 0) from matched);
$fn$;

create or replace function public.resolve_client_company_selection_v1(
  p_client_id text,
  p_domains text[] default null,
  p_names text[] default null,
  p_limit integer default 50000
)
returns table(company_id text)
language sql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
  select c.id
  from public.client_companies membership
  join public.companies c on c.id = membership.company_id
  where membership.client_id = p_client_id
    and (c.normalized_domain = any(coalesce(p_domains, array[]::text[]))
      or c.normalized_name = any(coalesce(p_names, array[]::text[])))
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 50000), 50000));
$fn$;

create or replace function public.resolve_company_action_selection_v1(
  p_client_id text default null,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_limit integer default 250000
)
returns table(company_id text)
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $fn$
  select c.id
  from public.companies c
  where (p_client_id is null or exists (
      select 1 from public.client_companies membership
      where membership.client_id = p_client_id and membership.company_id = c.id
    ))
    and (
      (p_company_ids is not null and c.id = any(p_company_ids[1:50000]))
      or (p_company_ids is null and public.company_matches_filters_v1(c, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)))
    )
    and (p_people_scope is null or c.id in (
      select company_id from public.people_scope_company_ids_v1(p_client_id, p_people_scope)
    ))
    and not (c.id = any(coalesce(p_excluded_ids, array[]::text[])))
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 250000), 250000));
$fn$;

create or replace function public.push_companies_to_client_v1(
  p_client_id text,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare v_ids text[] := array[]::text[]; v_added integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(null, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);
  insert into public.client_companies (client_id, company_id, added_by)
  select p_client_id, company_id, left(coalesce(p_actor, ''), 200) from unnest(v_ids) selected(company_id)
  on conflict (client_id, company_id) do nothing;
  get diagnostics v_added = row_count;
  return jsonb_build_object('selected', cardinality(v_ids), 'added', v_added, 'alreadyPresent', cardinality(v_ids) - v_added);
end;
$$;

create or replace function public.set_company_icp_verified_v2(
  p_client_id text,
  p_verified boolean,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare v_ids text[] := array[]::text[]; v_updated integer := 0; v_existing jsonb := '{}'::jsonb;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);
  if p_verified then
    insert into public.client_company_icp_validations (client_id, company_id, validated_at, validated_by)
    select p_client_id, company_id, now(), left(coalesce(p_actor, ''), 200) from unnest(v_ids) selected(company_id)
    on conflict (client_id, company_id) do nothing;
  else
    delete from public.client_company_icp_validations validation
    where validation.client_id = p_client_id and validation.company_id = any(v_ids);
  end if;
  get diagnostics v_updated = row_count;
  if cardinality(v_ids) > 0 then
    v_existing := public.set_company_icp_validated_v1(p_client_id, p_verified, v_ids, '', '[]'::jsonb, null, null, p_actor);
  end if;
  return v_existing || jsonb_build_object('updated', v_updated, 'selected', cardinality(v_ids));
end;
$$;

revoke execute on function public.sync_client_company_membership_v1() from public, anon, authenticated;
revoke execute on function public.sync_changed_prospect_company_memberships_v1() from public, anon, authenticated;
revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.resolve_client_company_selection_v1(text, text[], text[], integer) from public, anon, authenticated;
revoke execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) from public, anon, authenticated;
revoke execute on function public.push_companies_to_client_v1(text, text[], text, jsonb, jsonb, text[], text) from public, anon, authenticated;
revoke execute on function public.set_company_icp_verified_v2(text, boolean, text[], text, jsonb, jsonb, text[], text) from public, anon, authenticated;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;
grant execute on function public.resolve_client_company_selection_v1(text, text[], text[], integer) to service_role;
grant execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) to service_role;
grant execute on function public.push_companies_to_client_v1(text, text[], text, jsonb, jsonb, text[], text) to service_role;
grant execute on function public.set_company_icp_verified_v2(text, boolean, text[], text, jsonb, jsonb, text[], text) to service_role;

analyze public.client_companies;
commit;
