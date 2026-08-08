create or replace function public.prospect_filter_values(
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
  with scoped as materialized (
    select ps.*
    from public.prospect_summaries ps
    where p_client_id is null or p_client_id = any(ps.client_ids)
  ), raw_values as materialized (
    select ps.id as prospect_id,
      btrim(case p_field
        when '__name' then ps.full_name
        when '__company' then ps.company_name
        when '__email' then coalesce(nullif(ps.work_email, ''), ps.personal_email)
        when '__title' then ps.title
        when '__linkedin' then ps.linkedin_url
        when '__country' then ps.country
        when '__seniority' then ps.seniority
        when '__department' then ps.department
        else ps.all_data ->> p_field
      end) as value
    from scoped ps
    where p_field not in ('__lists', '__clients', '__tags', '__last_contacted')

    union all

    select ps.id, btrim(list_name)
    from scoped ps
    cross join lateral unnest(ps.list_names) list_name
    where p_field = '__lists'

    union all

    select ps.id, btrim(client_name)
    from scoped ps
    cross join lateral unnest(ps.client_names) client_name
    where p_field = '__clients'

    union all

    select ps.id, btrim(pt.name)
    from scoped ps
    join public.prospect_tag_links ptl on ptl.prospect_id = ps.id
    join public.prospect_tags pt on pt.id = ptl.tag_id
    where p_field = '__tags'

    union all

    select ps.id, to_char(max(ce.contacted_at) at time zone 'UTC', 'YYYY-MM-DD')
    from scoped ps
    join public.contact_events ce on ce.prospect_id = ps.id
      and (p_client_id is null or ce.client_id = p_client_id)
    where p_field = '__last_contacted'
    group by ps.id
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

revoke execute on function public.prospect_filter_values(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.prospect_filter_values(text, text, text, integer) to service_role;
