-- Conditional workspace totals: selective queries keep exact counts while the
-- unscoped People DB can use PostgreSQL's maintained planner estimate.

create or replace function public.search_prospect_workspace_v11(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb,
  p_with_total boolean default true
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
  with filtered as (
    select ps.*
    from public.prospect_index ps
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
    and (
      coalesce(p_company_scope, '{}'::jsonb) = '{}'::jsonb
      or ps.company_id in (
        select company_id
        from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
      )
    )
    and (
      btrim(coalesce(p_search, '')) = ''
      or ps.search_text ilike '%' || btrim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__first_name' then ps.first_name
          when '__last_name' then ps.last_name
          when '__company' then ps.company_name
          when '__email' then concat_ws(' ', ps.work_email, ps.personal_email)
          when '__work_email' then ps.work_email
          when '__personal_email' then ps.personal_email
          when '__title' then ps.title
          when '__keywords' then array_to_string(ps.keywords, ' | ')
          when '__linkedin' then ps.linkedin_url
          when '__city' then ps.city
          when '__state' then ps.state
          when '__country' then ps.country
          when '__person_location' then concat_ws(', ', nullif(ps.city, ''), nullif(ps.state, ''), nullif(ps.country, ''))
          when '__company_location' then concat_ws(', ', nullif(ps.company_location, ''), nullif(ps.company_city, ''), nullif(ps.company_state, ''), nullif(ps.company_country, ''))
          when '__company_city' then ps.company_city
          when '__company_state' then ps.company_state
          when '__company_country' then ps.company_country
          when '__seniority' then ps.seniority
          when '__department' then ps.department
          when '__esp' then ps.esp
          when '__email_provider_type' then ps.email_provider_type
          when '__tags' then ps.tag_text
          when '__last_contacted' then ps.last_contacted_at::text
          when '__lists' then array_to_string(ps.list_names, ' | ')
          when '__clients' then array_to_string(ps.client_names, ' | ')
          else case when filter_item->>'field' like 'custom:%' then coalesce((
            select string_agg(entry.value, ' | ' order by entry.key)
            from jsonb_each_text(ps.all_data) entry(key, value)
            where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
          ), '') else '' end
        end, '') as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
            or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
              case when filter_item->>'field' = '__lists' then ps.list_names else ps.client_names end
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
            and (
              (selected.value = 'unknown' and ps.employee_count_min is null and ps.employee_count_max is null)
              or (selected.value <> 'unknown' and ps.employee_count_min is not null
                and (selected_range.maximum is null or ps.employee_count_min <= selected_range.maximum)
                and (ps.employee_count_max is null or ps.employee_count_max >= selected_range.minimum))
            )
        )
        when 'empty' then btrim(candidate.candidate_value) = ''
        when 'not_empty' then btrim(candidate.candidate_value) <> ''
        else exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
      end
    )
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
      created_at desc,
      id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb),
    case
      when not p_with_total then null
      when btrim(coalesce(p_search, '')) = ''
        and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb
        and p_client_id is null
        and coalesce(p_company_scope, '{}'::jsonb) = '{}'::jsonb
        then (
          select pg_class.reltuples::bigint
          from pg_class
          join pg_namespace on pg_namespace.oid = pg_class.relnamespace
          where pg_namespace.nspname = 'public' and pg_class.relname = 'prospect_index'
        )
      else (select count(*) from filtered)
    end;
$$;

revoke execute on function public.search_prospect_workspace_v11(text, jsonb, text, text, integer, integer, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v11(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;

-- Bound the write-side hot paths without changing their behavior.
create or replace function public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb)
returns table(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $function$
declare
  base_result record;
begin
  select * into base_result
  from public.import_prospect_batch_v4(p_import_id, p_list_id, p_rows);

  -- Only the prospects touched by THIS chunk, not every row of the import.
  perform public.reindex_prospects(array(
    select distinct lr.prospect_id
    from public.list_rows lr
    where lr.import_id = p_import_id
      and lr.prospect_id is not null
      and lr.source_row_number = any(
        select (elem->>'sourceRowNumber')::integer
        from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as elem
        where nullif(elem->>'sourceRowNumber', '') is not null
      )
  ));

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$function$;

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
      linkedin_url, title, seniority, department, city, state, country, company_id,
      company_name, company_domain, all_data, created_at, updated_at, list_count, client_count,
      list_names, client_names, list_ids, client_ids, list_memberships, esp, email_provider_type,
      mx_records, mx_status, mx_checked_at, keywords, employee_count_min, employee_count_max,
      company_location, company_city, company_state, company_country, tags, tag_text,
      last_contacted_at, contact_count, search_text
    )
    select
      c.id, c.first_name, c.last_name, c.full_name, c.work_email, c.personal_email, c.mobile_number,
      c.linkedin_url, c.title, c.seniority, c.department, c.city, c.state, c.country, c.company_id,
      c.company_name, c.company_domain, c.all_data, c.created_at, c.updated_at, c.list_count, c.client_count,
      c.list_names, c.client_names, c.list_ids, c.client_ids, c.list_memberships, c.esp, c.email_provider_type,
      c.mx_records, c.mx_status, c.mx_checked_at, c.keywords, c.employee_count_min, c.employee_count_max,
      c.company_location, c.company_city, c.company_state, c.company_country, c.tags, c.tag_text,
      c.last_contacted_at, c.contact_count,
      concat_ws(' ',
        c.full_name, c.work_email, c.personal_email, c.title, array_to_string(c.keywords, ' '),
        c.company_name, c.company_domain, c.linkedin_url, c.city, c.state, c.country,
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

create or replace function public.reindex_all()
returns integer
language sql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
  select public.reindex_prospects(array(select id from public.prospects));
$$;

revoke execute on function public.import_prospect_batch_v5(text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.reindex_prospects(text[]) from public, anon, authenticated;
revoke execute on function public.reindex_all() from public, anon, authenticated;

grant execute on function public.import_prospect_batch_v5(text, text, jsonb) to service_role;
grant execute on function public.reindex_prospects(text[]) to service_role;
grant execute on function public.reindex_all() to service_role;
