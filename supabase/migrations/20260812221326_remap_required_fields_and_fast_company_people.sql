-- Canonical import fields, existing company-data recovery, and a set-based
-- Company -> People pivot that does not rescan the company scope per person.

alter table public.companies add column if not exists industry text not null default '';
alter table public.companies add column if not exists keywords text[] not null default '{}';
alter table public.companies add column if not exists short_description text not null default '';
alter table public.companies add column if not exists founded_year integer;
alter table public.companies add column if not exists technologies text[] not null default '{}';
alter table public.companies add column if not exists total_funding text not null default '';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'companies_founded_year_valid') then
    alter table public.companies add constraint companies_founded_year_valid
      check (founded_year is null or founded_year between 1000 and 9999);
  end if;
end
$$;

create or replace function public.parse_employee_count_v1(p_value text)
returns table(minimum integer, maximum integer)
language sql
immutable
security invoker
set search_path = public
as $$
  with normalized as (
    select lower(replace(btrim(coalesce(p_value, '')), ',', '')) as value
  ), extracted as (
    select value, array_agg(least(2147483647::bigint, match[1]::bigint)::integer) as numbers
    from normalized
    left join lateral regexp_matches(value, '([0-9]+)', 'g') match on true
    group by value
  )
  select
    case when cardinality(numbers) > 0 then least(numbers[1], coalesce(numbers[2], numbers[1])) end,
    case
      when cardinality(numbers) = 0 then null
      when value like '%+%' or value ~ '(more|over|above)' then null
      else greatest(numbers[1], coalesce(numbers[2], numbers[1]))
    end
  from extracted;
$$;

-- Recover employee counts already preserved in raw prospect data. The most
-- common populated value per company wins, preventing one outlier from
-- replacing the value shared by the rest of that company's prospects.
with raw_counts as materialized (
  select p.company_id, entry.value
  from public.prospects p
  cross join lateral jsonb_each_text(coalesce(p.all_data, '{}'::jsonb)) entry(key, value)
  where p.company_id is not null
    and btrim(entry.value) <> ''
    and regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in (
      'employeecount', 'employeescount', 'employees', 'numberofemployees',
      'companyemployeecount', 'companyemployees', 'companyheadcount', 'headcount'
    )
), parsed_counts as (
  select raw.company_id, parsed.minimum, parsed.maximum
  from raw_counts raw
  cross join lateral public.parse_employee_count_v1(raw.value) parsed
  where parsed.minimum is not null
), ranked_counts as (
  select company_id, minimum, maximum,
    row_number() over (partition by company_id order by count(*) desc, minimum desc) as rank
  from parsed_counts
  group by company_id, minimum, maximum
)
update public.companies c set
  employee_count_min = coalesce(c.employee_count_min, ranked.minimum),
  employee_count_max = case when c.employee_count_min is null then ranked.maximum else c.employee_count_max end,
  updated_at = now()
from ranked_counts ranked
where ranked.rank = 1 and ranked.company_id = c.id
  and c.employee_count_min is null and c.employee_count_max is null;

-- Existing files contain person City/State/Country rather than explicit
-- company geography. Use the most common, most complete person location as a
-- company fallback only where canonical company location fields are empty.
with grouped_locations as materialized (
  select p.company_id,
    btrim(coalesce(p.city, '')) as city,
    btrim(coalesce(p.state, '')) as state,
    btrim(coalesce(p.country, '')) as country,
    btrim(coalesce(nullif(p.all_data->>'Person Location', ''), nullif(p.all_data->>'Location', ''),
      concat_ws(', ', nullif(btrim(p.city), ''), nullif(btrim(p.state), ''), nullif(btrim(p.country), '')))) as location,
    count(*) as votes
  from public.prospects p
  where p.company_id is not null
    and (btrim(coalesce(p.city, '')) <> '' or btrim(coalesce(p.state, '')) <> '' or btrim(coalesce(p.country, '')) <> ''
      or btrim(coalesce(p.all_data->>'Person Location', p.all_data->>'Location', '')) <> '')
  group by p.company_id, btrim(coalesce(p.city, '')), btrim(coalesce(p.state, '')), btrim(coalesce(p.country, '')),
    btrim(coalesce(nullif(p.all_data->>'Person Location', ''), nullif(p.all_data->>'Location', ''),
      concat_ws(', ', nullif(btrim(p.city), ''), nullif(btrim(p.state), ''), nullif(btrim(p.country), ''))))
), ranked_locations as (
  select grouped_locations.*,
    row_number() over (partition by company_id order by
      ((city <> '')::integer + (state <> '')::integer + (country <> '')::integer) desc,
      votes desc, lower(location)) as rank
  from grouped_locations
)
update public.companies c set
  location = case when btrim(c.location) = '' then ranked.location else c.location end,
  city = case when btrim(c.city) = '' then ranked.city else c.city end,
  state = case when btrim(c.state) = '' then ranked.state else c.state end,
  country = case when btrim(c.country) = '' then ranked.country else c.country end,
  updated_at = now()
from ranked_locations ranked
where ranked.rank = 1 and ranked.company_id = c.id
  and (btrim(c.location) = '' or btrim(c.city) = '' or btrim(c.state) = '' or btrim(c.country) = '');

-- Keep the flat read model synchronized without invoking the more expensive
-- full membership/tag reindex during the migration.
update public.prospect_index pi set
  employee_count_min = c.employee_count_min,
  employee_count_max = c.employee_count_max,
  company_location = c.location,
  company_city = c.city,
  company_state = c.state,
  company_country = c.country,
  search_text = concat_ws(' ', pi.search_text, c.location, c.city, c.state, c.country)
from public.companies c
where pi.company_id = c.id
  and (pi.employee_count_min is distinct from c.employee_count_min
    or pi.employee_count_max is distinct from c.employee_count_max
    or pi.company_location is distinct from c.location
    or pi.company_city is distinct from c.city
    or pi.company_state is distinct from c.state
    or pi.company_country is distinct from c.country);

create index if not exists idx_companies_name_trgm on public.companies using gin (name gin_trgm_ops);
create index if not exists idx_companies_domain_trgm on public.companies using gin (domain gin_trgm_ops);
create index if not exists idx_companies_location_trgm on public.companies using gin (location gin_trgm_ops);

create or replace function public.import_company_batch_v2(p_import_id text, p_rows jsonb)
returns table(processed integer, added integer, updated integer, skipped integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  row_data jsonb;
  source_name text;
  company_id_value text;
  company_name_value text;
  normalized_name_value text;
  domain_value text;
  normalized_domain_value text;
  source_row_value integer;
  was_new boolean;
  row_inserted integer;
  processed_count integer := 0;
  added_count_value integer := 0;
  updated_count_value integer := 0;
  skipped_count_value integer := 0;
begin
  select data_source into source_name from public.company_imports
  where id = p_import_id and status = 'processing' for update;
  if source_name is null then raise exception 'Company import not found or already completed' using errcode = 'P0002'; end if;

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    source_row_value := greatest(2, coalesce((row_data->>'sourceRowNumber')::integer, 2));
    insert into public.company_import_rows(import_id, source_row_number, raw_data)
    values (p_import_id, source_row_value, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (import_id, source_row_number) do nothing;
    get diagnostics row_inserted = row_count;
    if row_inserted = 0 then continue; end if;

    processed_count := processed_count + 1;
    company_name_value := btrim(coalesce(row_data->>'name', ''));
    normalized_name_value := btrim(coalesce(row_data->>'normalizedName', ''));
    domain_value := btrim(coalesce(row_data->>'domain', ''));
    normalized_domain_value := btrim(coalesce(row_data->>'normalizedDomain', ''));
    if normalized_name_value = '' or normalized_domain_value = '' then
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

    select c.id into company_id_value from public.companies c
    where c.normalized_domain = normalized_domain_value
       or (c.normalized_name = normalized_name_value and c.normalized_domain = '')
    order by case when c.normalized_domain = normalized_domain_value then 0 else 1 end, c.created_at limit 1;
    was_new := company_id_value is null;
    if was_new then company_id_value := 'domain:' || normalized_domain_value; end if;

    insert into public.companies(
      id, name, normalized_name, domain, normalized_domain, all_data,
      employee_count_min, employee_count_max, industry, city, state, country,
      location, keywords, short_description, founded_year, technologies, total_funding, updated_at
    ) values (
      company_id_value, company_name_value, normalized_name_value, domain_value, normalized_domain_value,
      coalesce(row_data->'raw', '{}'::jsonb), nullif(row_data->>'employeeCountMin', '')::integer,
      nullif(row_data->>'employeeCountMax', '')::integer, btrim(coalesce(row_data->>'industry', '')),
      btrim(coalesce(row_data->>'city', '')), btrim(coalesce(row_data->>'state', '')), btrim(coalesce(row_data->>'country', '')),
      concat_ws(', ', nullif(btrim(row_data->>'city'), ''), nullif(btrim(row_data->>'state'), ''), nullif(btrim(row_data->>'country'), '')),
      array(select jsonb_array_elements_text(coalesce(row_data->'keywords', '[]'::jsonb))),
      btrim(coalesce(row_data->>'shortDescription', '')), nullif(row_data->>'foundedYear', '')::integer,
      array(select jsonb_array_elements_text(coalesce(row_data->'technologies', '[]'::jsonb))),
      btrim(coalesce(row_data->>'totalFunding', '')), now()
    )
    on conflict (id) do update set
      name = excluded.name, normalized_name = excluded.normalized_name,
      domain = excluded.domain, normalized_domain = excluded.normalized_domain,
      all_data = public.companies.all_data || excluded.all_data,
      employee_count_min = coalesce(excluded.employee_count_min, public.companies.employee_count_min),
      employee_count_max = coalesce(excluded.employee_count_max, public.companies.employee_count_max),
      industry = coalesce(nullif(excluded.industry, ''), public.companies.industry),
      city = coalesce(nullif(excluded.city, ''), public.companies.city),
      state = coalesce(nullif(excluded.state, ''), public.companies.state),
      country = coalesce(nullif(excluded.country, ''), public.companies.country),
      location = coalesce(nullif(excluded.location, ''), public.companies.location),
      keywords = case when cardinality(excluded.keywords) > 0 then excluded.keywords else public.companies.keywords end,
      short_description = coalesce(nullif(excluded.short_description, ''), public.companies.short_description),
      founded_year = coalesce(excluded.founded_year, public.companies.founded_year),
      technologies = case when cardinality(excluded.technologies) > 0 then excluded.technologies else public.companies.technologies end,
      total_funding = coalesce(nullif(excluded.total_funding, ''), public.companies.total_funding),
      updated_at = now();

    insert into public.company_sources(company_id, data_source, last_import_id, last_seen_at)
    values (company_id_value, source_name, p_import_id, now())
    on conflict (company_id, data_source) do update set last_import_id = excluded.last_import_id, last_seen_at = now();
    update public.company_import_rows set company_id = company_id_value
    where import_id = p_import_id and source_row_number = source_row_value;
    if was_new then added_count_value := added_count_value + 1; else updated_count_value := updated_count_value + 1; end if;
  end loop;

  update public.company_imports set processed_rows = processed_rows + processed_count,
    added_count = added_count + added_count_value, updated_count = updated_count + updated_count_value,
    skipped_count = skipped_count + skipped_count_value where id = p_import_id;
  return query select processed_count, added_count_value, updated_count_value, skipped_count_value;
end;
$$;

create or replace function public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb)
returns table(company_id text)
language sql
stable
security invoker
set search_path = public
as $$
  select c.id
  from public.companies c
  where (btrim(coalesce(p_company_scope->>'search', '')) = ''
      or c.name ilike '%' || btrim(p_company_scope->>'search') || '%'
      or c.domain ilike '%' || btrim(p_company_scope->>'search') || '%')
    and (jsonb_array_length(coalesce(p_company_scope->'names', '[]'::jsonb)) = 0 or exists (
      select 1 from jsonb_array_elements_text(p_company_scope->'names') selected(value)
      where c.name ilike '%' || selected.value || '%'
    ))
    and (jsonb_array_length(coalesce(p_company_scope->'domains', '[]'::jsonb)) = 0 or c.normalized_domain in (
      select value from jsonb_array_elements_text(p_company_scope->'domains')
    ))
    and (jsonb_array_length(coalesce(p_company_scope->'locations', '[]'::jsonb)) = 0 or exists (
      select 1 from jsonb_array_elements_text(p_company_scope->'locations') selected(value)
      where concat_ws(', ', nullif(c.location, ''), nullif(c.city, ''), nullif(c.state, ''), nullif(c.country, '')) ilike '%' || selected.value || '%'
    ))
    and (jsonb_array_length(coalesce(p_company_scope->'seniority', '[]'::jsonb)) = 0 or exists (
      select 1 from public.prospect_index qualifier
      where qualifier.company_id = c.id
        and (p_client_id is null or qualifier.client_ids @> array[p_client_id])
        and lower(qualifier.seniority) in (
          select lower(value) from jsonb_array_elements_text(p_company_scope->'seniority')
        )
    ));
$$;

create or replace function public.search_prospect_workspace_v9(
  p_search text default '', p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at', p_direction text default 'desc',
  p_limit integer default 50, p_offset integer default 0,
  p_client_id text default null, p_company_scope jsonb default '{}'::jsonb
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
  with eligible_companies as materialized (
    select company_id from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
  ), filtered as materialized (
    select ps.* from public.prospect_index ps
    join eligible_companies eligible on eligible.company_id = ps.company_id
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
      and ((btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.prospect_index_matches_v1(ps, p_search, p_filters))
  ), sorted as (
    select * from filtered order by
      case when p_sort = 'name' and lower(p_direction) = 'asc' then lower(full_name) end asc,
      case when p_sort = 'name' and lower(p_direction) = 'desc' then lower(full_name) end desc,
      case when p_sort = 'company' and lower(p_direction) = 'asc' then lower(company_name) end asc,
      case when p_sort = 'company' and lower(p_direction) = 'desc' then lower(company_name) end desc,
      case when p_sort = 'title' and lower(p_direction) = 'asc' then lower(title) end asc,
      case when p_sort = 'title' and lower(p_direction) = 'desc' then lower(title) end desc,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'asc' then last_contacted_at end asc nulls first,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'desc' then last_contacted_at end desc nulls last,
      case when p_sort = 'created_at' and lower(p_direction) = 'asc' then created_at end asc,
      created_at desc, id
    limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb), (select count(*) from filtered);
$$;

create or replace function public.search_prospect_export_v3(
  p_search text default '', p_filters jsonb default '[]'::jsonb, p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb, p_after_created_at timestamptz default null,
  p_after_id text default null, p_limit integer default 5000, p_with_total boolean default false
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '60s'
as $$
  with eligible_companies as materialized (
    select company_id from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
  ), filtered as materialized (
    select ps.* from public.prospect_index ps
    join eligible_companies eligible on eligible.company_id = ps.company_id
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
      and ((btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.prospect_index_matches_v1(ps, p_search, p_filters))
  ), page as (
    select * from filtered
    where p_after_created_at is null or (filtered.created_at, filtered.id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by filtered.created_at desc, filtered.id desc
    limit greatest(1, least(coalesce(p_limit, 5000), 50000))
  )
  select coalesce((select jsonb_agg(to_jsonb(page) order by page.created_at desc, page.id desc) from page), '[]'::jsonb),
    case when p_with_total then (select count(*) from filtered) else null end;
$$;

revoke execute on function public.parse_employee_count_v1(text) from public, anon, authenticated;
revoke execute on function public.import_company_batch_v2(text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_scope_ids_v2(text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v9(text, jsonb, text, text, integer, integer, text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_export_v3(text, jsonb, text, jsonb, timestamptz, text, integer, boolean) from public, anon, authenticated;

grant execute on function public.parse_employee_count_v1(text) to service_role;
grant execute on function public.import_company_batch_v2(text, jsonb) to service_role;
grant execute on function public.company_scope_ids_v2(text, jsonb) to service_role;
grant execute on function public.search_prospect_workspace_v9(text, jsonb, text, text, integer, integer, text, jsonb) to service_role;
grant execute on function public.search_prospect_export_v3(text, jsonb, text, jsonb, timestamptz, text, integer, boolean) to service_role;
