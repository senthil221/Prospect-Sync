create table if not exists public.clients (
  id text primary key,
  name text not null,
  normalized_name text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.companies (
  id text primary key,
  name text not null default '',
  normalized_name text not null default '',
  domain text not null default '',
  normalized_domain text not null default '',
  all_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lists (
  id text primary key,
  client_id text not null references public.clients(id) on delete cascade,
  name text not null,
  source_file_name text not null default '',
  uploaded_rows integer not null default 0,
  unique_added integer not null default 0,
  duplicates_linked integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.prospects (
  id text primary key,
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
  company_id text references public.companies(id) on delete set null,
  all_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.prospect_identifiers (
  type text not null,
  value text not null,
  prospect_id text not null references public.prospects(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (type, value)
);

create table if not exists public.imports (
  id text primary key,
  client_id text not null references public.clients(id) on delete cascade,
  list_id text not null references public.lists(id) on delete cascade,
  file_name text not null,
  status text not null default 'processing',
  total_rows integer not null default 0,
  processed_rows integer not null default 0,
  unique_added integer not null default 0,
  duplicates_linked integer not null default 0,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.list_memberships (
  list_id text not null references public.lists(id) on delete cascade,
  prospect_id text not null references public.prospects(id) on delete cascade,
  import_id text not null references public.imports(id) on delete cascade,
  raw_data jsonb not null default '{}'::jsonb,
  imported_at timestamptz not null default now(),
  primary key (list_id, prospect_id)
);

create index if not exists idx_lists_client_id on public.lists(client_id);
create index if not exists idx_companies_normalized_domain on public.companies(normalized_domain);
create index if not exists idx_companies_normalized_name on public.companies(normalized_name);
create index if not exists idx_prospects_company_id on public.prospects(company_id);
create index if not exists idx_prospects_full_name on public.prospects(full_name);
create index if not exists idx_identifiers_prospect_id on public.prospect_identifiers(prospect_id);
create index if not exists idx_memberships_prospect_id on public.list_memberships(prospect_id);
create index if not exists idx_imports_created_at on public.imports(created_at desc);

create or replace view public.client_summaries as
select c.id, c.name, c.created_at,
  count(distinct l.id)::integer as list_count,
  count(distinct lm.prospect_id)::integer as prospect_count
from public.clients c
left join public.lists l on l.client_id = c.id
left join public.list_memberships lm on lm.list_id = l.id
group by c.id;

create or replace view public.list_summaries as
select l.id, l.client_id, l.name, l.source_file_name, l.uploaded_rows,
  l.unique_added, l.duplicates_linked, l.created_at,
  count(lm.prospect_id)::integer as prospect_count
from public.lists l
left join public.list_memberships lm on lm.list_id = l.id
group by l.id;

create or replace view public.prospect_summaries as
select p.*, c.name as company_name, c.domain as company_domain,
  count(distinct lm.list_id)::integer as list_count,
  count(distinct l.client_id)::integer as client_count
from public.prospects p
left join public.companies c on c.id = p.company_id
left join public.list_memberships lm on lm.prospect_id = p.id
left join public.lists l on l.id = lm.list_id
group by p.id, c.id;

create or replace view public.company_summaries as
select c.id, c.name, c.domain, c.created_at,
  count(distinct p.id)::integer as prospect_count,
  count(distinct l.client_id)::integer as client_count
from public.companies c
left join public.prospects p on p.company_id = c.id
left join public.list_memberships lm on lm.prospect_id = p.id
left join public.lists l on l.id = lm.list_id
group by c.id;

create or replace function public.import_prospect_batch(
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
  new_count integer := 0;
  duplicate_count integer := 0;
  skipped_count integer := 0;
begin
  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    if jsonb_array_length(coalesce(row_data->'identifiers', '[]'::jsonb)) = 0 then
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

    insert into public.list_memberships(list_id, prospect_id, import_id, raw_data)
    values (p_list_id, prospect_id_value, p_import_id, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (list_id, prospect_id) do update set
      import_id = excluded.import_id,
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

alter table public.clients enable row level security;
alter table public.companies enable row level security;
alter table public.lists enable row level security;
alter table public.prospects enable row level security;
alter table public.prospect_identifiers enable row level security;
alter table public.imports enable row level security;
alter table public.list_memberships enable row level security;

revoke all on public.clients, public.companies, public.lists, public.prospects,
  public.prospect_identifiers, public.imports, public.list_memberships
  from anon, authenticated;
revoke all on public.client_summaries, public.list_summaries, public.prospect_summaries,
  public.company_summaries from anon, authenticated;
revoke execute on function public.import_prospect_batch(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.import_prospect_batch(text, text, jsonb) to service_role;
