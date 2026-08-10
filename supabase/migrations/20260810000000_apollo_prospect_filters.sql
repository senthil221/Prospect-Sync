alter table public.prospects
  add column if not exists keywords text[] not null default '{}'::text[];

alter table public.companies
  add column if not exists employee_count_min integer,
  add column if not exists employee_count_max integer,
  add column if not exists location text not null default '',
  add column if not exists city text not null default '',
  add column if not exists state text not null default '',
  add column if not exists country text not null default '';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'companies_employee_count_range_check'
      and conrelid = 'public.companies'::regclass
  ) then
    alter table public.companies add constraint companies_employee_count_range_check
      check (
        (employee_count_min is null or employee_count_min >= 0)
        and (employee_count_max is null or employee_count_max >= 0)
        and (employee_count_min is null or employee_count_max is null or employee_count_max >= employee_count_min)
      );
  end if;
end;
$$;

create index if not exists idx_prospects_keywords on public.prospects using gin(keywords);
create index if not exists idx_companies_employee_count on public.companies(employee_count_min, employee_count_max);
create index if not exists idx_companies_location on public.companies(lower(country), lower(state), lower(city));

-- Preserve raw imported headers, but backfill canonical fields from common aliases.
with keyword_source as (
  select p.id, array_agg(distinct btrim(keyword)) filter (where btrim(keyword) <> '') as keywords
  from public.prospects p
  cross join lateral jsonb_each_text(p.all_data) entry(key, value)
  cross join lateral regexp_split_to_table(entry.value, '[,;|]') keyword
  where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in
    ('keyword', 'keywords', 'personkeywords', 'prospectkeywords')
  group by p.id
)
update public.prospects p set keywords = source.keywords
from keyword_source source
where source.id = p.id and cardinality(p.keywords) = 0 and cardinality(source.keywords) > 0;

with location_source as (
  select c.id,
    max(entry.value) filter (where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in ('companylocation', 'accountlocation', 'headquarters', 'hqlocation')) as location,
    max(entry.value) filter (where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in ('companycity', 'accountcity', 'hqcity')) as city,
    max(entry.value) filter (where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in ('companystate', 'accountstate', 'hqstate', 'companyregion')) as state,
    max(entry.value) filter (where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in ('companycountry', 'accountcountry', 'hqcountry')) as country
  from public.companies c
  cross join lateral jsonb_each_text(c.all_data) entry(key, value)
  group by c.id
)
update public.companies c set
  location = case when c.location = '' then coalesce(source.location, '') else c.location end,
  city = case when c.city = '' then coalesce(source.city, '') else c.city end,
  state = case when c.state = '' then coalesce(source.state, '') else c.state end,
  country = case when c.country = '' then coalesce(source.country, '') else c.country end
from location_source source
where source.id = c.id and (
  (c.location = '' and coalesce(source.location, '') <> '')
   or (c.city = '' and coalesce(source.city, '') <> '')
   or (c.state = '' and coalesce(source.state, '') <> '')
   or (c.country = '' and coalesce(source.country, '') <> '')
);

with employee_raw as (
  select distinct on (c.id) c.id, replace(lower(btrim(entry.value)), ',', '') as value
  from public.companies c
  cross join lateral jsonb_each_text(c.all_data) entry(key, value)
  where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in
    ('employees', 'employeecount', 'numberofemployees', 'companyemployeecount', 'companyemployees', 'companyheadcount', 'headcount')
  order by c.id, entry.key
), employee_numbers as (
  select id, value, regexp_match(value, '([0-9]+)[^0-9]+([0-9]+)') as range_numbers,
    regexp_match(value, '([0-9]+)') as single_number
  from employee_raw
), employee_source as (
  select id, coalesce(range_numbers[1], single_number[1])::integer as minimum,
    case when value like '%+%' or value ~ '(more|over|above)' then null
      else coalesce(range_numbers[2], single_number[1])::integer end as maximum
  from employee_numbers
  where coalesce(range_numbers[1], single_number[1]) is not null
)
update public.companies c set employee_count_min = source.minimum, employee_count_max = source.maximum
from employee_source source
where source.id = c.id and c.employee_count_min is null;

create or replace view public.prospect_summaries as
select
  p.id,
  p.first_name,
  p.last_name,
  p.full_name,
  p.work_email,
  p.personal_email,
  p.mobile_number,
  p.linkedin_url,
  p.title,
  p.seniority,
  p.department,
  p.city,
  p.state,
  p.country,
  p.company_id,
  p.all_data,
  p.created_at,
  p.updated_at,
  co.name as company_name,
  co.domain as company_domain,
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
  co.mx_checked_at,
  p.keywords,
  co.employee_count_min,
  co.employee_count_max,
  co.location as company_location,
  co.city as company_city,
  co.state as company_state,
  co.country as company_country
from public.prospects p
left join public.companies co on co.id = p.company_id
left join public.list_memberships lm on lm.prospect_id = p.id
left join public.lists l on l.id = lm.list_id
left join public.clients cl on cl.id = l.client_id
group by p.id, co.id;

create or replace function public.import_prospect_batch_v4(
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
  row_data jsonb;
  prospect_id_value text;
begin
  select * into base_result
  from public.import_prospect_batch_v3(p_import_id, p_list_id, p_rows);

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    select lr.prospect_id into prospect_id_value
    from public.list_rows lr
    where lr.import_id = p_import_id
      and lr.source_row_number = coalesce(nullif(row_data->>'sourceRowNumber', '')::integer, 0);

    if prospect_id_value is null then continue; end if;

    update public.prospects set
      keywords = (
        select coalesce(array_agg(minimum_value order by lower_value), '{}'::text[])
        from (
          select lower(value) as lower_value, min(value) as minimum_value
          from unnest(prospects.keywords || array(
            select jsonb_array_elements_text(coalesce(row_data->'keywords', '[]'::jsonb))
          )) value
          where btrim(value) <> ''
          group by lower(value)
        ) unique_keywords
      ),
      updated_at = now()
    where id = prospect_id_value;

    update public.companies set
      employee_count_min = coalesce(companies.employee_count_min, nullif(row_data->>'companyEmployeeCountMin', '')::integer),
      employee_count_max = case
        when companies.employee_count_min is not null then companies.employee_count_max
        else nullif(row_data->>'companyEmployeeCountMax', '')::integer
      end,
      location = case when companies.location = '' then coalesce(row_data->>'companyLocation', '') else companies.location end,
      city = case when companies.city = '' then coalesce(row_data->>'companyCity', '') else companies.city end,
      state = case when companies.state = '' then coalesce(row_data->>'companyState', '') else companies.state end,
      country = case when companies.country = '' then coalesce(row_data->>'companyCountry', '') else companies.country end,
      updated_at = now()
    where id = (select company_id from public.prospects where id = prospect_id_value);
  end loop;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$$;

create or replace function public.search_prospect_workspace_v6(
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
      btrim(coalesce(p_search, '')) = ''
      or concat_ws(' ', ps.full_name, ps.work_email, ps.personal_email, ps.title,
        array_to_string(ps.keywords, ' '), ps.company_name, ps.company_domain, ps.linkedin_url,
        ps.city, ps.state, ps.country, ps.company_location, ps.company_city, ps.company_state,
        ps.company_country, ps.all_data::text, ps.esp, ps.email_provider_type,
        array_to_string(ps.mx_records, ' '), ps.tags::text,
        array_to_string(ps.list_names, ' '), array_to_string(ps.client_names, ' '))
        ilike '%' || btrim(p_search) || '%'
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
          when '__tags' then ps.tags::text
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

create or replace function public.prospect_filter_values_v2(
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
    select ps.id, to_char(max(ce.contacted_at) at time zone 'UTC', 'YYYY-MM-DD') from scoped ps
      join public.contact_events ce on ce.prospect_id = ps.id and (p_client_id is null or ce.client_id = p_client_id)
      where p_field = '__last_contacted' group by ps.id
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

revoke execute on function public.import_prospect_batch_v4(text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v6(text, jsonb, text, text, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.prospect_filter_values_v2(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.import_prospect_batch_v4(text, text, jsonb) to service_role;
grant execute on function public.search_prospect_workspace_v6(text, jsonb, text, text, integer, integer, text) to service_role;
grant execute on function public.prospect_filter_values_v2(text, text, text, integer) to service_role;
