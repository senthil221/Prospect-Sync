-- Prospect search index: a flat, always-fresh denormalized copy of prospect_summaries
-- plus a precomputed search_text, so reads never re-aggregate the whole database.
-- Maintained incrementally by reindex_prospects(...) called from every write path.

create extension if not exists pg_trgm;

create table if not exists public.prospect_index (
  id text primary key references public.prospects(id) on delete cascade,
  first_name text not null default '',
  last_name text not null default '',
  full_name text not null default '',
  work_email text not null default '',
  personal_email text not null default '',
  mobile_number text not null default '',
  linkedin_url text not null default '',
  title text not null default '',
  seniority text not null default '',
  department text not null default '',
  city text not null default '',
  state text not null default '',
  country text not null default '',
  company_id text,
  company_name text not null default '',
  company_domain text not null default '',
  all_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  list_count integer not null default 0,
  client_count integer not null default 0,
  list_names text[] not null default '{}'::text[],
  client_names text[] not null default '{}'::text[],
  list_ids text[] not null default '{}'::text[],
  client_ids text[] not null default '{}'::text[],
  list_memberships jsonb not null default '[]'::jsonb,
  esp text not null default '',
  email_provider_type text not null default 'Unknown',
  mx_records text[] not null default '{}'::text[],
  mx_status text,
  mx_checked_at timestamptz,
  keywords text[] not null default '{}'::text[],
  employee_count_min integer,
  employee_count_max integer,
  company_location text not null default '',
  company_city text not null default '',
  company_state text not null default '',
  company_country text not null default '',
  tags jsonb not null default '[]'::jsonb,
  tag_text text not null default '',
  last_contacted_at timestamptz,
  contact_count integer not null default 0,
  search_text text not null default ''
);

-- Substring search (ILIKE '%term%') is served by the trigram GIN index.
create index if not exists idx_prospect_index_search_trgm on public.prospect_index using gin (search_text gin_trgm_ops);
create index if not exists idx_prospect_index_company_trgm on public.prospect_index using gin (company_name gin_trgm_ops);
create index if not exists idx_prospect_index_title_trgm on public.prospect_index using gin (title gin_trgm_ops);
create index if not exists idx_prospect_index_keywords on public.prospect_index using gin (keywords);
create index if not exists idx_prospect_index_list_names on public.prospect_index using gin (list_names);
create index if not exists idx_prospect_index_client_names on public.prospect_index using gin (client_names);
create index if not exists idx_prospect_index_client_ids on public.prospect_index using gin (client_ids);
create index if not exists idx_prospect_index_full_name_lower on public.prospect_index (lower(full_name));
create index if not exists idx_prospect_index_company_name_lower on public.prospect_index (lower(company_name));
create index if not exists idx_prospect_index_title_lower on public.prospect_index (lower(title));
create index if not exists idx_prospect_index_created_at on public.prospect_index (created_at desc, id);
create index if not exists idx_prospect_index_last_contacted on public.prospect_index (last_contacted_at desc nulls last);
create index if not exists idx_prospect_index_employees on public.prospect_index (employee_count_min, employee_count_max);

alter table public.prospect_index enable row level security;
revoke all on public.prospect_index from anon, authenticated;

-- Recompute and upsert flat index rows for the given prospect ids.
create or replace function public.reindex_prospects(p_ids text[])
returns integer
language plpgsql
security definer
set search_path = public
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
      coalesce(co.name, '') as company_name,
      coalesce(co.domain, '') as company_domain,
      count(distinct lm.list_id)::integer as list_count,
      count(distinct l.client_id)::integer as client_count,
      coalesce(array_agg(distinct l.name order by l.name) filter (where l.id is not null), '{}'::text[]) as list_names,
      coalesce(array_agg(distinct cl.name order by cl.name) filter (where cl.id is not null), '{}'::text[]) as client_names,
      coalesce(array_agg(distinct l.id order by l.id) filter (where l.id is not null), '{}'::text[]) as list_ids,
      coalesce(array_agg(distinct cl.id order by cl.id) filter (where cl.id is not null), '{}'::text[]) as client_ids,
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
        select jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'color', pt.color) order by pt.name)
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
      linkedin_url, title, seniority, department, city, state, country, company_id,
      company_name, company_domain, all_data, created_at, updated_at, list_count, client_count,
      list_names, client_names, list_ids, client_ids, list_memberships, esp, email_provider_type,
      mx_records, mx_status, mx_checked_at, keywords, employee_count_min, employee_count_max,
      company_location, company_city, company_state, company_country, tags, tag_text,
      last_contacted_at, contact_count, search_text
    )
    select
      c.id, c.first_name, c.last_name, c.full_name, c.work_email, c.personal_email, c.mobile_number,
      c.linkedin_url, c.title, c.seniority, c.department, c.city, c.state, c.country, c.company_id,
      c.company_name, c.company_domain, c.all_data, c.created_at, c.updated_at, c.list_count, c.client_count,
      c.list_names, c.client_names, c.list_ids, c.client_ids, c.list_memberships, c.esp, c.email_provider_type,
      c.mx_records, c.mx_status, c.mx_checked_at, c.keywords, c.employee_count_min, c.employee_count_max,
      c.company_location, c.company_city, c.company_state, c.company_country, c.tags, c.tag_text,
      c.last_contacted_at, c.contact_count,
      concat_ws(' ',
        c.full_name, c.work_email, c.personal_email, c.title, array_to_string(c.keywords, ' '),
        c.company_name, c.company_domain, c.linkedin_url, c.city, c.state, c.country,
        c.company_location, c.company_city, c.company_state, c.company_country,
        c.all_data::text, c.esp, c.email_provider_type, array_to_string(c.mx_records, ' '),
        array_to_string(c.list_names, ' '), array_to_string(c.client_names, ' '), c.tag_text
      )
    from computed c
    on conflict (id) do update set
      first_name = excluded.first_name, last_name = excluded.last_name, full_name = excluded.full_name,
      work_email = excluded.work_email, personal_email = excluded.personal_email, mobile_number = excluded.mobile_number,
      linkedin_url = excluded.linkedin_url, title = excluded.title, seniority = excluded.seniority,
      department = excluded.department, city = excluded.city, state = excluded.state, country = excluded.country,
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
      search_text = excluded.search_text
    returning 1
  )
  select count(*)::integer into affected from upserted;

  return affected;
end;
$$;

create or replace function public.reindex_prospects_of_lists(p_list_ids text[])
returns integer
language sql
security definer
set search_path = public
as $$
  select public.reindex_prospects(array(
    select distinct lm.prospect_id from public.list_memberships lm where lm.list_id = any(p_list_ids)
  ));
$$;

create or replace function public.reindex_prospects_of_companies(p_company_ids text[])
returns integer
language sql
security definer
set search_path = public
as $$
  select public.reindex_prospects(array(
    select p.id from public.prospects p where p.company_id = any(p_company_ids)
  ));
$$;

-- Full rebuild: backfill after applying this migration, and a manual safety net.
create or replace function public.reindex_all()
returns integer
language sql
security definer
set search_path = public
as $$
  select public.reindex_prospects(array(select id from public.prospects));
$$;

-- Fast workspace read: identical filter/search/sort semantics to v6, but scanning the
-- flat prospect_index (indexed) instead of re-aggregating prospect_summaries.
create or replace function public.search_prospect_workspace_v7(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_client_id text default null
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with filtered as (
    select ps.*
    from public.prospect_index ps
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
    and (
      btrim(coalesce(p_search, '')) = ''
      or ps.search_text ilike '%' || btrim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__first_name' then ps.first_name
          when '__last_name' then ps.last_name
          when '__company' then ps.company_name
          when '__email' then concat_ws(' ', ps.work_email, ps.personal_email)
          when '__work_email' then ps.work_email
          when '__personal_email' then ps.personal_email
          when '__title' then ps.title
          when '__keywords' then array_to_string(ps.keywords, ' | ')
          when '__linkedin' then ps.linkedin_url
          when '__city' then ps.city
          when '__state' then ps.state
          when '__country' then ps.country
          when '__person_location' then concat_ws(', ', nullif(ps.city, ''), nullif(ps.state, ''), nullif(ps.country, ''))
          when '__company_location' then concat_ws(', ', nullif(ps.company_location, ''), nullif(ps.company_city, ''), nullif(ps.company_state, ''), nullif(ps.company_country, ''))
          when '__company_city' then ps.company_city
          when '__company_state' then ps.company_state
          when '__company_country' then ps.company_country
          when '__seniority' then ps.seniority
          when '__department' then ps.department
          when '__esp' then ps.esp
          when '__email_provider_type' then ps.email_provider_type
          when '__tags' then ps.tag_text
          when '__last_contacted' then ps.last_contacted_at::text
          when '__lists' then array_to_string(ps.list_names, ' | ')
          when '__clients' then array_to_string(ps.client_names, ' | ')
          else case when filter_item->>'field' like 'custom:%' then coalesce((
            select string_agg(entry.value, ' | ' order by entry.key)
            from jsonb_each_text(ps.all_data) entry(key, value)
            where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
          ), '') else '' end
        end, '') as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
            or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
              case when filter_item->>'field' = '__lists' then ps.list_names else ps.client_names end
            ))
        )
        when 'not_equals' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
        )
        when 'not_contains' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
        when 'boolean' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where to_tsvector('simple', candidate.candidate_value) @@ to_tsquery('simple', selected.value)
        )
        when 'number_ranges' then exists (
          select 1
          from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          cross join lateral (
            select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
              case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
          ) selected_range
          where filter_item->>'field' = '__employee_count'
            and (
              (selected.value = 'unknown' and ps.employee_count_min is null and ps.employee_count_max is null)
              or (selected.value <> 'unknown' and ps.employee_count_min is not null
                and (selected_range.maximum is null or ps.employee_count_min <= selected_range.maximum)
                and (ps.employee_count_max is null or ps.employee_count_max >= selected_range.minimum))
            )
        )
        when 'empty' then btrim(candidate.candidate_value) = ''
        when 'not_empty' then btrim(candidate.candidate_value) <> ''
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
      created_at desc,
      id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb),
    (select count(*) from filtered);
$$;

-- Fast filter-value suggestions: identical to v2 but scanning prospect_index.
create or replace function public.prospect_filter_values_v3(
  p_field text,
  p_search text default '',
  p_client_id text default null,
  p_limit integer default 50
)
returns table(value text, match_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with scoped as (
    select ps.*
    from public.prospect_index ps
    where p_client_id is null or ps.client_ids @> array[p_client_id]
  ), raw_values as (
    select ps.id as prospect_id, btrim(case p_field
      when '__name' then ps.full_name
      when '__first_name' then ps.first_name
      when '__last_name' then ps.last_name
      when '__company' then ps.company_name
      when '__email' then concat_ws(' ', ps.work_email, ps.personal_email)
      when '__work_email' then ps.work_email
      when '__personal_email' then ps.personal_email
      when '__title' then ps.title
      when '__linkedin' then ps.linkedin_url
      when '__city' then ps.city
      when '__state' then ps.state
      when '__country' then ps.country
      when '__person_location' then concat_ws(', ', nullif(ps.city, ''), nullif(ps.state, ''), nullif(ps.country, ''))
      when '__company_location' then concat_ws(', ', nullif(ps.company_location, ''), nullif(ps.company_city, ''), nullif(ps.company_state, ''), nullif(ps.company_country, ''))
      when '__company_city' then ps.company_city
      when '__company_state' then ps.company_state
      when '__company_country' then ps.company_country
      when '__seniority' then ps.seniority
      when '__department' then ps.department
      when '__esp' then ps.esp
      when '__email_provider_type' then ps.email_provider_type
      else case when p_field like 'custom:%' then coalesce((
        select string_agg(entry.value, ' | ' order by entry.key)
        from jsonb_each_text(ps.all_data) entry(key, value)
        where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(p_field from 8)
      ), '') else '' end
    end) as value
    from scoped ps
    where p_field not in ('__keywords', '__lists', '__clients', '__tags', '__last_contacted', '__employee_count')

    union all
    select ps.id, btrim(keyword) from scoped ps cross join lateral unnest(ps.keywords) keyword where p_field = '__keywords'
    union all
    select ps.id, btrim(list_name) from scoped ps cross join lateral unnest(ps.list_names) list_name where p_field = '__lists'
    union all
    select ps.id, btrim(client_name) from scoped ps cross join lateral unnest(ps.client_names) client_name where p_field = '__clients'
    union all
    select ps.id, btrim(pt.name) from scoped ps
      join public.prospect_tag_links ptl on ptl.prospect_id = ps.id
      join public.prospect_tags pt on pt.id = ptl.tag_id where p_field = '__tags'
    union all
    select ps.id, to_char(ps.last_contacted_at at time zone 'UTC', 'YYYY-MM-DD') from scoped ps
      where p_field = '__last_contacted' and ps.last_contacted_at is not null
  ), grouped as (
    select min(value) as value, count(distinct prospect_id) as match_count
    from raw_values
    where nullif(btrim(coalesce(value, '')), '') is not null
      and (btrim(coalesce(p_search, '')) = '' or value ilike '%' || btrim(p_search) || '%')
    group by lower(value)
  )
  select grouped.value, grouped.match_count
  from grouped
  order by grouped.match_count desc, lower(grouped.value)
  limit greatest(1, least(coalesce(p_limit, 50), 100));
$$;

-- Keyset export page: same filter/search semantics as v7, ordered by (created_at, id)
-- and sliced by a cursor so exports of any size traverse the index without deep OFFSET.
create or replace function public.search_prospect_export_v1(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null,
  p_after_created_at timestamptz default null,
  p_after_id text default null,
  p_limit integer default 5000,
  p_with_total boolean default false
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with filtered as (
    select ps.*
    from public.prospect_index ps
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
    and (
      btrim(coalesce(p_search, '')) = ''
      or ps.search_text ilike '%' || btrim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__first_name' then ps.first_name
          when '__last_name' then ps.last_name
          when '__company' then ps.company_name
          when '__email' then concat_ws(' ', ps.work_email, ps.personal_email)
          when '__work_email' then ps.work_email
          when '__personal_email' then ps.personal_email
          when '__title' then ps.title
          when '__keywords' then array_to_string(ps.keywords, ' | ')
          when '__linkedin' then ps.linkedin_url
          when '__city' then ps.city
          when '__state' then ps.state
          when '__country' then ps.country
          when '__person_location' then concat_ws(', ', nullif(ps.city, ''), nullif(ps.state, ''), nullif(ps.country, ''))
          when '__company_location' then concat_ws(', ', nullif(ps.company_location, ''), nullif(ps.company_city, ''), nullif(ps.company_state, ''), nullif(ps.company_country, ''))
          when '__company_city' then ps.company_city
          when '__company_state' then ps.company_state
          when '__company_country' then ps.company_country
          when '__seniority' then ps.seniority
          when '__department' then ps.department
          when '__esp' then ps.esp
          when '__email_provider_type' then ps.email_provider_type
          when '__tags' then ps.tag_text
          when '__last_contacted' then ps.last_contacted_at::text
          when '__lists' then array_to_string(ps.list_names, ' | ')
          when '__clients' then array_to_string(ps.client_names, ' | ')
          else case when filter_item->>'field' like 'custom:%' then coalesce((
            select string_agg(entry.value, ' | ' order by entry.key)
            from jsonb_each_text(ps.all_data) entry(key, value)
            where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
          ), '') else '' end
        end, '') as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
            or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
              case when filter_item->>'field' = '__lists' then ps.list_names else ps.client_names end
            ))
        )
        when 'not_equals' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
        )
        when 'not_contains' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
        when 'boolean' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where to_tsvector('simple', candidate.candidate_value) @@ to_tsquery('simple', selected.value)
        )
        when 'number_ranges' then exists (
          select 1
          from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          cross join lateral (
            select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
              case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
          ) selected_range
          where filter_item->>'field' = '__employee_count'
            and (
              (selected.value = 'unknown' and ps.employee_count_min is null and ps.employee_count_max is null)
              or (selected.value <> 'unknown' and ps.employee_count_min is not null
                and (selected_range.maximum is null or ps.employee_count_min <= selected_range.maximum)
                and (ps.employee_count_max is null or ps.employee_count_max >= selected_range.minimum))
            )
        )
        when 'empty' then btrim(candidate.candidate_value) = ''
        when 'not_empty' then btrim(candidate.candidate_value) <> ''
        else exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
      end
    )
  ), page as (
    select * from filtered
    where p_after_created_at is null
      or (filtered.created_at, filtered.id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by filtered.created_at desc, filtered.id desc
    limit greatest(1, least(coalesce(p_limit, 5000), 50000))
  )
  select coalesce((
    select jsonb_agg(ordered.row_json order by ordered.created_at_key desc, ordered.id_key desc)
    from (select to_jsonb(page) as row_json, page.created_at as created_at_key, page.id as id_key from page) ordered
  ), '[]'::jsonb),
  case when p_with_total then (select count(*) from filtered) else null end;
$$;

-- Import batch v5: v4 behavior plus incremental reindex of the prospects this import touched.
create or replace function public.import_prospect_batch_v5(
  p_import_id text,
  p_list_id text,
  p_rows jsonb
)
returns table(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  base_result record;
begin
  select * into base_result
  from public.import_prospect_batch_v4(p_import_id, p_list_id, p_rows);

  perform public.reindex_prospects(array(
    select distinct lr.prospect_id
    from public.list_rows lr
    where lr.import_id = p_import_id and lr.prospect_id is not null
  ));

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$$;

revoke execute on function public.reindex_prospects(text[]) from public, anon, authenticated;
revoke execute on function public.reindex_prospects_of_lists(text[]) from public, anon, authenticated;
revoke execute on function public.reindex_prospects_of_companies(text[]) from public, anon, authenticated;
revoke execute on function public.reindex_all() from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v7(text, jsonb, text, text, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.prospect_filter_values_v3(text, text, text, integer) from public, anon, authenticated;
revoke execute on function public.search_prospect_export_v1(text, jsonb, text, timestamptz, text, integer, boolean) from public, anon, authenticated;
revoke execute on function public.import_prospect_batch_v5(text, text, jsonb) from public, anon, authenticated;

grant execute on function public.reindex_prospects(text[]) to service_role;
grant execute on function public.reindex_prospects_of_lists(text[]) to service_role;
grant execute on function public.reindex_prospects_of_companies(text[]) to service_role;
grant execute on function public.reindex_all() to service_role;
grant execute on function public.search_prospect_workspace_v7(text, jsonb, text, text, integer, integer, text) to service_role;
grant execute on function public.prospect_filter_values_v3(text, text, text, integer) to service_role;
grant execute on function public.search_prospect_export_v1(text, jsonb, text, timestamptz, text, integer, boolean) to service_role;
grant execute on function public.import_prospect_batch_v5(text, text, jsonb) to service_role;

-- Backfill the index from existing data (safe to re-run).
select public.reindex_all();
