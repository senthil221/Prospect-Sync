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
