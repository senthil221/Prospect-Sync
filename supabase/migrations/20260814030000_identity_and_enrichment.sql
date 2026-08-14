-- Identity + enrichment tuning.
--
-- 1. Matching gains a Name + Company Name fallback: normalize.ts now emits a
--    `name_company_name` identifier, so rows with no email/LinkedIn/domain are no
--    longer skipped and dedupe against anyone sharing the same name + company.
--    Email/LinkedIn still win (see the identifier ordering below), so this only
--    ever links rows that share no stronger signal.
--
-- 2. Re-import now keeps role fields current ("newer wins"): Title, Seniority,
--    Departments, and the Company link are overwritten when the incoming row has a
--    value (so a promotion/company move is reflected). Identity fields (name,
--    email, LinkedIn) and location stay fill-blanks so a thinner list can never
--    erase a stronger record. All other imported columns are still preserved in
--    the prospect's raw all_data.
--
-- Only import_prospect_batch_v2 changes; v3/v4/v5 wrap it by name and inherit this
-- automatically, so the deployed app needs no redeploy for the DB side.

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
    -- Strongest signal wins: work email > personal email > LinkedIn > name+company.
    select pi.prospect_id into prospect_id_value
    from jsonb_array_elements(row_data->'identifiers') as item(value)
    join public.prospect_identifiers pi
      on pi.type = item.value->>'type' and pi.value = item.value->>'value'
    order by case pi.type
      when 'work_email' then 1 when 'personal_email' then 2 when 'linkedin' then 3
      when 'name_company' then 4 else 5 end
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
        -- Identity fields: fill blanks only, never overwrite a stronger record.
        first_name = case when first_name = '' then coalesce(row_data->>'firstName', '') else first_name end,
        last_name = case when last_name = '' then coalesce(row_data->>'lastName', '') else last_name end,
        full_name = case when full_name = '' then coalesce(row_data->>'fullName', '') else full_name end,
        work_email = case when work_email = '' then coalesce(row_data->>'workEmail', '') else work_email end,
        personal_email = case when personal_email = '' then coalesce(row_data->>'personalEmail', '') else personal_email end,
        mobile_number = case when mobile_number = '' then coalesce(row_data->>'mobileNumber', '') else mobile_number end,
        linkedin_url = case when linkedin_url = '' then coalesce(row_data->>'linkedinUrl', '') else linkedin_url end,
        -- Role fields: newer wins so promotions / moves are reflected.
        title = case when coalesce(row_data->>'title', '') <> '' then row_data->>'title' else title end,
        seniority = case when coalesce(row_data->>'seniority', '') <> '' then row_data->>'seniority' else seniority end,
        department = case when coalesce(row_data->>'department', '') <> '' then row_data->>'department' else department end,
        -- Location: fill blanks only.
        city = case when city = '' then coalesce(row_data->>'city', '') else city end,
        state = case when state = '' then coalesce(row_data->>'state', '') else state end,
        country = case when country = '' then coalesce(row_data->>'country', '') else country end,
        -- Company is a role field: a new company link wins when the row carries one.
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

-- Backfill the new fallback identity for existing prospects so a future
-- name+company-only row can match (and enrich) someone already imported by email.
-- Value format mirrors normalize.ts: lower/whitespace-collapsed "full name|company name".
-- One prospect wins per (name|company); homonyms collapse to the earliest record,
-- which is the accepted trade-off of a name-based key.
insert into public.prospect_identifiers (type, value, prospect_id)
select 'name_company_name', candidates.val, candidates.prospect_id
from (
  select distinct on (val) val, source.id as prospect_id
  from (
    select p.id, p.created_at,
      lower(btrim(regexp_replace(p.full_name, '\s+', ' ', 'g'))) || '|' ||
      lower(btrim(regexp_replace(c.name, '\s+', ' ', 'g'))) as val
    from public.prospects p
    join public.companies c on c.id = p.company_id
    where btrim(coalesce(p.full_name, '')) <> '' and btrim(coalesce(c.name, '')) <> ''
  ) source
  order by val, source.created_at
) candidates
on conflict (type, value) do nothing;
