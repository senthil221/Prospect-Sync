-- Canonical company identity for the prospect import + a one-time merge of the
-- companies that earlier imports fragmented.
--
-- WHY
-- The People <-> Company pivots ("See People" / "See Companies") join through a
-- shared companies.id, which is correct and index-backed. The break was upstream:
-- the prospect import minted a company key DETERMINISTICALLY -- 'domain:<website>'
-- when a website was present, else 'name:<company>' -- with no lookup. So a
-- company imported as 'domain:acme.com' and a website-less prospect row for
-- "Acme" produced a second, unlinked 'name:acme' company. The pivot then missed
-- those people even though the name matched.
--
-- FIX (two parts)
-- 1. import_prospect_batch_v2 now RESOLVES the company the same way
--    import_company_batch_v2 does: match an existing company by normalized domain,
--    then by normalized name, and reuse that id; only mint a new key when nothing
--    matches. Company profile fields are never overwritten -- the prospect path
--    only fills blank name/domain -- so a company import stays the source of truth.
--    v3/v4/v5 wrap v2 by name and inherit this, so the deployed app needs no
--    redeploy for the DB side.
-- 2. A one-time backfill merges every website-less 'name:' company into the
--    domain-keyed company that shares its normalized name, re-pointing prospects,
--    company_sources and company_import_rows, filling any blank profile fields on
--    the survivor, then reindexing the affected prospects so prospect_index.
--    company_id / company_name follow.

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

    -- Canonical company resolution: reuse an existing company (domain first, then
    -- name) so a website-less prospect links to the company import's record instead
    -- of forking a new 'name:' row. companyDomain is already normalized (normalize.ts);
    -- normalizedCompanyName mirrors normalizeText.
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
        coalesce(row_data->'raw', '{}'::jsonb)
      )
      on conflict (id) do update set
        -- Fill blanks only; a company import stays authoritative for these.
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
        -- Company is a role field: a resolved company link wins when the row carries one.
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

-- One-time merge of the companies earlier imports fragmented. Winner per
-- normalized name = the earliest company that carries a domain; losers = the
-- website-less 'name:' rows sharing that normalized name. Children are re-pointed
-- before the losers are deleted, and blank profile fields on the winner are filled
-- from the loser so no captured company data is lost.
do $$
begin
  create temp table _company_merges on commit drop as
  with winners as (
    select distinct on (c.normalized_name) c.normalized_name, c.id as winner_id
    from public.companies c
    where coalesce(c.normalized_domain, '') <> '' and coalesce(c.normalized_name, '') <> ''
    order by c.normalized_name, c.created_at
  )
  select loser.id as loser_id, w.winner_id
  from public.companies loser
  join winners w on w.normalized_name = loser.normalized_name
  where coalesce(loser.normalized_domain, '') = ''
    and loser.id <> w.winner_id;

  if (select count(*) from _company_merges) = 0 then
    return;
  end if;

  -- Fill blank profile fields on the survivor from the loser (best effort).
  update public.companies w set
    employee_count_min = coalesce(w.employee_count_min, l.employee_count_min),
    employee_count_max = coalesce(w.employee_count_max, l.employee_count_max),
    industry = coalesce(nullif(w.industry, ''), l.industry),
    city = coalesce(nullif(w.city, ''), l.city),
    state = coalesce(nullif(w.state, ''), l.state),
    country = coalesce(nullif(w.country, ''), l.country),
    location = coalesce(nullif(w.location, ''), l.location),
    keywords = case when cardinality(coalesce(w.keywords, '{}')) > 0 then w.keywords else l.keywords end,
    short_description = coalesce(nullif(w.short_description, ''), l.short_description),
    founded_year = coalesce(w.founded_year, l.founded_year),
    technologies = case when cardinality(coalesce(w.technologies, '{}')) > 0 then w.technologies else l.technologies end,
    total_funding = coalesce(nullif(w.total_funding, ''), l.total_funding),
    all_data = l.all_data || w.all_data,
    updated_at = now()
  from _company_merges m
  join public.companies l on l.id = m.loser_id
  where w.id = m.winner_id;

  update public.prospects p set company_id = m.winner_id
  from _company_merges m where p.company_id = m.loser_id;

  insert into public.company_sources (company_id, data_source, last_import_id, last_seen_at)
  select m.winner_id, s.data_source, s.last_import_id, s.last_seen_at
  from public.company_sources s
  join _company_merges m on m.loser_id = s.company_id
  on conflict (company_id, data_source) do update set
    last_seen_at = greatest(public.company_sources.last_seen_at, excluded.last_seen_at);

  delete from public.company_sources s
  using _company_merges m where s.company_id = m.loser_id;

  update public.company_import_rows r set company_id = m.winner_id
  from _company_merges m where r.company_id = m.loser_id;

  delete from public.companies c
  using _company_merges m where c.id = m.loser_id;

  perform public.reindex_prospects_of_companies(array(select distinct winner_id from _company_merges));
end $$;
