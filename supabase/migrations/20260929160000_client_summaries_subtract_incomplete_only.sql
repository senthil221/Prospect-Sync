-- Restore the client directory's indexed baseline counts after the incomplete
-- partition was introduced. The first segregation view joined every client
-- membership to prospects and companies before grouping; production's large
-- Unassigned client made that exceed the interactive statement timeout.
--
-- Keep the pre-existing index-only correlated counts for the full membership
-- totals. Only the incomplete slice pays the prospect/company joins, starting
-- from the two partial blank-profile indexes. Exact visible counts are the
-- indexed totals minus that slice. This changes only the view; memberships,
-- profile data, RLS, and mutation functions are untouched.
--
-- MEASURED read-only on production 2026-09-29: the deployed global join cost
-- ~609k and timed out after scanning ~512k memberships and ~487k prospects per
-- worker. A nested-loop subtraction was 5.50s because stale blank-index stats
-- caused ~90k random membership lookups. Materializing the narrow active
-- membership columns forces the stable hash shape below: 2.97s warm for
-- 870,839 active memberships and 81,520 incomplete prospect ids. It spills
-- about 60MB to temporary storage, an accepted emergency tradeoff that is
-- bounded to this directory read and avoids a risky trigger-maintained cache.

set local lock_timeout = '5s';

create or replace view public.client_summaries as
with incomplete_company_ids as materialized (
  select company.id
  from public.companies company
  where btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
    and btrim(coalesce(company.short_description, '')) = ''
), incomplete_prospect_ids as materialized (
  select prospect.id
  from incomplete_company_ids incomplete_company
  join public.prospects prospect on prospect.company_id = incomplete_company.id
), active_client_memberships as materialized (
  select membership.client_id, membership.prospect_id, membership.icp_verified
  from public.client_prospects membership
  where membership.status = 'active'
), incomplete_people_counts as (
  select membership.client_id,
    count(*)::integer as prospect_count,
    count(*) filter (where membership.icp_verified)::integer as icp_verified_count
  from active_client_memberships membership
  join incomplete_prospect_ids incomplete_prospect
    on incomplete_prospect.id = membership.prospect_id
  group by membership.client_id
), incomplete_company_counts as (
  select membership.client_id, count(*)::integer as company_count
  from incomplete_company_ids incomplete_company
  join public.client_companies membership on membership.company_id = incomplete_company.id
  group by membership.client_id
)
select client.id, client.name, client.created_at,
  (select count(*)::integer
   from public.lists list_row
   where list_row.client_id = client.id) as list_count,
  ((select count(*)::integer
    from public.client_prospects membership
    where membership.client_id = client.id and membership.status = 'active')
    - coalesce(incomplete_people_counts.prospect_count, 0))::integer as prospect_count,
  ((select count(*)::integer
    from public.client_prospects membership
    where membership.client_id = client.id
      and membership.status = 'active' and membership.icp_verified)
    - coalesce(incomplete_people_counts.icp_verified_count, 0))::integer as icp_verified_count,
  (select count(*)::integer
   from public.client_prospects membership
   where membership.client_id = client.id and membership.status = 'blocked') as blocked_count,
  ((select count(*)::integer
    from public.client_companies membership
    where membership.client_id = client.id)
    - coalesce(incomplete_company_counts.company_count, 0))::integer as company_count,
  client.folder_id, client.archived_at
from public.clients client
left join incomplete_people_counts
  on incomplete_people_counts.client_id = client.id
left join incomplete_company_counts
  on incomplete_company_counts.client_id = client.id;

revoke all on public.client_summaries from public, anon, authenticated;
grant select on public.client_summaries to service_role;

do $assert$
declare
  v_definition text := pg_get_viewdef('public.client_summaries'::regclass, true);
begin
  if position('incomplete_company_ids AS MATERIALIZED' in v_definition) = 0
    or position('incomplete_prospect_ids AS MATERIALIZED' in v_definition) = 0
    or position('active_client_memberships AS MATERIALIZED' in v_definition) = 0
    or position('client_prospects membership' in v_definition) = 0
    or position('incomplete_people_counts.prospect_count' in v_definition) = 0
    or position('incomplete_company_counts.company_count' in v_definition) = 0 then
    raise exception 'client_summaries did not retain indexed totals minus incomplete slices: %', v_definition;
  end if;
  if has_table_privilege('anon', 'public.client_summaries', 'SELECT')
    or has_table_privilege('authenticated', 'public.client_summaries', 'SELECT')
    or not has_table_privilege('service_role', 'public.client_summaries', 'SELECT') then
    raise exception 'client_summaries grants widened or service access was lost';
  end if;
end;
$assert$;
