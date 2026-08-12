-- Request 2: explicit import lineage, company-only imports, client-only prospect
-- removal, richer company filters, and filter-preserving company/people pivots.

alter table public.lists add column if not exists data_source text;
alter table public.imports add column if not exists data_source text;

update public.lists set data_source = 'Legacy Import' where nullif(btrim(data_source), '') is null;
update public.imports set data_source = 'Legacy Import' where nullif(btrim(data_source), '') is null;

alter table public.lists alter column data_source set default 'Legacy Import';
alter table public.lists alter column data_source set not null;
alter table public.imports alter column data_source set default 'Legacy Import';
alter table public.imports alter column data_source set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'lists_data_source_required') then
    alter table public.lists add constraint lists_data_source_required check (btrim(data_source) <> '');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'imports_data_source_required') then
    alter table public.imports add constraint imports_data_source_required check (btrim(data_source) <> '');
  end if;
end
$$;

create or replace view public.list_summaries as
select l.id, l.client_id, l.name, l.source_file_name, l.uploaded_rows,
  l.unique_added, l.duplicates_linked, l.created_at,
  count(lm.prospect_id)::integer as prospect_count,
  l.field_headers,
  jsonb_array_length(l.field_headers)::integer as field_count,
  l.data_source
from public.lists l
left join public.list_memberships lm on lm.list_id = l.id
group by l.id;

create table if not exists public.company_imports (
  id text primary key,
  file_name text not null default '',
  data_source text not null check (btrim(data_source) <> ''),
  status text not null default 'processing' check (status in ('processing', 'completed', 'failed')),
  total_rows integer not null default 0,
  processed_rows integer not null default 0,
  added_count integer not null default 0,
  updated_count integer not null default 0,
  skipped_count integer not null default 0,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.company_import_rows (
  import_id text not null references public.company_imports(id) on delete cascade,
  source_row_number integer not null,
  company_id text references public.companies(id) on delete set null,
  raw_data jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now(),
  primary key (import_id, source_row_number)
);

create table if not exists public.company_sources (
  company_id text not null references public.companies(id) on delete cascade,
  data_source text not null check (btrim(data_source) <> ''),
  last_import_id text references public.company_imports(id) on delete set null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (company_id, data_source)
);

create index if not exists idx_company_imports_created_at on public.company_imports(created_at desc);
create index if not exists idx_company_import_rows_company_id on public.company_import_rows(company_id);
create index if not exists idx_company_sources_data_source on public.company_sources(data_source, company_id);

alter table public.company_imports enable row level security;
alter table public.company_import_rows enable row level security;
alter table public.company_sources enable row level security;
revoke all on public.company_imports from anon, authenticated;
revoke all on public.company_import_rows from anon, authenticated;
revoke all on public.company_sources from anon, authenticated;

create or replace function public.import_company_batch_v1(
  p_import_id text,
  p_rows jsonb
)
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
  select data_source into source_name
  from public.company_imports
  where id = p_import_id and status = 'processing'
  for update;
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
    if normalized_name_value = '' and normalized_domain_value = '' then
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

    company_id_value := null;
    select c.id into company_id_value
    from public.companies c
    where (normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value)
       or (normalized_name_value <> '' and c.normalized_name = normalized_name_value
         and (normalized_domain_value = '' or c.normalized_domain = ''))
    order by case when normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value then 0 else 1 end, c.created_at
    limit 1;
    was_new := company_id_value is null;
    if was_new then
      company_id_value := case when normalized_domain_value <> '' then 'domain:' || normalized_domain_value else 'name:' || normalized_name_value end;
    end if;

    insert into public.companies(id, name, normalized_name, domain, normalized_domain, all_data, updated_at)
    values (company_id_value, company_name_value, normalized_name_value, domain_value, normalized_domain_value, coalesce(row_data->'raw', '{}'::jsonb), now())
    on conflict (id) do update set
      name = case when excluded.name <> '' then excluded.name else public.companies.name end,
      normalized_name = case when excluded.normalized_name <> '' then excluded.normalized_name else public.companies.normalized_name end,
      domain = case when excluded.domain <> '' then excluded.domain else public.companies.domain end,
      normalized_domain = case when excluded.normalized_domain <> '' then excluded.normalized_domain else public.companies.normalized_domain end,
      all_data = public.companies.all_data || excluded.all_data,
      updated_at = now();

    insert into public.company_sources(company_id, data_source, last_import_id, last_seen_at)
    values (company_id_value, source_name, p_import_id, now())
    on conflict (company_id, data_source) do update set last_import_id = excluded.last_import_id, last_seen_at = now();
    update public.company_import_rows set company_id = company_id_value
    where import_id = p_import_id and source_row_number = source_row_value;
    if was_new then added_count_value := added_count_value + 1; else updated_count_value := updated_count_value + 1; end if;
  end loop;

  update public.company_imports set
    processed_rows = processed_rows + processed_count,
    added_count = added_count + added_count_value,
    updated_count = updated_count + updated_count_value,
    skipped_count = skipped_count + skipped_count_value
  where id = p_import_id;
  return query select processed_count, added_count_value, updated_count_value, skipped_count_value;
end;
$$;

create or replace function public.remove_prospect_from_client_v1(p_client_id text, p_prospect_id text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare removed_count integer;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.prospects where id = p_prospect_id) then
    raise exception 'Prospect not found' using errcode = 'P0002';
  end if;
  delete from public.list_memberships lm
  using public.lists l
  where lm.list_id = l.id and l.client_id = p_client_id and lm.prospect_id = p_prospect_id;
  get diagnostics removed_count = row_count;
  return removed_count;
end;
$$;

-- One reusable predicate keeps People DB filters identical when companies are
-- derived from a filtered people result set.
create or replace function public.prospect_index_matches_v1(
  p_row public.prospect_index,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb
)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select (
    btrim(coalesce(p_search, '')) = ''
    or (p_row).search_text ilike '%' || btrim(p_search) || '%'
  ) and not exists (
    select 1
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
    cross join lateral (
      select coalesce(case filter_item->>'field'
        when '__name' then (p_row).full_name
        when '__first_name' then (p_row).first_name
        when '__last_name' then (p_row).last_name
        when '__company' then (p_row).company_name
        when '__company_domain' then (p_row).company_domain
        when '__email' then concat_ws(' ', (p_row).work_email, (p_row).personal_email)
        when '__work_email' then (p_row).work_email
        when '__personal_email' then (p_row).personal_email
        when '__title' then (p_row).title
        when '__keywords' then array_to_string((p_row).keywords, ' | ')
        when '__linkedin' then (p_row).linkedin_url
        when '__city' then (p_row).city
        when '__state' then (p_row).state
        when '__country' then (p_row).country
        when '__person_location' then concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, ''))
        when '__company_location' then concat_ws(', ', nullif((p_row).company_location, ''), nullif((p_row).company_city, ''), nullif((p_row).company_state, ''), nullif((p_row).company_country, ''))
        when '__company_city' then (p_row).company_city
        when '__company_state' then (p_row).company_state
        when '__company_country' then (p_row).company_country
        when '__seniority' then (p_row).seniority
        when '__department' then (p_row).department
        when '__esp' then (p_row).esp
        when '__email_provider_type' then (p_row).email_provider_type
        when '__tags' then (p_row).tag_text
        when '__last_contacted' then (p_row).last_contacted_at::text
        when '__lists' then array_to_string((p_row).list_names, ' | ')
        when '__clients' then array_to_string((p_row).client_names, ' | ')
        else case when filter_item->>'field' like 'custom:%' then coalesce((
          select string_agg(entry.value, ' | ' order by entry.key)
          from jsonb_each_text((p_row).all_data) entry(key, value)
          where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
        ), '') else '' end
      end, '') as candidate_value
    ) candidate
    where not case coalesce(filter_item->>'operator', 'contains')
      when 'equals' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
          or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
            case when filter_item->>'field' = '__lists' then (p_row).list_names else (p_row).client_names end
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
          and ((selected.value = 'unknown' and (p_row).employee_count_min is null and (p_row).employee_count_max is null)
            or (selected.value <> 'unknown' and (p_row).employee_count_min is not null
              and (selected_range.maximum is null or (p_row).employee_count_min <= selected_range.maximum)
              and ((p_row).employee_count_max is null or (p_row).employee_count_max >= selected_range.minimum)))
      )
      when 'empty' then btrim(candidate.candidate_value) = ''
      when 'not_empty' then btrim(candidate.candidate_value) <> ''
      else exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
    end
  );
$$;

create or replace function public.company_matches_scope_v1(
  p_company_id text,
  p_client_id text,
  p_company_scope jsonb
)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(p_company_scope, '{}'::jsonb) = '{}'::jsonb or exists (
    select 1 from public.companies c
    where c.id = p_company_id
      and (btrim(coalesce(p_company_scope->>'search', '')) = '' or c.name ilike '%' || btrim(p_company_scope->>'search') || '%' or c.domain ilike '%' || btrim(p_company_scope->>'search') || '%')
      and (jsonb_array_length(coalesce(p_company_scope->'names', '[]'::jsonb)) = 0 or exists (
        select 1 from jsonb_array_elements_text(p_company_scope->'names') selected(value) where c.name ilike '%' || selected.value || '%'
      ))
      and (jsonb_array_length(coalesce(p_company_scope->'domains', '[]'::jsonb)) = 0 or exists (
        select 1 from jsonb_array_elements_text(p_company_scope->'domains') selected(value) where c.normalized_domain = selected.value
      ))
      and ((jsonb_array_length(coalesce(p_company_scope->'seniority', '[]'::jsonb)) = 0 and jsonb_array_length(coalesce(p_company_scope->'locations', '[]'::jsonb)) = 0) or exists (
        select 1 from public.prospect_index qualifier
        where qualifier.company_id = c.id
          and (p_client_id is null or qualifier.client_ids @> array[p_client_id])
          and (jsonb_array_length(coalesce(p_company_scope->'seniority', '[]'::jsonb)) = 0 or exists (
            select 1 from jsonb_array_elements_text(p_company_scope->'seniority') selected(value) where lower(qualifier.seniority) = lower(selected.value)
          ))
          and (jsonb_array_length(coalesce(p_company_scope->'locations', '[]'::jsonb)) = 0 or exists (
            select 1 from jsonb_array_elements_text(p_company_scope->'locations') selected(value)
            where concat_ws(', ', nullif(qualifier.city, ''), nullif(qualifier.state, ''), nullif(qualifier.country, '')) ilike '%' || selected.value || '%'
          ))
      ))
  );
$$;

create or replace function public.search_prospect_workspace_v8(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb
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
      and public.prospect_index_matches_v1(ps, p_search, p_filters)
      and public.company_matches_scope_v1(ps.company_id, p_client_id, p_company_scope)
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
      created_at desc, id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb), (select count(*) from filtered);
$$;

create or replace function public.search_prospect_export_v2(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb,
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
    select ps.* from public.prospect_index ps
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
      and public.prospect_index_matches_v1(ps, p_search, p_filters)
      and public.company_matches_scope_v1(ps.company_id, p_client_id, p_company_scope)
  ), page as (
    select * from filtered
    where p_after_created_at is null or (filtered.created_at, filtered.id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by filtered.created_at desc, filtered.id desc
    limit greatest(1, least(coalesce(p_limit, 5000), 50000))
  )
  select coalesce((
    select jsonb_agg(ordered.row_json order by ordered.created_at_key desc, ordered.id_key desc)
    from (select to_jsonb(page) as row_json, page.created_at as created_at_key, page.id as id_key from page) ordered
  ), '[]'::jsonb),
  case when p_with_total then (select count(*) from filtered) else null end;
$$;

create or replace function public.filter_companies_v3(
  p_search text default '',
  p_names text[] default '{}',
  p_domains text[] default '{}',
  p_seniority text[] default '{}',
  p_locations text[] default '{}',
  p_client_id text default null,
  p_people_scope jsonb default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select c.id, c.name, c.domain, c.created_at
    from public.companies c
    where (coalesce(p_search, '') = '' or c.name ilike '%' || p_search || '%' or c.domain ilike '%' || p_search || '%')
      and (coalesce(cardinality(p_names), 0) = 0 or exists (select 1 from unnest(p_names) selected where c.name ilike '%' || selected || '%'))
      and (coalesce(cardinality(p_domains), 0) = 0 or c.normalized_domain = any(p_domains))
      and ((coalesce(cardinality(p_seniority), 0) = 0 and coalesce(cardinality(p_locations), 0) = 0) or exists (
        select 1 from public.prospect_index qualifier
        where qualifier.company_id = c.id
          and (p_client_id is null or qualifier.client_ids @> array[p_client_id])
          and (coalesce(cardinality(p_seniority), 0) = 0 or qualifier.seniority = any(p_seniority))
          and (coalesce(cardinality(p_locations), 0) = 0 or exists (
            select 1 from unnest(p_locations) loc where concat_ws(', ', nullif(qualifier.city, ''), nullif(qualifier.state, ''), nullif(qualifier.country, '')) ilike '%' || loc || '%'
          ))
      ))
      and (p_client_id is null or exists (select 1 from public.prospect_index scoped where scoped.company_id = c.id and scoped.client_ids @> array[p_client_id]))
      and (p_people_scope is null or exists (
        select 1 from public.prospect_index scoped
        where scoped.company_id = c.id
          and (p_client_id is null or scoped.client_ids @> array[p_client_id])
          and public.prospect_index_matches_v1(scoped, coalesce(p_people_scope->>'search', ''), coalesce(p_people_scope->'filters', '[]'::jsonb))
      ))
  ), agg as (
    select b.id, b.name, b.domain, b.created_at,
      coalesce(counts.prospect_count, 0) as prospect_count,
      coalesce(counts.client_count, 0) as client_count
    from base b
    left join lateral (
      select count(distinct pi.id)::integer as prospect_count, count(distinct client_id)::integer as client_count
      from public.prospect_index pi
      left join lateral unnest(pi.client_ids) client_id on true
      where pi.company_id = b.id and (p_client_id is null or pi.client_ids @> array[p_client_id])
    ) counts on true
  ), counted as (
    select count(*)::integer as total_count,
      count(*) filter (where prospect_count > 0)::integer as covered_count,
      coalesce(sum(prospect_count), 0)::integer as prospect_total
    from agg
  ), page as (
    select id, name, domain, created_at, prospect_count, client_count
    from agg order by prospect_count desc, lower(name), id
    offset greatest(coalesce(p_offset, 0), 0)
    limit greatest(1, least(coalesce(p_limit, 50), 5000))
  )
  select coalesce((select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id) from page), '[]'::jsonb),
    counted.total_count, counted.covered_count, counted.prospect_total
  from counted;
$$;

create or replace function public.dashboard_workspace()
returns table(result jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'stats', jsonb_build_object(
      'prospects', (select count(*) from public.prospects),
      'companies', (select count(*) from public.companies),
      'clients', (select count(*) from public.clients),
      'lists', (select count(*) from public.lists),
      'rowsImported', (select coalesce(sum(processed_rows), 0) from public.imports),
      'duplicatesDetected', (select coalesce(sum(duplicates_linked), 0) from public.imports)
    ),
    'recentImports', coalesce((
      select jsonb_agg(to_jsonb(recent) order by recent.created_at desc)
      from (
        select i.id, i.file_name, i.data_source, i.status, i.processed_rows, i.unique_added,
          i.duplicates_linked, i.created_at, c.name as client_name, l.name as list_name
        from public.imports i
        left join public.clients c on c.id = i.client_id
        left join public.lists l on l.id = i.list_id
        order by i.created_at desc limit 6
      ) recent
    ), '[]'::jsonb)
  );
$$;

revoke execute on function public.import_company_batch_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.remove_prospect_from_client_v1(text, text) from public, anon, authenticated;
revoke execute on function public.prospect_index_matches_v1(public.prospect_index, text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_matches_scope_v1(text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v8(text, jsonb, text, text, integer, integer, text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_export_v2(text, jsonb, text, jsonb, timestamptz, text, integer, boolean) from public, anon, authenticated;
revoke execute on function public.filter_companies_v3(text, text[], text[], text[], text[], text, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.dashboard_workspace() from public, anon, authenticated;

grant execute on function public.import_company_batch_v1(text, jsonb) to service_role;
grant execute on function public.remove_prospect_from_client_v1(text, text) to service_role;
grant execute on function public.prospect_index_matches_v1(public.prospect_index, text, jsonb) to service_role;
grant execute on function public.company_matches_scope_v1(text, text, jsonb) to service_role;
grant execute on function public.search_prospect_workspace_v8(text, jsonb, text, text, integer, integer, text, jsonb) to service_role;
grant execute on function public.search_prospect_export_v2(text, jsonb, text, jsonb, timestamptz, text, integer, boolean) to service_role;
grant execute on function public.filter_companies_v3(text, text[], text[], text[], text[], text, jsonb, integer, integer) to service_role;
grant execute on function public.dashboard_workspace() to service_role;
