create or replace view public.prospect_summaries as
select p.*, co.name as company_name, co.domain as company_domain,
  count(distinct lm.list_id)::integer as list_count,
  count(distinct l.client_id)::integer as client_count,
  coalesce(array_agg(distinct l.name order by l.name) filter (where l.id is not null), '{}'::text[]) as list_names,
  coalesce(array_agg(distinct cl.name order by cl.name) filter (where cl.id is not null), '{}'::text[]) as client_names,
  coalesce(array_agg(distinct l.id order by l.id) filter (where l.id is not null), '{}'::text[]) as list_ids,
  coalesce(array_agg(distinct cl.id order by cl.id) filter (where cl.id is not null), '{}'::text[]) as client_ids,
  coalesce(jsonb_agg(distinct jsonb_build_object(
    'listId', l.id, 'listName', l.name, 'clientId', cl.id, 'clientName', cl.name
  )) filter (where l.id is not null), '[]'::jsonb) as list_memberships
from public.prospects p
left join public.companies co on co.id = p.company_id
left join public.list_memberships lm on lm.prospect_id = p.id
left join public.lists l on l.id = lm.list_id
left join public.clients cl on cl.id = l.client_id
group by p.id, co.id;

create or replace function public.search_prospect_workspace_v4(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_client_id text default null
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with enriched as materialized (
    select ps.*,
      activity.last_contacted_at,
      coalesce(activity.contact_count, 0)::integer as contact_count,
      coalesce(tags.tag_names, '[]'::jsonb) as tags
    from public.prospect_summaries ps
    left join lateral (
      select max(ce.contacted_at) as last_contacted_at, count(*) as contact_count
      from public.contact_events ce
      where ce.prospect_id = ps.id and (p_client_id is null or ce.client_id = p_client_id)
    ) activity on true
    left join lateral (
      select jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'color', pt.color) order by pt.name) as tag_names
      from public.prospect_tag_links ptl
      join public.prospect_tags pt on pt.id = ptl.tag_id
      where ptl.prospect_id = ps.id
    ) tags on true
    where p_client_id is null or p_client_id = any(ps.client_ids)
  ), filtered as materialized (
    select ps.*
    from enriched ps
    where (
      trim(coalesce(p_search, '')) = ''
      or concat_ws(' ', ps.full_name, ps.work_email, ps.personal_email, ps.title,
        ps.company_name, ps.company_domain, ps.linkedin_url, ps.country, ps.all_data::text,
        ps.tags::text, array_to_string(ps.list_names, ' '), array_to_string(ps.client_names, ' '))
        ilike '%' || trim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__company' then ps.company_name
          when '__email' then coalesce(nullif(ps.work_email, ''), ps.personal_email)
          when '__title' then ps.title
          when '__linkedin' then ps.linkedin_url
          when '__country' then ps.country
          when '__seniority' then ps.seniority
          when '__department' then ps.department
          when '__tags' then ps.tags::text
          when '__last_contacted' then ps.last_contacted_at::text
          when '__lists' then array_to_string(ps.list_names, ' | ')
          when '__clients' then array_to_string(ps.client_names, ' | ')
          else ps.all_data ->> (filter_item->>'field')
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
            or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
              case when filter_item->>'field' = '__lists' then ps.list_names else ps.client_names end
            ))
        )
        when 'not_contains' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
        when 'empty' then trim(candidate.candidate_value) = ''
        when 'not_empty' then trim(candidate.candidate_value) <> ''
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
      created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb),
    (select count(*) from filtered);
$$;

create or replace function public.client_company_workspace(
  p_client_id text,
  p_search text default '',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with client_prospects as materialized (
    select distinct lm.prospect_id, p.company_id
    from public.list_memberships lm
    join public.lists l on l.id = lm.list_id and l.client_id = p_client_id
    join public.prospects p on p.id = lm.prospect_id
  ), matched as materialized (
    select c.id, c.name, c.domain, c.created_at,
      count(distinct cp.prospect_id)::integer as prospect_count,
      1::integer as client_count
    from client_prospects cp
    join public.companies c on c.id = cp.company_id
    where trim(coalesce(p_search, '')) = ''
      or concat_ws(' ', c.name, c.domain) ilike '%' || trim(p_search) || '%'
    group by c.id
  ), page_rows as (
    select * from matched
    order by prospect_count desc, name
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows)) from page_rows), '[]'::jsonb),
    (select count(*) from matched),
    (select count(*) from matched where matched.prospect_count > 0),
    (select count(*) from client_prospects where company_id is not null);
$$;

create or replace function public.client_company_prospects(
  p_client_id text,
  p_company_id text,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with matched as materialized (
    select distinct ps.*
    from public.prospect_summaries ps
    join public.list_memberships lm on lm.prospect_id = ps.id
    join public.lists l on l.id = lm.list_id
    where l.client_id = p_client_id and ps.company_id = p_company_id
  ), page_rows as (
    select * from matched order by full_name
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows)) from page_rows), '[]'::jsonb),
    (select count(*) from matched);
$$;

create or replace function public.import_prospect_batch_v3(
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
  base_result record;
  cross_client_duplicates integer := 0;
begin
  select * into base_result
  from public.import_prospect_batch_v2(p_import_id, p_list_id, p_rows);

  select count(*)::integer into cross_client_duplicates
  from public.list_rows lr
  join public.lists current_list on current_list.id = p_list_id
  where lr.import_id = p_import_id
    and lr.prospect_id is not null
    and lr.source_row_number in (
      select coalesce(nullif(item.value->>'sourceRowNumber', '')::integer, 0)
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) item(value)
    )
    and exists (
      select 1
      from public.list_memberships other_membership
      join public.lists other_list on other_list.id = other_membership.list_id
      where other_membership.prospect_id = lr.prospect_id
        and other_list.client_id <> current_list.client_id
        and other_membership.imported_at < lr.imported_at
    );

  update public.imports set
    duplicates_linked = greatest(0, imports.duplicates_linked - base_result.duplicates_linked + cross_client_duplicates)
  where id = p_import_id;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := cross_client_duplicates;
  skipped := base_result.skipped;
  return next;
end;
$$;

update public.imports i set duplicates_linked = coalesce((
  select count(*)::integer
  from public.list_rows lr
  join public.lists current_list on current_list.id = lr.list_id
  where lr.import_id = i.id and lr.prospect_id is not null
    and exists (
      select 1
      from public.list_memberships other_membership
      join public.lists other_list on other_list.id = other_membership.list_id
      where other_membership.prospect_id = lr.prospect_id
        and other_list.client_id <> current_list.client_id
        and other_membership.imported_at < lr.imported_at
    )
), 0);

update public.lists l set duplicates_linked = coalesce((
  select sum(i.duplicates_linked)::integer from public.imports i where i.list_id = l.id
), 0);

create or replace function public.find_duplicate_candidates(p_limit integer default 100)
returns table(result_rows jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'left', to_jsonb(a), 'right', to_jsonb(b),
    'reason', 'Same person found in different clients', 'confidence', 90
  )), '[]'::jsonb)
  from (
    select p1.* from public.prospect_summaries p1
    join public.prospects p2 on p1.id < p2.id
      and lower(trim(p1.full_name)) = lower(trim(p2.full_name))
      and p1.company_id = p2.company_id
    where trim(p1.full_name) <> '' and p1.company_id is not null
      and exists (
        select 1 from public.list_memberships lm1
        join public.lists l1 on l1.id = lm1.list_id
        join public.list_memberships lm2 on lm2.prospect_id = p2.id
        join public.lists l2 on l2.id = lm2.list_id
        where lm1.prospect_id = p1.id and l1.client_id <> l2.client_id
      )
    order by p1.updated_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 250))
  ) a
  join lateral (
    select p2.* from public.prospect_summaries p2
    where a.id < p2.id
      and lower(trim(a.full_name)) = lower(trim(p2.full_name))
      and a.company_id = p2.company_id
      and exists (
        select 1 from unnest(a.client_ids) left_client(id)
        cross join unnest(p2.client_ids) right_client(id)
        where left_client.id <> right_client.id
      )
    order by p2.updated_at desc limit 1
  ) b on true;
$$;

revoke execute on function public.search_prospect_workspace_v4(text, jsonb, text, text, integer, integer, text) from public, anon, authenticated;
revoke execute on function public.client_company_workspace(text, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.client_company_prospects(text, text, integer, integer) from public, anon, authenticated;
revoke execute on function public.import_prospect_batch_v3(text, text, jsonb) from public, anon, authenticated;

grant execute on function public.search_prospect_workspace_v4(text, jsonb, text, text, integer, integer, text) to service_role;
grant execute on function public.client_company_workspace(text, text, integer, integer) to service_role;
grant execute on function public.client_company_prospects(text, text, integer, integer) to service_role;
grant execute on function public.import_prospect_batch_v3(text, text, jsonb) to service_role;
