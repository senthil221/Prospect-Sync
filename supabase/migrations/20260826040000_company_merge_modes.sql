-- Three duplicate-handling modes for company uploads.
--
-- Matching is unchanged and already does the right thing: normalized website wins,
-- and a name match only counts when at least one side has no website (so two
-- different "Acme" companies with different domains never collapse into one).
--
-- What changes is what happens AFTER a match. Until now there was exactly one
-- behaviour, hardcoded into import_company_batch_v2: fill blanks only. The upload
-- now picks one of three:
--
--   enrich    (default) Fill only the fields the stored company is missing.
--             Existing values are never changed. This is the old behaviour.
--   overwrite The uploaded file is authoritative: every field it supplies a value
--             for replaces what is stored. Fields the file does NOT supply are
--             left alone -- a CSV without a "Founded Year" column must not blank
--             out the founded years already collected. So "overwrite" means
--             "new value wins where a new value exists", not "replace the row".
--   skip      Leave the matched company completely untouched and count it as
--             skipped. Only genuinely new companies are written.
--
-- all_data (the raw uploaded JSON), keywords and technologies now follow the same
-- rule as the typed columns in every mode. This fixes an inconsistency in v2,
-- where the typed columns kept the OLD value on a collision but all_data was
-- merged as `stored || incoming` and keywords/technologies took the incoming array
-- whenever it was non-empty -- so parts of the same row treated the upload as
-- authoritative while the rest treated the store as authoritative.
--
-- Enrich keeps a stored keyword/technology array rather than unioning it with the
-- uploaded one. Union would accumulate more, but it also makes the arrays grow
-- without bound across uploads and there is no way to remove a bad entry, so the
-- predictable rule wins until there is a reason to change it.
--
-- In all three modes a new company is inserted normally; the mode only governs
-- collisions. company_sources is still stamped in skip mode: knowing a source
-- listed this company is provenance, not company data.
--
-- This supersedes 20260825103139_fix_company_location_import_drift.sql: that
-- migration is already applied, and this function is a newer definition of the
-- same two RPCs, so its Company Location handling is carried forward below rather
-- than being silently rolled back.

begin;

alter table public.company_imports
  add column if not exists merge_mode text not null default 'enrich';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'company_imports_merge_mode_check'
  ) then
    alter table public.company_imports
      add constraint company_imports_merge_mode_check
      check (merge_mode in ('enrich', 'overwrite', 'skip'));
  end if;
end $$;

create or replace function public.import_company_batch_v3(
  p_import_id text,
  p_rows jsonb,
  p_row_offset integer
)
returns table(processed integer, added integer, updated integer, skipped integer)
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  row_data jsonb;
  source_name text;
  merge_mode_value text;
  committed_offset integer;
  batch_size integer := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  company_id_value text;
  company_name_value text;
  normalized_name_value text;
  domain_value text;
  normalized_domain_value text;
  location_value text;
  source_row_value integer;
  was_new boolean;
  row_inserted integer;
  processed_count integer := 0;
  added_count_value integer := 0;
  updated_count_value integer := 0;
  skipped_count_value integer := 0;
begin
  if p_row_offset is null or p_row_offset < 0 then
    raise exception 'A non-negative row offset is required' using errcode = '22023';
  end if;

  select ci.data_source, ci.committed_row_offset, ci.merge_mode
  into source_name, committed_offset, merge_mode_value
  from public.company_imports ci
  where ci.id = p_import_id and ci.status = 'processing'
  for update;

  if not found then
    raise exception 'Company import not found or already completed' using errcode = 'P0002';
  end if;

  merge_mode_value := coalesce(nullif(merge_mode_value, ''), 'enrich');

  -- Already-committed chunk replayed after a resume: acknowledge, do not re-apply.
  if p_row_offset + batch_size <= committed_offset then
    return query select batch_size, 0, 0, 0;
    return;
  end if;

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
    -- A row is importable with a name OR a website; skip only when it has neither.
    if normalized_name_value = '' and normalized_domain_value = '' then
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

    -- Geography arrives either as one Location column or as city/state/country,
    -- so prefer what the file actually carried and compose only as a fallback.
    -- Carried over from 20260825103139_fix_company_location_import_drift.sql,
    -- which this function supersedes: without it a file whose only geography is a
    -- single "Company Location" column silently imports a blank location.
    location_value := coalesce(
      nullif(btrim(coalesce(row_data->>'location', '')), ''),
      nullif(concat_ws(', ',
        nullif(btrim(coalesce(row_data->>'city', '')), ''),
        nullif(btrim(coalesce(row_data->>'state', '')), ''),
        nullif(btrim(coalesce(row_data->>'country', '')), '')), ''),
      '');

    company_id_value := null;
    select c.id into company_id_value from public.companies c
    where (normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value)
       or (normalized_name_value <> '' and c.normalized_name = normalized_name_value
         and (normalized_domain_value = '' or c.normalized_domain = ''))
    order by case when normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value then 0 else 1 end, c.created_at
    limit 1;
    was_new := company_id_value is null;

    if not was_new and merge_mode_value = 'skip' then
      -- Record that this source saw the company, then leave the company alone.
      insert into public.company_sources(company_id, data_source, last_import_id, last_seen_at)
      values (company_id_value, source_name, p_import_id, now())
      on conflict (company_id, data_source) do update set last_import_id = excluded.last_import_id, last_seen_at = now();
      update public.company_import_rows set company_id = company_id_value
      where import_id = p_import_id and source_row_number = source_row_value;
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

    if was_new then
      company_id_value := case when normalized_domain_value <> '' then 'domain:' || normalized_domain_value else 'name:' || normalized_name_value end;
    end if;

    insert into public.companies(
      id, name, normalized_name, domain, normalized_domain, all_data,
      employee_count_min, employee_count_max, industry, city, state, country,
      location, keywords, short_description, founded_year, technologies, total_funding, updated_at
    ) values (
      company_id_value, company_name_value, normalized_name_value, domain_value, normalized_domain_value,
      coalesce(row_data->'raw', '{}'::jsonb), nullif(row_data->>'employeeCountMin', '')::integer,
      nullif(row_data->>'employeeCountMax', '')::integer, btrim(coalesce(row_data->>'industry', '')),
      btrim(coalesce(row_data->>'city', '')), btrim(coalesce(row_data->>'state', '')), btrim(coalesce(row_data->>'country', '')),
      location_value,
      array(select jsonb_array_elements_text(coalesce(row_data->'keywords', '[]'::jsonb))),
      btrim(coalesce(row_data->>'shortDescription', '')), nullif(row_data->>'foundedYear', '')::integer,
      array(select jsonb_array_elements_text(coalesce(row_data->'technologies', '[]'::jsonb))),
      btrim(coalesce(row_data->>'totalFunding', '')), now()
    )
    on conflict (id) do update set
      -- overwrite: the uploaded value wins wherever the upload has one.
      -- enrich:    the stored value wins wherever the store has one.
      name = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.name, ''), public.companies.name)
        else coalesce(nullif(public.companies.name, ''), excluded.name) end,
      normalized_name = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.normalized_name, ''), public.companies.normalized_name)
        else coalesce(nullif(public.companies.normalized_name, ''), excluded.normalized_name) end,
      domain = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.domain, ''), public.companies.domain)
        else coalesce(nullif(public.companies.domain, ''), excluded.domain) end,
      normalized_domain = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.normalized_domain, ''), public.companies.normalized_domain)
        else coalesce(nullif(public.companies.normalized_domain, ''), excluded.normalized_domain) end,
      all_data = case when merge_mode_value = 'overwrite'
        then public.companies.all_data || excluded.all_data
        else excluded.all_data || public.companies.all_data end,
      employee_count_min = case when merge_mode_value = 'overwrite'
        then coalesce(excluded.employee_count_min, public.companies.employee_count_min)
        else coalesce(public.companies.employee_count_min, excluded.employee_count_min) end,
      employee_count_max = case when merge_mode_value = 'overwrite'
        then coalesce(excluded.employee_count_max, public.companies.employee_count_max)
        else coalesce(public.companies.employee_count_max, excluded.employee_count_max) end,
      industry = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.industry, ''), public.companies.industry)
        else coalesce(nullif(public.companies.industry, ''), excluded.industry) end,
      city = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.city, ''), public.companies.city)
        else coalesce(nullif(public.companies.city, ''), excluded.city) end,
      state = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.state, ''), public.companies.state)
        else coalesce(nullif(public.companies.state, ''), excluded.state) end,
      country = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.country, ''), public.companies.country)
        else coalesce(nullif(public.companies.country, ''), excluded.country) end,
      location = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.location, ''), public.companies.location)
        else coalesce(nullif(public.companies.location, ''), excluded.location) end,
      keywords = case
        when merge_mode_value = 'overwrite' and cardinality(excluded.keywords) > 0 then excluded.keywords
        when merge_mode_value = 'overwrite' then public.companies.keywords
        when cardinality(public.companies.keywords) > 0 then public.companies.keywords
        else excluded.keywords end,
      short_description = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.short_description, ''), public.companies.short_description)
        else coalesce(nullif(public.companies.short_description, ''), excluded.short_description) end,
      founded_year = case when merge_mode_value = 'overwrite'
        then coalesce(excluded.founded_year, public.companies.founded_year)
        else coalesce(public.companies.founded_year, excluded.founded_year) end,
      technologies = case
        when merge_mode_value = 'overwrite' and cardinality(excluded.technologies) > 0 then excluded.technologies
        when merge_mode_value = 'overwrite' then public.companies.technologies
        when cardinality(public.companies.technologies) > 0 then public.companies.technologies
        else excluded.technologies end,
      total_funding = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.total_funding, ''), public.companies.total_funding)
        else coalesce(nullif(public.companies.total_funding, ''), excluded.total_funding) end,
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
    skipped_count = skipped_count + skipped_count_value,
    committed_row_offset = greatest(committed_row_offset, p_row_offset + batch_size)
  where id = p_import_id;
  return query select processed_count, added_count_value, updated_count_value, skipped_count_value;
end;
$$;

-- v2 stays callable for any deployed build that has not picked up v3 yet. It now
-- delegates, so such a build gets whatever mode the import row carries -- which is
-- 'enrich' for imports it started, exactly its old behaviour.
create or replace function public.import_company_batch_v2(
  p_import_id text,
  p_rows jsonb,
  p_row_offset integer
)
returns table(processed integer, added integer, updated integer, skipped integer)
language sql
security definer
set search_path = public
as $$
  select * from public.import_company_batch_v3(p_import_id, p_rows, p_row_offset);
$$;

revoke execute on function public.import_company_batch_v3(text, jsonb, integer) from public, anon, authenticated;
revoke execute on function public.import_company_batch_v2(text, jsonb, integer) from public, anon, authenticated;
grant execute on function public.import_company_batch_v3(text, jsonb, integer) to service_role;
grant execute on function public.import_company_batch_v2(text, jsonb, integer) to service_role;

commit;
