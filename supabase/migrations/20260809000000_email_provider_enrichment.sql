alter table public.companies
  add column if not exists esp text not null default '',
  add column if not exists email_provider_type text not null default 'Unknown',
  add column if not exists mx_records text[] not null default '{}'::text[],
  add column if not exists mx_status text not null default 'pending',
  add column if not exists mx_checked_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'companies_email_provider_type_check'
      and conrelid = 'public.companies'::regclass
  ) then
    alter table public.companies add constraint companies_email_provider_type_check
      check (email_provider_type in ('SEG', 'Mailbox provider', 'Email relay', 'Unknown'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'companies_mx_status_check'
      and conrelid = 'public.companies'::regclass
  ) then
    alter table public.companies add constraint companies_mx_status_check
      check (mx_status in ('pending', 'resolved', 'no_mx', 'lookup_failed'));
  end if;
end;
$$;

create index if not exists idx_companies_pending_mx_scan
  on public.companies(id)
  where normalized_domain <> '' and mx_checked_at is null;

create or replace view public.prospect_summaries as
select p.*, co.name as company_name, co.domain as company_domain,
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
  co.mx_status,
  co.mx_checked_at
from public.prospects p
left join public.companies co on co.id = p.company_id
left join public.list_memberships lm on lm.prospect_id = p.id
left join public.lists l on l.id = lm.list_id
left join public.clients cl on cl.id = l.client_id
group by p.id, co.id;

create or replace function public.search_prospect_workspace_v5(
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
  with enriched as materialized (
    select ps.*,
      activity.last_contacted_at,
      coalesce(activity.contact_count, 0)::integer as contact_count,
      coalesce(tags.tag_names, '[]'::jsonb) as tags
    from public.prospect_summaries ps
    left join lateral (
      select max(ce.contacted_at) as last_contacted_at, count(*) as contact_count
      from public.contact_events ce
      where ce.prospect_id = ps.id and (p_client_id is null or ce.client_id = p_client_id)
    ) activity on true
    left join lateral (
      select jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'color', pt.color) order by pt.name) as tag_names
      from public.prospect_tag_links ptl
      join public.prospect_tags pt on pt.id = ptl.tag_id
      where ptl.prospect_id = ps.id
    ) tags on true
    where p_client_id is null or p_client_id = any(ps.client_ids)
  ), filtered as materialized (
    select ps.*
    from enriched ps
    where (
      trim(coalesce(p_search, '')) = ''
      or concat_ws(' ', ps.full_name, ps.work_email, ps.personal_email, ps.title,
        ps.company_name, ps.company_domain, ps.linkedin_url, ps.country, ps.all_data::text,
        ps.esp, ps.email_provider_type, array_to_string(ps.mx_records, ' '),
        ps.tags::text, array_to_string(ps.list_names, ' '), array_to_string(ps.client_names, ' '))
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
          when '__esp' then ps.esp
          when '__email_provider_type' then ps.email_provider_type
          when '__tags' then ps.tags::text
          when '__last_contacted' then ps.last_contacted_at::text
          when '__lists' then array_to_string(ps.list_names, ' | ')
          when '__clients' then array_to_string(ps.client_names, ' | ')
          else ps.all_data ->> (filter_item->>'field')
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
            or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
              case when filter_item->>'field' = '__lists' then ps.list_names else ps.client_names end
            ))
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
      created_at desc,
      id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb),
    (select count(*) from filtered);
$$;

create or replace function public.prospect_filter_values(
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
  with scoped as materialized (
    select ps.*
    from public.prospect_summaries ps
    where p_client_id is null or p_client_id = any(ps.client_ids)
  ), raw_values as materialized (
    select ps.id as prospect_id,
      btrim(case p_field
        when '__name' then ps.full_name
        when '__company' then ps.company_name
        when '__email' then coalesce(nullif(ps.work_email, ''), ps.personal_email)
        when '__title' then ps.title
        when '__linkedin' then ps.linkedin_url
        when '__country' then ps.country
        when '__seniority' then ps.seniority
        when '__department' then ps.department
        when '__esp' then ps.esp
        when '__email_provider_type' then ps.email_provider_type
        else ps.all_data ->> p_field
      end) as value
    from scoped ps
    where p_field not in ('__lists', '__clients', '__tags', '__last_contacted')

    union all

    select ps.id, btrim(list_name)
    from scoped ps
    cross join lateral unnest(ps.list_names) list_name
    where p_field = '__lists'

    union all

    select ps.id, btrim(client_name)
    from scoped ps
    cross join lateral unnest(ps.client_names) client_name
    where p_field = '__clients'

    union all

    select ps.id, btrim(pt.name)
    from scoped ps
    join public.prospect_tag_links ptl on ptl.prospect_id = ps.id
    join public.prospect_tags pt on pt.id = ptl.tag_id
    where p_field = '__tags'

    union all

    select ps.id, to_char(max(ce.contacted_at) at time zone 'UTC', 'YYYY-MM-DD')
    from scoped ps
    join public.contact_events ce on ce.prospect_id = ps.id
      and (p_client_id is null or ce.client_id = p_client_id)
    where p_field = '__last_contacted'
    group by ps.id
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

revoke execute on function public.search_prospect_workspace_v5(text, jsonb, text, text, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.prospect_filter_values(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v5(text, jsonb, text, text, integer, integer, text) to service_role;
grant execute on function public.prospect_filter_values(text, text, text, integer) to service_role;
