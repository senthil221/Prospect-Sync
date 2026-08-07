create table if not exists public.saved_views (
  id text primary key,
  name text not null,
  definition jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.prospect_tags (
  id text primary key,
  name text not null unique,
  color text not null default 'blue',
  created_at timestamptz not null default now()
);

create table if not exists public.prospect_tag_links (
  prospect_id text not null references public.prospects(id) on delete cascade,
  tag_id text not null references public.prospect_tags(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (prospect_id, tag_id)
);

create table if not exists public.client_settings (
  client_id text primary key references public.clients(id) on delete cascade,
  cooldown_days integer not null default 90 check (cooldown_days between 0 and 730),
  updated_at timestamptz not null default now()
);

create table if not exists public.contact_events (
  id text primary key,
  prospect_id text not null references public.prospects(id) on delete cascade,
  client_id text not null references public.clients(id) on delete cascade,
  contacted_at timestamptz not null default now(),
  channel text not null default 'email',
  campaign_name text not null default '',
  outcome text not null default 'contacted',
  notes text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists idx_contact_events_prospect on public.contact_events(prospect_id, contacted_at desc);
create index if not exists idx_contact_events_client on public.contact_events(client_id, contacted_at desc);
create index if not exists idx_tag_links_tag on public.prospect_tag_links(tag_id, prospect_id);

insert into public.client_settings(client_id)
select id from public.clients
on conflict (client_id) do nothing;

create or replace function public.search_prospect_workspace_v3(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with enriched as materialized (
    select ps.*,
      activity.last_contacted_at,
      coalesce(activity.contact_count, 0)::integer as contact_count,
      coalesce(tags.tag_names, '[]'::jsonb) as tags
    from public.prospect_summaries ps
    left join lateral (
      select max(ce.contacted_at) as last_contacted_at, count(*) as contact_count
      from public.contact_events ce where ce.prospect_id = ps.id
    ) activity on true
    left join lateral (
      select jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'color', pt.color) order by pt.name) as tag_names
      from public.prospect_tag_links ptl
      join public.prospect_tags pt on pt.id = ptl.tag_id
      where ptl.prospect_id = ps.id
    ) tags on true
  ), filtered as materialized (
    select ps.*
    from enriched ps
    where (
      trim(coalesce(p_search, '')) = ''
      or concat_ws(' ', ps.full_name, ps.work_email, ps.personal_email, ps.title,
        ps.company_name, ps.company_domain, ps.linkedin_url, ps.country, ps.all_data::text, ps.tags::text)
        ilike '%' || trim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__company' then ps.company_name
          when '__email' then coalesce(nullif(ps.work_email, ''), ps.personal_email)
          when '__title' then ps.title
          when '__linkedin' then ps.linkedin_url
          when '__country' then ps.country
          when '__seniority' then ps.seniority
          when '__department' then ps.department
          when '__tags' then ps.tags::text
          when '__last_contacted' then ps.last_contacted_at::text
          else ps.all_data ->> (filter_item->>'field')
        end, '') as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
        )
        when 'not_equals' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
        )
        when 'not_contains' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
        when 'empty' then trim(candidate.candidate_value) = ''
        when 'not_empty' then trim(candidate.candidate_value) <> ''
        else exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
      end
    )
  ), sorted as (
    select * from filtered
    order by
      case when p_sort = 'name' and lower(p_direction) = 'asc' then lower(full_name) end asc,
      case when p_sort = 'name' and lower(p_direction) = 'desc' then lower(full_name) end desc,
      case when p_sort = 'company' and lower(p_direction) = 'asc' then lower(company_name) end asc,
      case when p_sort = 'company' and lower(p_direction) = 'desc' then lower(company_name) end desc,
      case when p_sort = 'title' and lower(p_direction) = 'asc' then lower(title) end asc,
      case when p_sort = 'title' and lower(p_direction) = 'desc' then lower(title) end desc,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'asc' then last_contacted_at end asc nulls first,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'desc' then last_contacted_at end desc nulls last,
      case when p_sort = 'created_at' and lower(p_direction) = 'asc' then created_at end asc,
      created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select
    coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb),
    (select count(*) from filtered);
$$;

create or replace function public.list_workspace(
  p_list_id text,
  p_search text default '',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with matched as materialized (
    select ps.*, lm.raw_data as list_data, lm.imported_at,
      contact.last_contacted_at,
      case when contact.last_contacted_at is null then null else contact.last_contacted_at + make_interval(days => coalesce(settings.cooldown_days, 90)) end as next_eligible_at,
      (contact.last_contacted_at is null or contact.last_contacted_at + make_interval(days => coalesce(settings.cooldown_days, 90)) <= now()) as eligible
    from public.list_memberships lm
    join public.lists l on l.id = lm.list_id
    join public.prospect_summaries ps on ps.id = lm.prospect_id
    left join public.client_settings settings on settings.client_id = l.client_id
    left join lateral (
      select max(ce.contacted_at) as last_contacted_at from public.contact_events ce
      where ce.prospect_id = ps.id and ce.client_id = l.client_id
    ) contact on true
    where lm.list_id = p_list_id
      and (trim(coalesce(p_search, '')) = '' or concat_ws(' ', ps.full_name, ps.work_email, ps.title, ps.company_name, lm.raw_data::text) ilike '%' || trim(p_search) || '%')
  ), page_rows as (
    select * from matched order by imported_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows) order by imported_at desc) from page_rows), '[]'::jsonb),
    (select count(*) from matched);
$$;

create or replace function public.data_quality_overview()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'total', count(*),
    'missingEmail', count(*) filter (where trim(coalesce(p.work_email, '')) = '' and trim(coalesce(p.personal_email, '')) = ''),
    'missingTitle', count(*) filter (where trim(coalesce(p.title, '')) = ''),
    'missingLinkedin', count(*) filter (where trim(coalesce(p.linkedin_url, '')) = ''),
    'missingCompany', count(*) filter (where p.company_id is null),
    'missingDomain', count(*) filter (where trim(coalesce(c.domain, '')) = ''),
    'staleRecords', count(*) filter (where p.updated_at < now() - interval '180 days'),
    'potentialDuplicateGroups', (
      select count(*) from (
        select lower(trim(p2.full_name)), coalesce(p2.company_id, '')
        from public.prospects p2 where trim(p2.full_name) <> '' and p2.company_id is not null
        group by lower(trim(p2.full_name)), p2.company_id having count(*) > 1
      ) duplicate_groups
    )
  )
  from public.prospects p left join public.companies c on c.id = p.company_id;
$$;

create or replace function public.find_duplicate_candidates(p_limit integer default 100)
returns table(result_rows jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'left', to_jsonb(a), 'right', to_jsonb(b),
    'reason', 'Same normalized name and company', 'confidence', 90
  )), '[]'::jsonb)
  from (
    select p1.* from public.prospect_summaries p1
    join public.prospects p2 on p1.id < p2.id and lower(trim(p1.full_name)) = lower(trim(p2.full_name)) and p1.company_id = p2.company_id
    where trim(p1.full_name) <> '' and p1.company_id is not null
    order by p1.updated_at desc limit greatest(1, least(coalesce(p_limit, 100), 250))
  ) a
  join lateral (
    select p2.* from public.prospect_summaries p2
    where a.id < p2.id and lower(trim(a.full_name)) = lower(trim(p2.full_name)) and a.company_id = p2.company_id
    order by p2.updated_at desc limit 1
  ) b on true;
$$;

create or replace function public.merge_prospects(p_keep_id text, p_merge_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_keep_id = p_merge_id then raise exception 'Choose two different prospects.'; end if;
  if not exists (select 1 from public.prospects where id = p_keep_id) or not exists (select 1 from public.prospects where id = p_merge_id) then
    raise exception 'Prospect not found.';
  end if;

  update public.prospects as keep_record set
    first_name = coalesce(nullif(keep_record.first_name, ''), source_record.first_name),
    last_name = coalesce(nullif(keep_record.last_name, ''), source_record.last_name),
    full_name = coalesce(nullif(keep_record.full_name, ''), source_record.full_name),
    work_email = coalesce(nullif(keep_record.work_email, ''), source_record.work_email),
    personal_email = coalesce(nullif(keep_record.personal_email, ''), source_record.personal_email),
    mobile_number = coalesce(nullif(keep_record.mobile_number, ''), source_record.mobile_number),
    linkedin_url = coalesce(nullif(keep_record.linkedin_url, ''), source_record.linkedin_url),
    title = coalesce(nullif(keep_record.title, ''), source_record.title),
    seniority = coalesce(nullif(keep_record.seniority, ''), source_record.seniority),
    department = coalesce(nullif(keep_record.department, ''), source_record.department),
    city = coalesce(nullif(keep_record.city, ''), source_record.city),
    state = coalesce(nullif(keep_record.state, ''), source_record.state),
    country = coalesce(nullif(keep_record.country, ''), source_record.country),
    company_id = coalesce(keep_record.company_id, source_record.company_id),
    all_data = source_record.all_data || keep_record.all_data,
    updated_at = now()
  from public.prospects as source_record
  where keep_record.id = p_keep_id and source_record.id = p_merge_id;

  insert into public.list_memberships(list_id, prospect_id, import_id, raw_data, imported_at)
  select list_id, p_keep_id, import_id, raw_data, imported_at from public.list_memberships where prospect_id = p_merge_id
  on conflict (list_id, prospect_id) do update set raw_data = excluded.raw_data || list_memberships.raw_data;
  delete from public.list_memberships where prospect_id = p_merge_id;
  update public.list_rows set prospect_id = p_keep_id where prospect_id = p_merge_id;
  update public.prospect_identifiers set prospect_id = p_keep_id where prospect_id = p_merge_id;
  insert into public.prospect_tag_links(prospect_id, tag_id)
  select p_keep_id, tag_id from public.prospect_tag_links where prospect_id = p_merge_id on conflict do nothing;
  delete from public.prospect_tag_links where prospect_id = p_merge_id;
  update public.contact_events set prospect_id = p_keep_id where prospect_id = p_merge_id;
  delete from public.prospects where id = p_merge_id;
  return jsonb_build_object('kept', p_keep_id, 'merged', p_merge_id);
end;
$$;

alter table public.saved_views enable row level security;
alter table public.prospect_tags enable row level security;
alter table public.prospect_tag_links enable row level security;
alter table public.client_settings enable row level security;
alter table public.contact_events enable row level security;

revoke all on public.saved_views, public.prospect_tags, public.prospect_tag_links, public.client_settings, public.contact_events from anon, authenticated;
revoke execute on function public.search_prospect_workspace_v3(text, jsonb, text, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.list_workspace(text, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.data_quality_overview() from public, anon, authenticated;
revoke execute on function public.find_duplicate_candidates(integer) from public, anon, authenticated;
revoke execute on function public.merge_prospects(text, text) from public, anon, authenticated;

grant execute on function public.search_prospect_workspace_v3(text, jsonb, text, text, integer, integer) to service_role;
grant execute on function public.list_workspace(text, text, integer, integer) to service_role;
grant execute on function public.data_quality_overview() to service_role;
grant execute on function public.find_duplicate_candidates(integer) to service_role;
grant execute on function public.merge_prospects(text, text) to service_role;
