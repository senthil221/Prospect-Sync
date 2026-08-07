alter table public.lists
  add column if not exists field_headers jsonb not null default '[]'::jsonb;

alter table public.imports
  add column if not exists field_headers jsonb not null default '[]'::jsonb;

create table if not exists public.prospect_fields (
  field_name text primary key,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create table if not exists public.list_rows (
  id bigint generated always as identity primary key,
  list_id text not null references public.lists(id) on delete cascade,
  prospect_id text references public.prospects(id) on delete set null,
  import_id text not null references public.imports(id) on delete cascade,
  source_row_number integer not null,
  raw_data jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now(),
  unique(import_id, source_row_number)
);

create index if not exists idx_list_rows_list_id on public.list_rows(list_id);
create index if not exists idx_list_rows_prospect_id on public.list_rows(prospect_id);

insert into public.prospect_fields(field_name)
select distinct fields.field_name
from public.prospects p
cross join lateral jsonb_object_keys(p.all_data) as fields(field_name)
where fields.field_name <> ''
on conflict (field_name) do update set last_seen_at = now();

update public.lists l
set field_headers = coalesce((
  select jsonb_agg(field_name order by field_name)
  from (
    select distinct fields.field_name
    from public.list_memberships lm
    cross join lateral jsonb_object_keys(lm.raw_data) as fields(field_name)
    where lm.list_id = l.id
  ) catalog
), '[]'::jsonb)
where l.field_headers = '[]'::jsonb;

update public.imports i
set field_headers = coalesce(l.field_headers, '[]'::jsonb)
from public.lists l
where l.id = i.list_id and i.field_headers = '[]'::jsonb;

insert into public.list_rows(list_id, prospect_id, import_id, source_row_number, raw_data, imported_at)
select lm.list_id, lm.prospect_id, lm.import_id,
  row_number() over (partition by lm.import_id order by lm.imported_at, lm.prospect_id)::integer + 1,
  lm.raw_data, lm.imported_at
from public.list_memberships lm
on conflict (import_id, source_row_number) do nothing;

create or replace function public.cleanup_orphaned_master_records(
  p_candidate_prospect_ids text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_prospects integer := 0;
  deleted_companies integer := 0;
  deleted_fields integer := 0;
begin
  delete from public.prospects p
  where (p_candidate_prospect_ids is null or p.id = any(p_candidate_prospect_ids))
    and not exists (
      select 1 from public.list_memberships lm where lm.prospect_id = p.id
    );
  get diagnostics deleted_prospects = row_count;

  delete from public.companies c
  where not exists (
    select 1 from public.prospects p where p.company_id = c.id
  );
  get diagnostics deleted_companies = row_count;

  delete from public.prospect_fields pf
  where not exists (
    select 1 from public.prospects p where p.all_data ? pf.field_name
  )
  and not exists (
    select 1 from public.lists l where l.field_headers ? pf.field_name
  );
  get diagnostics deleted_fields = row_count;

  return jsonb_build_object(
    'orphanedProspectsDeleted', deleted_prospects,
    'orphanedCompaniesDeleted', deleted_companies,
    'unusedFieldsDeleted', deleted_fields
  );
end;
$$;

create or replace view public.list_summaries as
select l.id, l.client_id, l.name, l.source_file_name, l.uploaded_rows,
  l.unique_added, l.duplicates_linked, l.created_at,
  count(lm.prospect_id)::integer as prospect_count,
  l.field_headers,
  jsonb_array_length(l.field_headers)::integer as field_count
from public.lists l
left join public.list_memberships lm on lm.list_id = l.id
group by l.id;

create or replace function public.import_prospect_batch_v2(
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
  row_data jsonb;
  identifier jsonb;
  prospect_id_value text;
  company_id_value text;
  source_row_number_value integer;
  new_count integer := 0;
  duplicate_count integer := 0;
  skipped_count integer := 0;
begin
  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    source_row_number_value := coalesce(nullif(row_data->>'sourceRowNumber', '')::integer, 0);
    if jsonb_array_length(coalesce(row_data->'identifiers', '[]'::jsonb)) = 0 then
      insert into public.list_rows(list_id, prospect_id, import_id, source_row_number, raw_data)
      values (p_list_id, null, p_import_id, source_row_number_value, coalesce(row_data->'raw', '{}'::jsonb))
      on conflict (import_id, source_row_number) do update set
        raw_data = excluded.raw_data,
        imported_at = now();
      skipped_count := skipped_count + 1;
      continue;
    end if;

    prospect_id_value := null;
    select pi.prospect_id into prospect_id_value
    from jsonb_array_elements(row_data->'identifiers') as item(value)
    join public.prospect_identifiers pi
      on pi.type = item.value->>'type' and pi.value = item.value->>'value'
    order by case pi.type when 'work_email' then 1 when 'personal_email' then 2 when 'linkedin' then 3 else 4 end
    limit 1;

    company_id_value := nullif(row_data->>'companyId', '');
    if company_id_value is not null then
      insert into public.companies (id, name, normalized_name, domain, normalized_domain, all_data)
      values (
        company_id_value,
        coalesce(row_data->>'companyName', ''),
        coalesce(row_data->>'normalizedCompanyName', ''),
        coalesce(row_data->>'companyDomain', ''),
        coalesce(row_data->>'companyDomain', ''),
        coalesce(row_data->'raw', '{}'::jsonb)
      )
      on conflict (id) do update set
        name = case when companies.name = '' then excluded.name else companies.name end,
        domain = case when companies.domain = '' then excluded.domain else companies.domain end,
        all_data = excluded.all_data || companies.all_data,
        updated_at = now();
    end if;

    if prospect_id_value is null then
      prospect_id_value := gen_random_uuid()::text;
      insert into public.prospects (
        id, first_name, last_name, full_name, work_email, personal_email, mobile_number,
        linkedin_url, title, seniority, department, city, state, country, company_id, all_data
      ) values (
        prospect_id_value, coalesce(row_data->>'firstName', ''), coalesce(row_data->>'lastName', ''),
        coalesce(row_data->>'fullName', ''), coalesce(row_data->>'workEmail', ''),
        coalesce(row_data->>'personalEmail', ''), coalesce(row_data->>'mobileNumber', ''),
        coalesce(row_data->>'linkedinUrl', ''), coalesce(row_data->>'title', ''),
        coalesce(row_data->>'seniority', ''), coalesce(row_data->>'department', ''),
        coalesce(row_data->>'city', ''), coalesce(row_data->>'state', ''),
        coalesce(row_data->>'country', ''), company_id_value, coalesce(row_data->'raw', '{}'::jsonb)
      );
      new_count := new_count + 1;
    else
      update public.prospects set
        first_name = case when first_name = '' then coalesce(row_data->>'firstName', '') else first_name end,
        last_name = case when last_name = '' then coalesce(row_data->>'lastName', '') else last_name end,
        full_name = case when full_name = '' then coalesce(row_data->>'fullName', '') else full_name end,
        work_email = case when work_email = '' then coalesce(row_data->>'workEmail', '') else work_email end,
        personal_email = case when personal_email = '' then coalesce(row_data->>'personalEmail', '') else personal_email end,
        mobile_number = case when mobile_number = '' then coalesce(row_data->>'mobileNumber', '') else mobile_number end,
        linkedin_url = case when linkedin_url = '' then coalesce(row_data->>'linkedinUrl', '') else linkedin_url end,
        title = case when title = '' then coalesce(row_data->>'title', '') else title end,
        seniority = case when seniority = '' then coalesce(row_data->>'seniority', '') else seniority end,
        department = case when department = '' then coalesce(row_data->>'department', '') else department end,
        city = case when city = '' then coalesce(row_data->>'city', '') else city end,
        state = case when state = '' then coalesce(row_data->>'state', '') else state end,
        country = case when country = '' then coalesce(row_data->>'country', '') else country end,
        company_id = coalesce(company_id, company_id_value),
        all_data = coalesce(row_data->'raw', '{}'::jsonb) || all_data,
        updated_at = now()
      where id = prospect_id_value;
      duplicate_count := duplicate_count + 1;
    end if;

    for identifier in select value from jsonb_array_elements(row_data->'identifiers')
    loop
      insert into public.prospect_identifiers(type, value, prospect_id)
      values (identifier->>'type', identifier->>'value', prospect_id_value)
      on conflict (type, value) do nothing;
    end loop;

    insert into public.prospect_fields(field_name)
    select fields.field_name
    from jsonb_object_keys(coalesce(row_data->'raw', '{}'::jsonb)) as fields(field_name)
    where fields.field_name <> ''
    on conflict (field_name) do update set last_seen_at = now();

    insert into public.list_memberships(list_id, prospect_id, import_id, raw_data)
    values (p_list_id, prospect_id_value, p_import_id, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (list_id, prospect_id) do update set
      import_id = excluded.import_id,
      raw_data = excluded.raw_data,
      imported_at = now();

    insert into public.list_rows(list_id, prospect_id, import_id, source_row_number, raw_data)
    values (p_list_id, prospect_id_value, p_import_id, source_row_number_value, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (import_id, source_row_number) do update set
      prospect_id = excluded.prospect_id,
      raw_data = excluded.raw_data,
      imported_at = now();
  end loop;

  processed := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  unique_added := new_count;
  duplicates_linked := duplicate_count;
  skipped := skipped_count;

  update public.imports set
    processed_rows = processed_rows + processed,
    unique_added = imports.unique_added + new_count,
    duplicates_linked = imports.duplicates_linked + duplicate_count
  where id = p_import_id;

  return next;
end;
$$;

create or replace function public.search_prospect_workspace(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with filtered as materialized (
    select ps.*
    from public.prospect_summaries ps
    where (
      trim(coalesce(p_search, '')) = ''
      or concat_ws(' ', ps.full_name, ps.work_email, ps.personal_email, ps.title,
        ps.company_name, ps.company_domain, ps.linkedin_url, ps.country, ps.all_data::text)
        ilike '%' || trim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select case filter_item->>'field'
          when '__name' then ps.full_name
          when '__company' then coalesce(ps.company_name, '')
          when '__email' then ps.work_email
          when '__title' then ps.title
          when '__linkedin' then ps.linkedin_url
          when '__country' then ps.country
          when '__seniority' then ps.seniority
          when '__department' then ps.department
          else coalesce(ps.all_data ->> (filter_item->>'field'), '')
        end as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then lower(candidate.candidate_value) = lower(coalesce(filter_item->>'value', ''))
        when 'empty' then trim(candidate.candidate_value) = ''
        when 'not_empty' then trim(candidate.candidate_value) <> ''
        else candidate.candidate_value ilike '%' || coalesce(filter_item->>'value', '') || '%'
      end
    )
  ),
  page_rows as (
    select * from filtered
    order by created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select
    coalesce((select jsonb_agg(to_jsonb(page_rows) order by page_rows.created_at desc) from page_rows), '[]'::jsonb),
    (select count(*) from filtered);
$$;

alter table public.prospect_fields enable row level security;
alter table public.list_rows enable row level security;

revoke all on public.prospect_fields, public.list_rows from anon, authenticated;
revoke all on public.list_summaries from anon, authenticated;
revoke execute on function public.import_prospect_batch_v2(text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace(text, jsonb, integer, integer) from public, anon, authenticated;

grant execute on function public.import_prospect_batch_v2(text, text, jsonb) to service_role;
grant execute on function public.search_prospect_workspace(text, jsonb, integer, integer) to service_role;
