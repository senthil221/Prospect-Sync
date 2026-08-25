-- Apollo-style single Location field for people, plus the "No client" rename.
--
-- __person_location was already filterable, but it was computed per row as
-- concat_ws(city, state, country) inside the scalar matcher — invisible to every
-- index and impossible for prospect_prefilter_sql to narrow on. It also had no
-- home for a location that arrives as one column ("London, England, UK"), which
-- is how Apollo, Clay and most scrapers actually export it: the parts were
-- guessed apart on import and re-joined on read.
--
-- prospects.location becomes the stored, indexed, canonical field. city / state /
-- country stay exactly as they are — exports still need them, and the
-- fill-from-company enrichment reads them — but Location is what the UI filters
-- and displays.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------

alter table public.prospects add column if not exists location text not null default '';
alter table public.prospect_index add column if not exists location text not null default '';

-- Backfill: prefer a location column preserved in all_data, otherwise compose it
-- from the parts. Matches the aliases db/normalize.ts resolves on import.
update public.prospects p set location = coalesce(
  nullif(btrim((
    select entry.value
    from jsonb_each_text(p.all_data) entry(key, value)
    where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in ('location', 'personlocation', 'contactlocation')
      and btrim(entry.value) <> ''
    limit 1
  )), ''),
  nullif(concat_ws(', ', nullif(p.city, ''), nullif(p.state, ''), nullif(p.country, '')), ''),
  ''
)
where p.location = '';

create index if not exists idx_prospect_index_location_trgm
  on public.prospect_index using gin (location gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 2. Write path: persist location on import
-- ---------------------------------------------------------------------------

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

    -- An explicit Location column wins; otherwise compose from the parts so the
    -- field is always populated and always filterable.
    location_value := coalesce(nullif(btrim(coalesce(row_data->>'location', '')), ''), nullif(concat_ws(', ',
      nullif(btrim(coalesce(row_data->>'city', '')), ''),
      nullif(btrim(coalesce(row_data->>'state', '')), ''),
      nullif(btrim(coalesce(row_data->>'country', '')), '')
    ), ''), '');

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
    -- of forking a new 'name:' row.
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
        location = case when location = '' then location_value else location end,
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

revoke execute on function public.import_prospect_batch_v2(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.import_prospect_batch_v2(text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Read paths: location becomes a first-class indexed field
-- ---------------------------------------------------------------------------

-- The pre-filter can now narrow on location before the scalar matcher runs.
create or replace function public.prospect_prefilter_sql(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  value_parts text[];
  raw_values text[];
  value_text text;
  -- Above this many values an OR chain costs more to plan than the index scan
  -- saves, so the pre-filter switches to an array predicate.
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('pi.search_text ilike %L', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';
    column_expr := case field_key
      when '__name' then 'pi.full_name'
      when '__first_name' then 'pi.first_name'
      when '__last_name' then 'pi.last_name'
      when '__company' then 'pi.company_name'
      when '__company_domain' then 'pi.company_domain'
      when '__title' then 'pi.title'
      when '__seniority' then 'pi.seniority'
      when '__department' then 'pi.department'
      when '__work_email' then 'pi.work_email'
      when '__personal_email' then 'pi.personal_email'
      when '__linkedin' then 'pi.linkedin_url'
      when '__city' then 'pi.city'
      when '__state' then 'pi.state'
      when '__country' then 'pi.country'
      when '__person_location' then 'pi.location'
      when '__company_city' then 'pi.company_city'
      when '__company_state' then 'pi.company_state'
      when '__company_country' then 'pi.company_country'
      when '__esp' then 'pi.esp'
      when '__email_provider_type' then 'pi.email_provider_type'
      when '__tags' then 'pi.tag_text'
      else null
    end;
    if column_expr is null then continue; end if;

    -- Collect the raw values once, then choose a shape by size. All three shapes
    -- below are exactly equivalent to the OR-of-values the real predicate applies,
    -- so the pre-filter stays implied by it no matter which one is emitted.
    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    if operator_key = 'equals' then
      -- Equality scales to any list size as a single array membership test.
      conjuncts := conjuncts || format('lower(%s) = any (%L::text[])',
        column_expr, array(select lower(value) from unnest(raw_values) value));
    elsif cardinality(raw_values) <= bulk_or_threshold then
      -- Few enough values that the planner can still BitmapOr the trigram index.
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      -- A pasted column of hundreds of values: one lateral over the array beats a
      -- several-hundred-branch OR, which costs more to plan than it saves.
      conjuncts := conjuncts || format(
        'exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')',
        raw_values, column_expr);
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$$;

revoke execute on function public.prospect_prefilter_sql(text, jsonb) from public, anon, authenticated;
grant execute on function public.prospect_prefilter_sql(text, jsonb) to service_role;

-- The scalar matcher reads the stored column instead of recomposing it per row.
-- Falls back to the parts so a row indexed before this migration still matches.
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
        when '__person_location' then coalesce(nullif((p_row).location, ''),
          concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, '')))
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

revoke execute on function public.prospect_index_matches_v1(public.prospect_index, text, jsonb) from public, anon, authenticated;
grant execute on function public.prospect_index_matches_v1(public.prospect_index, text, jsonb) to service_role;

-- Autocomplete values for the Location filter come from the stored column too,
-- so the dropdown offers whole locations rather than recomposed fragments.
create or replace function public.prospect_filter_values_v3(
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
  with scoped as (
    select ps.*
    from public.prospect_index ps
    where p_client_id is null or ps.client_ids @> array[p_client_id]
  ), raw_values as (
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
      when '__person_location' then coalesce(nullif(ps.location, ''),
        concat_ws(', ', nullif(ps.city, ''), nullif(ps.state, ''), nullif(ps.country, '')))
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
    select ps.id, to_char(ps.last_contacted_at at time zone 'UTC', 'YYYY-MM-DD') from scoped ps
      where p_field = '__last_contacted' and ps.last_contacted_at is not null
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

revoke execute on function public.prospect_filter_values_v3(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.prospect_filter_values_v3(text, text, text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Index maintenance: carry location into prospect_index and search_text
-- ---------------------------------------------------------------------------

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
      concat_ws(' ',
        c.full_name, c.work_email, c.personal_email, c.title, array_to_string(c.keywords, ' '),
        c.company_name, c.company_domain, c.linkedin_url, c.city, c.state, c.country, c.location,
        c.company_location, c.company_city, c.company_state, c.company_country,
        c.all_data::text, c.esp, c.email_provider_type, array_to_string(c.mx_records, ' '),
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
grant execute on function public.reindex_prospects(text[]) to service_role;

-- Backfill the index column directly rather than reindexing every prospect: the
-- other 40-odd index columns are already correct, only location is new.
update public.prospect_index pi set
  location = coalesce(nullif(p.location, ''), concat_ws(', ', nullif(pi.city, ''), nullif(pi.state, ''), nullif(pi.country, ''))),
  search_text = pi.search_text || ' ' || coalesce(nullif(p.location, ''), '')
from public.prospects p
where p.id = pi.id and pi.location = '';

-- ---------------------------------------------------------------------------
-- 5. "No client" becomes "Unassigned"
-- ---------------------------------------------------------------------------
-- lib/import-owner.ts upserts this row by id on every unassigned import, so the
-- constant is the source of truth; this only brings the existing row into line
-- and refreshes the denormalized client_names that the People DB reads.

update public.clients set name = 'Unassigned'
where id = 'prospect-sync-no-client' and name <> 'Unassigned';

update public.prospect_index set
  client_names = array_replace(client_names, 'No client', 'Unassigned'),
  search_text = replace(search_text, 'No client', 'Unassigned')
where client_names @> array['No client'];

analyze public.prospects;
analyze public.prospect_index;

-- ---------------------------------------------------------------------------
-- 6. Smoke test
-- ---------------------------------------------------------------------------
-- prospect_prefilter_sql now emits three different shapes depending on operator
-- and list size, and each one is spliced into dynamic SQL. Exercise all three
-- here so a malformed branch rolls the migration back instead of shipping.
do $smoke$
declare
  v_row record;
  v_sql text;
  v_many jsonb;
begin
  -- equals -> array membership
  v_sql := public.prospect_prefilter_sql('', '[{"field":"__company_domain","operator":"equals","values":["acme.com","stripe.com"]}]'::jsonb);
  if v_sql not like '%= any%' then
    raise exception 'equals filters must compile to an array predicate, got: %', v_sql;
  end if;

  -- small contains -> OR chain
  v_sql := public.prospect_prefilter_sql('', '[{"field":"__title","operator":"contains","values":["director","head of"]}]'::jsonb);
  if v_sql not like '%ilike%' or v_sql like '%unnest%' then
    raise exception 'small contains filters must compile to an OR chain, got: %', v_sql;
  end if;

  -- large contains -> lateral over the array
  select jsonb_build_object('field', '__company', 'operator', 'contains',
    'values', jsonb_agg('company-' || generation || '.com'))
  into v_many
  from generate_series(1, 120) generation;
  v_sql := public.prospect_prefilter_sql('', jsonb_build_array(v_many));
  if v_sql not like '%unnest%' then
    raise exception 'large contains filters must compile to an array predicate, got: %', left(v_sql, 200);
  end if;

  -- and every shape must actually run end to end through the workspace function
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"__company_domain","operator":"equals","values":["acme.com"]}]'::jsonb, p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => jsonb_build_array(v_many), p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"__person_location","operator":"contains","values":["london"]}]'::jsonb, p_with_total => false);
  select * into v_row from public.prospect_filter_values_v3('__person_location', '', null, 5);
end;
$smoke$;
