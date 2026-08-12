-- Materialize only narrow sort/count keys. The previous function materialized
-- every wide prospect JSON row before pagination, which could spill to disk.

create index if not exists idx_company_sources_last_import_id on public.company_sources(last_import_id);

create or replace function public.search_prospect_workspace_v10(
  p_search text default '', p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at', p_direction text default 'desc',
  p_limit integer default 50, p_offset integer default 0,
  p_client_id text default null, p_company_scope jsonb default '{}'::jsonb
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
  with eligible_companies as materialized (
    select company_id from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
  ), matched as materialized (
    select ps.id, ps.created_at, ps.full_name, ps.company_name, ps.title, ps.last_contacted_at
    from public.prospect_index ps
    join eligible_companies eligible on eligible.company_id = ps.company_id
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
      and ((btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.prospect_index_matches_v1(ps, p_search, p_filters))
  ), ordered_page as (
    select * from matched order by
      case when p_sort = 'name' and lower(p_direction) = 'asc' then lower(full_name) end asc,
      case when p_sort = 'name' and lower(p_direction) = 'desc' then lower(full_name) end desc,
      case when p_sort = 'company' and lower(p_direction) = 'asc' then lower(company_name) end asc,
      case when p_sort = 'company' and lower(p_direction) = 'desc' then lower(company_name) end desc,
      case when p_sort = 'title' and lower(p_direction) = 'asc' then lower(title) end asc,
      case when p_sort = 'title' and lower(p_direction) = 'desc' then lower(title) end desc,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'asc' then last_contacted_at end asc nulls first,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'desc' then last_contacted_at end desc nulls last,
      case when p_sort = 'created_at' and lower(p_direction) = 'asc' then created_at end asc,
      created_at desc, id
    limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
  ), page as (
    select ordered_page.*, row_number() over (order by
      case when p_sort = 'name' and lower(p_direction) = 'asc' then lower(full_name) end asc,
      case when p_sort = 'name' and lower(p_direction) = 'desc' then lower(full_name) end desc,
      case when p_sort = 'company' and lower(p_direction) = 'asc' then lower(company_name) end asc,
      case when p_sort = 'company' and lower(p_direction) = 'desc' then lower(company_name) end desc,
      case when p_sort = 'title' and lower(p_direction) = 'asc' then lower(title) end asc,
      case when p_sort = 'title' and lower(p_direction) = 'desc' then lower(title) end desc,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'asc' then last_contacted_at end asc nulls first,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'desc' then last_contacted_at end desc nulls last,
      case when p_sort = 'created_at' and lower(p_direction) = 'asc' then created_at end asc,
      created_at desc, id) as page_order
    from ordered_page
  ), hydrated as (
    select ps.*, page.page_order
    from page join public.prospect_index ps on ps.id = page.id
  )
  select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
    (select count(*) from matched);
$$;

create or replace function public.search_prospect_export_v4(
  p_search text default '', p_filters jsonb default '[]'::jsonb, p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb, p_after_created_at timestamptz default null,
  p_after_id text default null, p_limit integer default 5000, p_with_total boolean default false
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '60s'
as $$
  with eligible_companies as materialized (
    select company_id from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
  ), matched as materialized (
    select ps.id, ps.created_at
    from public.prospect_index ps
    join eligible_companies eligible on eligible.company_id = ps.company_id
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
      and ((btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.prospect_index_matches_v1(ps, p_search, p_filters))
  ), ordered_page as (
    select * from matched
    where p_after_created_at is null or (matched.created_at, matched.id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by matched.created_at desc, matched.id desc
    limit greatest(1, least(coalesce(p_limit, 5000), 50000))
  ), page as (
    select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order
    from ordered_page
  ), hydrated as (
    select ps.*, page.page_order
    from page join public.prospect_index ps on ps.id = page.id
  )
  select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
    case when p_with_total then (select count(*) from matched) else null end;
$$;

revoke execute on function public.search_prospect_workspace_v10(text, jsonb, text, text, integer, integer, text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_export_v4(text, jsonb, text, jsonb, timestamptz, text, integer, boolean) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v10(text, jsonb, text, text, integer, integer, text, jsonb) to service_role;
grant execute on function public.search_prospect_export_v4(text, jsonb, text, jsonb, timestamptz, text, integer, boolean) to service_role;
