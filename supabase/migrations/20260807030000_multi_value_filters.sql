create or replace function public.search_prospect_workspace(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with filtered as materialized (
    select ps.*
    from public.prospect_summaries ps
    where (
      trim(coalesce(p_search, '')) = ''
      or concat_ws(' ', ps.full_name, ps.work_email, ps.personal_email, ps.title,
        ps.company_name, ps.company_domain, ps.linkedin_url, ps.country, ps.all_data::text)
        ilike '%' || trim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__company' then ps.company_name
          when '__email' then coalesce(ps.work_email, ps.personal_email)
          when '__title' then ps.title
          when '__linkedin' then ps.linkedin_url
          when '__country' then ps.country
          when '__seniority' then ps.seniority
          when '__department' then ps.department
          else ps.all_data ->> (filter_item->>'field')
        end, '') as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then exists (
          select 1
          from jsonb_array_elements_text(
            case when jsonb_typeof(filter_item->'values') = 'array'
              then filter_item->'values'
              else jsonb_build_array(coalesce(filter_item->>'value', ''))
            end
          ) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
        )
        when 'empty' then trim(candidate.candidate_value) = ''
        when 'not_empty' then trim(candidate.candidate_value) <> ''
        else exists (
          select 1
          from jsonb_array_elements_text(
            case when jsonb_typeof(filter_item->'values') = 'array'
              then filter_item->'values'
              else jsonb_build_array(coalesce(filter_item->>'value', ''))
            end
          ) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
      end
    )
  ),
  page_rows as (
    select * from filtered
    order by created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select
    coalesce((select jsonb_agg(to_jsonb(page_rows) order by page_rows.created_at desc) from page_rows), '[]'::jsonb),
    (select count(*) from filtered);
$$;

revoke execute on function public.search_prospect_workspace(text, jsonb, integer, integer) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace(text, jsonb, integer, integer) to service_role;
