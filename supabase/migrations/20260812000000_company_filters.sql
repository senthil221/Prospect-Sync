-- Company tab filters: domain/website (exact, on the normalized domain),
-- seniority, and location. Seniority and location are person-level attributes
-- (the company location columns are effectively empty in practice), so a
-- company qualifies when it has at least one prospect that matches every active
-- person-criterion together -- e.g. "a Manager located in Mumbai". Counts are
-- derived from the small, indexed prospect_index rather than the heavy
-- company_summaries view so filtered reads stay fast.

-- Speeds up the per-company lookups the function relies on.
create index if not exists idx_prospect_index_company_id on public.prospect_index (company_id);

create or replace function public.filter_companies(
  p_search text default '',
  p_domains text[] default '{}',
  p_seniority text[] default '{}',
  p_locations text[] default '{}',
  p_client_id text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select c.id, c.name, c.domain, c.created_at
    from public.companies c
    where
      (coalesce(p_search, '') = '' or c.name ilike '%' || p_search || '%' or c.domain ilike '%' || p_search || '%')
      and (coalesce(cardinality(p_domains), 0) = 0 or c.normalized_domain = any(p_domains))
      -- Seniority and location are person-level: a company qualifies when it has a
      -- prospect that matches every active person-criterion (e.g. a Manager IN India).
      and (
        (coalesce(cardinality(p_seniority), 0) = 0 and coalesce(cardinality(p_locations), 0) = 0)
        or exists (
          select 1 from public.prospect_index pi
          where pi.company_id = c.id
            and (p_client_id is null or p_client_id = any(pi.client_ids))
            and (coalesce(cardinality(p_seniority), 0) = 0 or pi.seniority = any(p_seniority))
            and (coalesce(cardinality(p_locations), 0) = 0 or exists (
              select 1 from unnest(p_locations) as loc
              where concat_ws(', ', nullif(pi.city, ''), nullif(pi.state, ''), nullif(pi.country, '')) ilike '%' || loc || '%'
            ))
        )
      )
      and (p_client_id is null or exists (
        select 1 from public.prospect_index pi
        where pi.company_id = c.id and p_client_id = any(pi.client_ids)
      ))
  ),
  agg as (
    select b.id, b.name, b.domain, b.created_at,
           coalesce(pc.prospect_count, 0) as prospect_count,
           coalesce(pc.client_count, 0) as client_count
    from base b
    left join lateral (
      select count(distinct pi.id)::integer as prospect_count,
             count(distinct cl)::integer as client_count
      from public.prospect_index pi
      left join lateral unnest(pi.client_ids) as cl on true
      where pi.company_id = b.id
        and (p_client_id is null or p_client_id = any(pi.client_ids))
    ) pc on true
  ),
  counted as (
    select count(*)::integer as total_count,
           count(*) filter (where prospect_count > 0)::integer as covered_count,
           coalesce(sum(prospect_count), 0)::integer as prospect_total
    from agg
  ),
  page as (
    select id, name, domain, created_at, prospect_count, client_count
    from agg
    order by prospect_count desc, name
    offset greatest(coalesce(p_offset, 0), 0)
    limit greatest(coalesce(p_limit, 50), 1)
  )
  select
    coalesce((select jsonb_agg(to_jsonb(p) order by p.prospect_count desc, p.name) from page p), '[]'::jsonb),
    counted.total_count,
    counted.covered_count,
    counted.prospect_total
  from counted;
$$;

revoke execute on function public.filter_companies(text, text[], text[], text[], text, integer, integer) from public, anon, authenticated;
grant execute on function public.filter_companies(text, text[], text[], text[], text, integer, integer) to service_role;
