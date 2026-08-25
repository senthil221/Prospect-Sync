-- The Company Location support was accidentally appended to the already-applied
-- 20260825070000 migration and updated the obsolete two-argument overload. The
-- application calls the resumable three-argument function, so production never
-- received the change and a fresh database still used the wrong function.
--
-- Remove the unused overload and forward-fix the active RPC. This makes existing
-- and newly-created databases converge without rewriting migration history.
drop function if exists public.import_company_batch_v2(text, jsonb);

create or replace function public.import_company_batch_v2(
  p_import_id text,
  p_rows jsonb,
  p_row_offset integer
)
returns table(processed integer, added integer, updated integer, skipped integer)
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $function$
declare
  row_data jsonb;
  source_name text;
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

  select ci.data_source, ci.committed_row_offset
  into source_name, committed_offset
  from public.company_imports ci
  where ci.id = p_import_id and ci.status = 'processing'
  for update;

  if not found then
    raise exception 'Company import not found or already completed' using errcode = 'P0002';
  end if;

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
    if normalized_name_value = '' and normalized_domain_value = '' then
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

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
      name = coalesce(nullif(excluded.name, ''), public.companies.name),
      normalized_name = coalesce(nullif(excluded.normalized_name, ''), public.companies.normalized_name),
      domain = coalesce(nullif(excluded.domain, ''), public.companies.domain),
      normalized_domain = coalesce(nullif(excluded.normalized_domain, ''), public.companies.normalized_domain),
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
    skipped_count = skipped_count + skipped_count_value,
    committed_row_offset = greatest(committed_row_offset, p_row_offset + batch_size)
  where id = p_import_id;
  return query select processed_count, added_count_value, updated_count_value, skipped_count_value;
end;
$function$;

revoke execute on function public.import_company_batch_v2(text, jsonb, integer) from public, anon, authenticated;
grant execute on function public.import_company_batch_v2(text, jsonb, integer) to service_role;

do $smoke$
begin
  if to_regprocedure('public.import_company_batch_v2(text,jsonb,integer)') is null then
    raise exception 'active resumable company import function is missing';
  end if;
  if to_regprocedure('public.import_company_batch_v2(text,jsonb)') is not null then
    raise exception 'obsolete company import overload still exists';
  end if;
  if has_function_privilege('anon', 'public.import_company_batch_v2(text,jsonb,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.import_company_batch_v2(text,jsonb,integer)', 'execute') then
    raise exception 'company import function is exposed to browser roles';
  end if;
  if not has_function_privilege('service_role', 'public.import_company_batch_v2(text,jsonb,integer)', 'execute') then
    raise exception 'service_role cannot execute company imports';
  end if;
end;
$smoke$;
