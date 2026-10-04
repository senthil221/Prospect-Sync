-- Let PostgreSQL inline the selective client summary CTEs instead of forcing
-- five database-wide intermediate results. A read-only production comparison
-- on 2026-10-04 found identical rows for all ten clients; the forced plan hit
-- an 8s statement timeout while the candidate completed in 1.618s on a later
-- (not cache-controlled) run. This migration changes no result predicates.
create or replace view public.client_summaries as
with incomplete_company_ids as not materialized (
  select company.id
  from public.companies company
  where btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
    and btrim(coalesce(company.short_description, '')) = ''
), incomplete_prospect_ids as not materialized (
  select prospect.id
  from incomplete_company_ids incomplete_company
  join public.prospects prospect on prospect.company_id = incomplete_company.id
), active_client_memberships as not materialized (
  select membership.client_id, membership.prospect_id, membership.icp_verified
  from public.client_prospects membership
  where membership.status = 'active'
), incomplete_people_counts as (
  select membership.client_id,
    count(*)::integer as prospect_count,
    count(*) filter (where membership.icp_verified)::integer as icp_verified_count
  from active_client_memberships membership
  join incomplete_prospect_ids incomplete_prospect on incomplete_prospect.id = membership.prospect_id
  group by membership.client_id
), incomplete_company_counts as (
  select membership.client_id, count(*)::integer as company_count
  from incomplete_company_ids incomplete_company
  join public.client_companies membership on membership.company_id = incomplete_company.id
  group by membership.client_id
), seg_clients as not materialized (
  select setting.client_id from public.client_settings setting where setting.seg_emails = 'discard'
), seg_company_ids as not materialized (
  select company.id
  from public.companies company
  where company.email_provider_type = 'SEG'
    and exists (select 1 from seg_clients)
    and not (btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
             and btrim(coalesce(company.short_description, '')) = '')
), seg_people_counts as (
  select membership.client_id,
    count(*)::integer as prospect_count,
    count(*) filter (where membership.icp_verified)::integer as icp_verified_count
  from seg_clients seg_client
  join active_client_memberships membership on membership.client_id = seg_client.client_id
  join public.prospects prospect on prospect.id = membership.prospect_id
  join seg_company_ids seg_company on seg_company.id = prospect.company_id
  group by membership.client_id
), seg_company_counts as (
  select membership.client_id, count(*)::integer as company_count
  from seg_clients seg_client
  join public.client_companies membership on membership.client_id = seg_client.client_id
  join seg_company_ids seg_company on seg_company.id = membership.company_id
  group by membership.client_id
)
select client.id, client.name, client.created_at,
  (select count(*)::integer from public.lists list_row where list_row.client_id = client.id) as list_count,
  (select count(*)::integer from public.client_prospects membership
    where membership.client_id = client.id and membership.status = 'active')
    - coalesce(incomplete_people_counts.prospect_count, 0)
    - coalesce(seg_people_counts.prospect_count, 0) as prospect_count,
  (select count(*)::integer from public.client_prospects membership
    where membership.client_id = client.id and membership.status = 'active' and membership.icp_verified)
    - coalesce(incomplete_people_counts.icp_verified_count, 0)
    - coalesce(seg_people_counts.icp_verified_count, 0) as icp_verified_count,
  (select count(*)::integer from public.client_prospects membership
    where membership.client_id = client.id and membership.status = 'blocked') as blocked_count,
  (select count(*)::integer from public.client_companies membership where membership.client_id = client.id)
    - coalesce(incomplete_company_counts.company_count, 0)
    - coalesce(seg_company_counts.company_count, 0) as company_count,
  client.folder_id,
  client.archived_at
from public.clients client
left join incomplete_people_counts on incomplete_people_counts.client_id = client.id
left join incomplete_company_counts on incomplete_company_counts.client_id = client.id
left join seg_people_counts on seg_people_counts.client_id = client.id
left join seg_company_counts on seg_company_counts.client_id = client.id;

revoke all on public.client_summaries from public, anon, authenticated;
grant select on public.client_summaries to service_role;

do $$
declare v_definition text := pg_get_viewdef('public.client_summaries'::regclass, true);
begin
  if position('incomplete_company_ids AS NOT MATERIALIZED' in v_definition) = 0
     or position('incomplete_prospect_ids AS NOT MATERIALIZED' in v_definition) = 0
     or position('active_client_memberships AS NOT MATERIALIZED' in v_definition) = 0
     or position('seg_clients AS NOT MATERIALIZED' in v_definition) = 0
     or position('seg_company_ids AS NOT MATERIALIZED' in v_definition) = 0 then
    raise exception 'client_summaries did not retain the measured inlined plan shape: %', v_definition;
  end if;
  if has_table_privilege('anon', 'public.client_summaries', 'SELECT')
     or has_table_privilege('authenticated', 'public.client_summaries', 'SELECT')
     or not has_table_privilege('service_role', 'public.client_summaries', 'SELECT') then
    raise exception 'client_summaries grants widened or service access was lost';
  end if;
end $$;
