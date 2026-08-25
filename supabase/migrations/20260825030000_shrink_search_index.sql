-- A1: the same imported row was stored five times, plus a sixth textual copy
-- inside search_text, which the trigram GIN index then covered.
--
--   prospects.all_data          canonical raw row
--   list_memberships.raw_data   identical payload, keyed by (list, prospect)
--   list_rows.raw_data          identical payload, keyed by (import, row number)
--   prospect_index.all_data     copy for custom: filters and export
--   companies.all_data          the PERSON's row, written onto the company
--   prospect_index.search_text  all of the above again, as text, GIN-indexed
--
-- For a 50-column export at ~1.5 KB/row, a million prospects cost roughly 9 GB
-- against 1.5 GB of information. With shared_buffers=2GB that is the difference
-- between a working set that fits in cache and one that does not — and no query
-- plan fixes a cache miss.
--
-- This migration removes two of the copies. It deliberately keeps
-- prospect_index.all_data (custom: filters and exports read it directly, and
-- re-joining prospects would undo the point of having a flat index).

-- ---------------------------------------------------------------------------
-- 1. search_text stops swallowing the whole raw row
-- ---------------------------------------------------------------------------
-- Free-text search now covers the canonical fields a person actually searches
-- by. Uploaded columns remain fully searchable through their own custom:
-- filters, which read all_data directly and are unaffected.

create or replace function public.prospect_search_text(p_row public.prospect_index)
returns text
language sql
immutable
security invoker
as $$
  select concat_ws(' ',
    (p_row).full_name, (p_row).work_email, (p_row).personal_email, (p_row).mobile_number,
    (p_row).title, (p_row).seniority, (p_row).department,
    array_to_string((p_row).keywords, ' '),
    (p_row).company_name, (p_row).company_domain, (p_row).linkedin_url,
    (p_row).location, (p_row).city, (p_row).state, (p_row).country,
    (p_row).company_location, (p_row).company_city, (p_row).company_state, (p_row).company_country,
    (p_row).esp, (p_row).email_provider_type,
    array_to_string((p_row).list_names, ' '), array_to_string((p_row).client_names, ' '),
    (p_row).tag_text
  );
$$;

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
      linkedin_url, title, seniority, department, city, state, country, location, company_id,
      company_name, company_domain, all_data, created_at, updated_at, list_count, client_count,
      list_names, client_names, list_ids, client_ids, list_memberships, esp, email_provider_type,
      mx_records, mx_status, mx_checked_at, keywords, employee_count_min, employee_count_max,
      company_location, company_city, company_state, company_country, tags, tag_text,
      last_contacted_at, contact_count, search_text
    )
    select
      c.id, c.first_name, c.last_name, c.full_name, c.work_email, c.personal_email, c.mobile_number,
      c.linkedin_url, c.title, c.seniority, c.department, c.city, c.state, c.country, c.location, c.company_id,
      c.company_name, c.company_domain, c.all_data, c.created_at, c.updated_at, c.list_count, c.client_count,
      c.list_names, c.client_names, c.list_ids, c.client_ids, c.list_memberships, c.esp, c.email_provider_type,
      c.mx_records, c.mx_status, c.mx_checked_at, c.keywords, c.employee_count_min, c.employee_count_max,
      c.company_location, c.company_city, c.company_state, c.company_country, c.tags, c.tag_text,
      c.last_contacted_at, c.contact_count,
      -- Canonical fields only. all_data::text used to be appended here, which is
      -- what made the trigram index cover every uploaded column in the database.
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
      search_text = excluded.search_text
    returning 1
  )
  select count(*)::integer into affected from upserted;

  return affected;
end;
$$;

revoke execute on function public.reindex_prospects(text[]) from public, anon, authenticated;
revoke execute on function public.prospect_search_text(public.prospect_index) from public, anon, authenticated;
grant execute on function public.reindex_prospects(text[]) to service_role;
grant execute on function public.prospect_search_text(public.prospect_index) to service_role;

-- Rewrite existing search_text in place. Done in one statement rather than via
-- reindex_prospects so it does not re-derive 40 other columns it does not need
-- to touch, and so the statement-level count trigger fires once.
update public.prospect_index set search_text = concat_ws(' ',
  full_name, work_email, personal_email, mobile_number,
  title, seniority, department, array_to_string(keywords, ' '),
  company_name, company_domain, linkedin_url,
  location, city, state, country,
  company_location, company_city, company_state, company_country,
  esp, email_provider_type,
  array_to_string(list_names, ' '), array_to_string(client_names, ' '), tag_text
);

-- ---------------------------------------------------------------------------
-- 2. Company records stop carrying the person's row
-- ---------------------------------------------------------------------------
-- companies.all_data was receiving the whole person row, so company records
-- carried somebody's job title, seniority and email address. Keep only the keys
-- that describe the company. Defined here because the import path below uses it.

create or replace function public.company_scoped_raw(p_raw jsonb)
returns jsonb
language sql
immutable
security invoker
as $$
  select coalesce(jsonb_object_agg(entry.key, entry.value), '{}'::jsonb)
  from jsonb_each_text(coalesce(p_raw, '{}'::jsonb)) entry(key, value)
  where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') like 'company%'
     or regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in (
       'industry', 'website', 'domain', 'employees', 'employeecount', 'numberofemployees',
       'headcount', 'shortdescription', 'description', 'foundedyear', 'founded',
       'technologies', 'techstack', 'totalfunding', 'funding', 'annualrevenue', 'revenue'
     );
$$;

revoke execute on function public.company_scoped_raw(jsonb) from public, anon, authenticated;
grant execute on function public.company_scoped_raw(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Drop the duplicate raw payload on list_memberships
-- ---------------------------------------------------------------------------
-- list_rows already stores the identical payload keyed by (import_id,
-- source_row_number), and the List workspace reads it from there. The column on
-- list_memberships was a second copy of the same bytes for every membership.

create or replace view public.list_membership_rows as
  select lm.list_id, lm.prospect_id, lm.import_id, lm.imported_at,
    coalesce(lr.raw_data, '{}'::jsonb) as raw_data
  from public.list_memberships lm
  left join public.list_rows lr
    on lr.import_id = lm.import_id and lr.prospect_id = lm.prospect_id;

revoke all on public.list_membership_rows from anon, authenticated;

-- Both writers of the column have to stop referencing it before it can go.
-- import_prospect_batch_v2 wrote the payload it had already written to
-- list_rows one statement earlier; merge_prospects carried it across.

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
    location = coalesce(nullif(keep_record.location, ''), source_record.location),
    company_id = coalesce(keep_record.company_id, source_record.company_id),
    all_data = source_record.all_data || keep_record.all_data,
    updated_at = now()
  from public.prospects as source_record
  where keep_record.id = p_keep_id and source_record.id = p_merge_id;

  insert into public.list_memberships(list_id, prospect_id, import_id, imported_at)
  select list_id, p_keep_id, import_id, imported_at from public.list_memberships where prospect_id = p_merge_id
  on conflict (list_id, prospect_id) do nothing;
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

revoke execute on function public.merge_prospects(text, text) from public, anon, authenticated;
grant execute on function public.merge_prospects(text, text) to service_role;

-- import_prospect_batch_v2: same body as 20260825010000 with the redundant
-- list_memberships.raw_data write removed and companies.all_data scoped.
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
  normalized_name_value text;
  normalized_domain_value text;
  source_row_number_value integer;
  location_value text;
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

    location_value := coalesce(nullif(btrim(coalesce(row_data->>'location', '')), ''), nullif(concat_ws(', ',
      nullif(btrim(coalesce(row_data->>'city', '')), ''),
      nullif(btrim(coalesce(row_data->>'state', '')), ''),
      nullif(btrim(coalesce(row_data->>'country', '')), '')
    ), ''), '');

    prospect_id_value := null;
    select pi.prospect_id into prospect_id_value
    from jsonb_array_elements(row_data->'identifiers') as item(value)
    join public.prospect_identifiers pi
      on pi.type = item.value->>'type' and pi.value = item.value->>'value'
    order by case pi.type
      when 'work_email' then 1 when 'personal_email' then 2 when 'linkedin' then 3
      when 'name_company' then 4 else 5 end
    limit 1;

    normalized_domain_value := btrim(coalesce(row_data->>'companyDomain', ''));
    normalized_name_value := btrim(coalesce(row_data->>'normalizedCompanyName', ''));
    company_id_value := null;
    if normalized_domain_value <> '' or normalized_name_value <> '' then
      select c.id into company_id_value
      from public.companies c
      where (normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value)
         or (normalized_name_value <> '' and c.normalized_name = normalized_name_value
           and (normalized_domain_value = '' or coalesce(c.normalized_domain, '') = ''))
      order by case when normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value then 0 else 1 end, c.created_at
      limit 1;
      if company_id_value is null then
        company_id_value := case when normalized_domain_value <> ''
          then 'domain:' || normalized_domain_value
          else 'name:' || normalized_name_value end;
      end if;

      insert into public.companies (id, name, normalized_name, domain, normalized_domain, all_data)
      values (
        company_id_value,
        coalesce(row_data->>'companyName', ''),
        normalized_name_value,
        coalesce(row_data->>'companyDomain', ''),
        normalized_domain_value,
        -- Company-scoped keys only: this used to store the whole person row.
        public.company_scoped_raw(row_data->'raw')
      )
      on conflict (id) do update set
        name = coalesce(nullif(public.companies.name, ''), excluded.name),
        normalized_name = coalesce(nullif(public.companies.normalized_name, ''), excluded.normalized_name),
        domain = coalesce(nullif(public.companies.domain, ''), excluded.domain),
        normalized_domain = coalesce(nullif(public.companies.normalized_domain, ''), excluded.normalized_domain),
        all_data = excluded.all_data || public.companies.all_data,
        updated_at = now();
    end if;

    if prospect_id_value is null then
      prospect_id_value := gen_random_uuid()::text;
      insert into public.prospects (
        id, first_name, last_name, full_name, work_email, personal_email, mobile_number,
        linkedin_url, title, seniority, department, city, state, country, location,
        company_id, all_data
      ) values (
        prospect_id_value, coalesce(row_data->>'firstName', ''), coalesce(row_data->>'lastName', ''),
        coalesce(row_data->>'fullName', ''), coalesce(row_data->>'workEmail', ''),
        coalesce(row_data->>'personalEmail', ''), coalesce(row_data->>'mobileNumber', ''),
        coalesce(row_data->>'linkedinUrl', ''), coalesce(row_data->>'title', ''),
        coalesce(row_data->>'seniority', ''), coalesce(row_data->>'department', ''),
        coalesce(row_data->>'city', ''), coalesce(row_data->>'state', ''),
        coalesce(row_data->>'country', ''), location_value,
        company_id_value, coalesce(row_data->'raw', '{}'::jsonb)
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
        title = case when coalesce(row_data->>'title', '') <> '' then row_data->>'title' else title end,
        seniority = case when coalesce(row_data->>'seniority', '') <> '' then row_data->>'seniority' else seniority end,
        department = case when coalesce(row_data->>'department', '') <> '' then row_data->>'department' else department end,
        city = case when city = '' then coalesce(row_data->>'city', '') else city end,
        state = case when state = '' then coalesce(row_data->>'state', '') else state end,
        country = case when country = '' then coalesce(row_data->>'country', '') else country end,
        location = case when location = '' then location_value else location end,
        company_id = coalesce(company_id_value, company_id),
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

    -- The raw payload lives on list_rows (below) only; this link is now just a link.
    insert into public.list_memberships(list_id, prospect_id, import_id)
    values (p_list_id, prospect_id_value, p_import_id)
    on conflict (list_id, prospect_id) do update set
      import_id = excluded.import_id,
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

revoke execute on function public.import_prospect_batch_v2(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.import_prospect_batch_v2(text, text, jsonb) to service_role;

alter table public.list_memberships drop column if exists raw_data;

-- ---------------------------------------------------------------------------
-- 4. Backfill: strip the person-level keys previous imports left on companies
-- ---------------------------------------------------------------------------
update public.companies c
set all_data = public.company_scoped_raw(c.all_data)
where c.all_data <> '{}'::jsonb
  and c.all_data <> public.company_scoped_raw(c.all_data);

analyze public.prospect_index;
analyze public.list_memberships;
analyze public.companies;

-- ---------------------------------------------------------------------------
-- 5. Smoke test
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_row record;
  v_scoped jsonb;
  v_count bigint;
begin
  -- Company scoping keeps company keys and drops person keys.
  v_scoped := public.company_scoped_raw(
    '{"Company Name":"Acme","Industry":"SaaS","Title":"VP Sales","Email":"a@b.com","Founded Year":"2011"}'::jsonb);
  if not (v_scoped ? 'Company Name') or not (v_scoped ? 'Industry') or not (v_scoped ? 'Founded Year') then
    raise exception 'company_scoped_raw dropped a company key: %', v_scoped;
  end if;
  if (v_scoped ? 'Title') or (v_scoped ? 'Email') then
    raise exception 'company_scoped_raw kept a person key: %', v_scoped;
  end if;

  -- The raw payload must still be reachable now that the duplicate column is gone.
  select count(*) into v_count from public.list_membership_rows;

  -- Search, custom-field filtering, and the write paths must all still work.
  select * into v_row from public.search_prospect_workspace_v12(p_search => 'a', p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"custom:industry","operator":"contains","values":["software"]}]'::jsonb, p_with_total => false);
  select * into v_row from public.reindex_scope_v1(p_prospect_ids => array(select id from public.prospects limit 3));

  -- import_prospect_batch_v2 no longer writes list_memberships.raw_data. Prove
  -- it against a throwaway import rather than trusting the text of the function.
  insert into public.clients (id, name, normalized_name)
    values ('__smoke_client__', 'Smoke Test', '__smoke_test_client__')
    on conflict (id) do nothing;
  insert into public.lists (id, client_id, name, data_source)
    values ('__smoke_list__', '__smoke_client__', 'Smoke', 'Legacy Import')
    on conflict (id) do nothing;
  insert into public.imports (id, client_id, list_id, file_name, data_source)
    values ('__smoke_import__', '__smoke_client__', '__smoke_list__', 'smoke.csv', 'Legacy Import')
    on conflict (id) do nothing;

  perform public.import_prospect_batch_v2('__smoke_import__', '__smoke_list__', jsonb_build_array(jsonb_build_object(
    'sourceRowNumber', 2,
    'fullName', 'Smoke Test Person',
    'workEmail', '__prospect_sync_smoke__@example.invalid',
    'companyName', 'Smoke Test Co',
    'companyDomain', 'smoke-test.invalid',
    'normalizedCompanyName', 'smoke test co',
    'city', 'Chennai', 'country', 'India',
    'identifiers', jsonb_build_array(jsonb_build_object('type', 'work_email', 'value', '__prospect_sync_smoke__@example.invalid')),
    'raw', jsonb_build_object('Full Name', 'Smoke Test Person', 'Title', 'VP Smoke', 'Industry', 'Testing')
  )));

  if not exists (select 1 from public.prospects where work_email = '__prospect_sync_smoke__@example.invalid' and location = 'Chennai, India') then
    raise exception 'import did not persist the composed location';
  end if;
  if exists (select 1 from public.companies where id = 'domain:smoke-test.invalid' and all_data ? 'Title') then
    raise exception 'company all_data still receives person-level keys';
  end if;

  -- Clean up: cascades remove the prospect, memberships, rows and identifiers.
  delete from public.prospects where work_email = '__prospect_sync_smoke__@example.invalid';
  delete from public.companies where id = 'domain:smoke-test.invalid';
  delete from public.clients where id = '__smoke_client__';
end;
$smoke$;
