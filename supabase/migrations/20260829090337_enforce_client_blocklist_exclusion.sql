begin;

-- A blocklist is a client-level exclusion boundary. Matching records remain in
-- the master database and imported-list history, but are absent from every
-- client-facing People/Company view until the matching blocklist entry is
-- removed. Keeping the membership row makes the action reversible and auditable.

create or replace function public.client_block_reason_v1(
  p_client_id text,
  p_prospect_id text
)
returns text
language sql
stable
security definer
set search_path = public
set statement_timeout = '5s'
as $fn$
  select coalesce(nullif(b.reason, ''), 'Matched client blocklist')
  from public.prospects p
  left join public.companies c on c.id = p.company_id
  join public.client_blocklist b on b.client_id = p_client_id
    and (
      (b.kind = 'domain' and b.value <> '' and b.value = coalesce(c.normalized_domain, lower(c.domain), ''))
      or (b.kind = 'email' and b.value <> '' and b.value in (lower(coalesce(p.work_email, '')), lower(coalesce(p.personal_email, ''))))
    )
  where p.id = p_prospect_id
  order by b.created_at, b.id
  limit 1;
$fn$;

-- Future imports must observe a blocklist that was prepared before the first
-- list. The relationship is recorded as blocked in the same transaction, so it
-- never flashes into the client workspace between import and cleanup.
create or replace function public.sync_client_prospects_from_lists()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    with incoming as (
      select l.client_id, n.prospect_id, min(i.prospect_date_added) as date_added
      from new_rows n
      join public.lists l on l.id = n.list_id
      left join public.imports i on i.id = n.import_id
      where n.prospect_id is not null
      group by l.client_id, n.prospect_id
    )
    insert into public.client_prospects (
      client_id, prospect_id, added_via, date_added,
      status, blocked_reason, blocked_at
    )
    select incoming.client_id, incoming.prospect_id, 'import', incoming.date_added,
      case when block.reason is null then 'active' else 'blocked' end,
      coalesce(block.reason, ''),
      case when block.reason is null then null else now() end
    from incoming
    left join lateral (
      select public.client_block_reason_v1(incoming.client_id, incoming.prospect_id) as reason
    ) block on true
    on conflict (client_id, prospect_id) do update set
      date_added = case
        when excluded.date_added is null then public.client_prospects.date_added
        when public.client_prospects.date_added is null then excluded.date_added
        else least(public.client_prospects.date_added, excluded.date_added)
      end,
      status = case when excluded.status = 'blocked' then 'blocked' else public.client_prospects.status end,
      blocked_reason = case when excluded.status = 'blocked' then excluded.blocked_reason else public.client_prospects.blocked_reason end,
      blocked_at = case when excluded.status = 'blocked' then coalesce(public.client_prospects.blocked_at, excluded.blocked_at) else public.client_prospects.blocked_at end;
  end if;

  if tg_op in ('DELETE', 'UPDATE') then
    delete from public.client_prospects cp
    using (
      select distinct l.client_id, o.prospect_id
      from old_rows o
      join public.lists l on l.id = o.list_id
      where o.prospect_id is not null
    ) removed
    where cp.client_id = removed.client_id
      and cp.prospect_id = removed.prospect_id
      and cp.added_via = 'import'
      and not exists (
        select 1
        from public.list_memberships lm
        join public.lists l2 on l2.id = lm.list_id
        where l2.client_id = cp.client_id and lm.prospect_id = cp.prospect_id
      );
  end if;

  return null;
end;
$$;

-- Only active memberships are projected into client_ids. Client workspace
-- queries already use that indexed array, so blocklist changes become immediate
-- and retain the same scalable query plan.
create or replace function public.reindex_prospects(p_ids text[])
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare affected integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;

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
      (select count(*)::integer from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'active') as client_count,
      coalesce(array_agg(distinct l.name order by l.name) filter (where l.id is not null), '{}'::text[]) as list_names,
      coalesce((select array_agg(distinct cl2.name order by cl2.name)
        from public.client_prospects cp join public.clients cl2 on cl2.id = cp.client_id
        where cp.prospect_id = p.id and cp.status = 'active'), '{}'::text[]) as client_names,
      coalesce(array_agg(distinct l.id order by l.id) filter (where l.id is not null), '{}'::text[]) as list_ids,
      coalesce((select array_agg(distinct cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'active'), '{}'::text[]) as client_ids,
      coalesce((select array_agg(cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'active' and cp.icp_verified), '{}'::text[]) as icp_verified_client_ids,
      coalesce((select array_agg(cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'blocked'), '{}'::text[]) as blocked_client_ids,
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
      coalesce((select jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'color', pt.color, 'clientId', pt.client_id) order by pt.name)
        from public.prospect_tag_links ptl join public.prospect_tags pt on pt.id = ptl.tag_id
        where ptl.prospect_id = p.id), '[]'::jsonb) as tags,
      coalesce((select string_agg(pt.name, ' ' order by pt.name)
        from public.prospect_tag_links ptl join public.prospect_tags pt on pt.id = ptl.tag_id
        where ptl.prospect_id = p.id), '') as tag_text,
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
      last_contacted_at, contact_count, icp_verified_client_ids, blocked_client_ids, search_text
    )
    select
      c.id, c.first_name, c.last_name, c.full_name, c.work_email, c.personal_email, c.mobile_number,
      c.linkedin_url, c.title, c.seniority, c.department, c.city, c.state, c.country, c.location, c.company_id,
      c.company_name, c.company_domain, c.all_data, c.created_at, c.updated_at, c.list_count, c.client_count,
      c.list_names, c.client_names, c.list_ids, c.client_ids, c.list_memberships, c.esp, c.email_provider_type,
      c.mx_records, c.mx_status, c.mx_checked_at, c.keywords, c.employee_count_min, c.employee_count_max,
      c.company_location, c.company_city, c.company_state, c.company_country, c.tags, c.tag_text,
      c.last_contacted_at, c.contact_count, c.icp_verified_client_ids, c.blocked_client_ids,
      concat_ws(' ', c.full_name, c.work_email, c.personal_email, c.mobile_number,
        c.title, c.seniority, c.department, array_to_string(c.keywords, ' '),
        c.company_name, c.company_domain, c.linkedin_url, c.location, c.city, c.state, c.country,
        c.company_location, c.company_city, c.company_state, c.company_country, c.esp, c.email_provider_type,
        array_to_string(c.list_names, ' '), array_to_string(c.client_names, ' '), c.tag_text)
    from computed c
    on conflict (id) do update set
      first_name = excluded.first_name, last_name = excluded.last_name, full_name = excluded.full_name,
      work_email = excluded.work_email, personal_email = excluded.personal_email, mobile_number = excluded.mobile_number,
      linkedin_url = excluded.linkedin_url, title = excluded.title, seniority = excluded.seniority,
      department = excluded.department, city = excluded.city, state = excluded.state, country = excluded.country,
      location = excluded.location, company_id = excluded.company_id, company_name = excluded.company_name,
      company_domain = excluded.company_domain, all_data = excluded.all_data, created_at = excluded.created_at,
      updated_at = excluded.updated_at, list_count = excluded.list_count, client_count = excluded.client_count,
      list_names = excluded.list_names, client_names = excluded.client_names, list_ids = excluded.list_ids,
      client_ids = excluded.client_ids, list_memberships = excluded.list_memberships, esp = excluded.esp,
      email_provider_type = excluded.email_provider_type, mx_records = excluded.mx_records,
      mx_status = excluded.mx_status, mx_checked_at = excluded.mx_checked_at, keywords = excluded.keywords,
      employee_count_min = excluded.employee_count_min, employee_count_max = excluded.employee_count_max,
      company_location = excluded.company_location, company_city = excluded.company_city,
      company_state = excluded.company_state, company_country = excluded.company_country,
      tags = excluded.tags, tag_text = excluded.tag_text, last_contacted_at = excluded.last_contacted_at,
      contact_count = excluded.contact_count, icp_verified_client_ids = excluded.icp_verified_client_ids,
      blocked_client_ids = excluded.blocked_client_ids, search_text = excluded.search_text
    returning 1
  )
  select count(*)::integer into affected from upserted;
  return affected;
end;
$$;

-- Repair previously blocked memberships without a full 675k-row reindex.
update public.prospect_index pi set
  client_ids = coalesce((select array_agg(distinct cp.client_id order by cp.client_id)
    from public.client_prospects cp where cp.prospect_id = pi.id and cp.status = 'active'), '{}'::text[]),
  client_names = coalesce((select array_agg(distinct c.name order by c.name)
    from public.client_prospects cp join public.clients c on c.id = cp.client_id
    where cp.prospect_id = pi.id and cp.status = 'active'), '{}'::text[]),
  client_count = (select count(*)::integer from public.client_prospects cp where cp.prospect_id = pi.id and cp.status = 'active'),
  icp_verified_client_ids = coalesce((select array_agg(cp.client_id order by cp.client_id)
    from public.client_prospects cp where cp.prospect_id = pi.id and cp.status = 'active' and cp.icp_verified), '{}'::text[]),
  blocked_client_ids = coalesce((select array_agg(cp.client_id order by cp.client_id)
    from public.client_prospects cp where cp.prospect_id = pi.id and cp.status = 'blocked'), '{}'::text[])
where exists (select 1 from public.client_prospects blocked where blocked.prospect_id = pi.id and blocked.status = 'blocked');

create or replace view public.client_summaries as
select c.id, c.name, c.created_at,
  (select count(*)::integer from public.lists l where l.client_id = c.id) as list_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.status = 'active') as prospect_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.status = 'active' and cp.icp_verified) as icp_verified_count,
  (select count(*)::integer from public.client_prospects cp where cp.client_id = c.id and cp.status = 'blocked') as blocked_count
from public.clients c;

-- Keep the optimized two-plan company workspace, while excluding automatic
-- company memberships that no longer have an active prospect. Companies pushed
-- explicitly remain visible even when they have no prospects.
create or replace function public.client_company_workspace_v2(
  p_client_id text, p_search text default '', p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null, p_limit integer default 50, p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
language plpgsql stable security definer
set search_path = public
set statement_timeout = '20s'
as $function$
declare
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text; v_counts_cte text; v_counts_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0)); v_sql text;
begin
  if v_unfiltered then
    v_match_clause := 'true';
    v_counts_cte := format($c$client_counts as (
        select pi.company_id, count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), coverage_counts as (
        select cc.company_id, count(*)::integer as client_count
        from public.client_companies cc group by cc.company_id
      ), $c$, p_client_id);
    v_counts_join := 'left join client_counts counts on counts.company_id = c.id'
      || ' left join coverage_counts coverage on coverage.company_id = c.id';
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
    v_counts_cte := '';
    v_counts_join := format($j$left join lateral (
        select count(*)::integer as prospect_count from public.prospect_index pi
        where pi.company_id = c.id and pi.client_ids @> array[%L]
      ) counts on true
      left join lateral (
        select count(*)::integer as client_count from public.client_companies all_memberships
        where all_memberships.company_id = c.id
      ) coverage on true$j$, p_client_id);
  end if;

  v_sql := format($q$
    with %6$s matched as materialized (
      select c.id, c.name, c.domain, c.created_at,
        coalesce(counts.prospect_count, 0)::integer as prospect_count,
        coalesce(coverage.client_count, 0)::integer as client_count
      from public.client_companies membership
      join public.companies c on c.id = membership.company_id
      %7$s
      where membership.client_id = %1$L
        and (membership.added_by not in ('membership-backfill', 'prospect-membership', 'prospect-company-change')
          or coalesce(counts.prospect_count, 0) > 0)
        and (%2$s)
        and (%3$L::jsonb is null or c.id in (select company_id from public.people_scope_company_ids_v1(%1$L, %3$L::jsonb)))
    ), page_rows as (
      select * from matched order by prospect_count desc, lower(name), id limit %5$s offset %4$s
    )
    select coalesce((select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id) from page_rows), '[]'::jsonb),
      (select count(*) from matched),
      (select count(*) from matched where matched.prospect_count > 0),
      (select coalesce(sum(matched.prospect_count), 0) from matched)
  $q$, p_client_id, v_match_clause, case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join);
  return query execute v_sql;
end;
$function$;

create or replace function public.resolve_client_company_selection_v1(
  p_client_id text, p_domains text[] default null, p_names text[] default null, p_limit integer default 50000
)
returns table(company_id text)
language sql stable security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
  select c.id
  from public.client_companies membership
  join public.companies c on c.id = membership.company_id
  where membership.client_id = p_client_id
    and (membership.added_by not in ('membership-backfill', 'prospect-membership', 'prospect-company-change')
      or exists (select 1 from public.prospect_index pi where pi.company_id = c.id and pi.client_ids @> array[p_client_id]))
    and (c.normalized_domain = any(coalesce(p_domains, array[]::text[]))
      or c.normalized_name = any(coalesce(p_names, array[]::text[])))
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 50000), 50000));
$fn$;

create or replace function public.resolve_company_action_selection_v1(
  p_client_id text default null, p_company_ids text[] default null,
  p_search text default '', p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null, p_excluded_ids text[] default null,
  p_limit integer default 250000
)
returns table(company_id text)
language sql stable security definer
set search_path = public
set statement_timeout = '30s'
as $fn$
  select c.id
  from public.companies c
  where (p_client_id is null or exists (
      select 1 from public.client_companies membership
      where membership.client_id = p_client_id and membership.company_id = c.id
        and (membership.added_by not in ('membership-backfill', 'prospect-membership', 'prospect-company-change')
          or exists (select 1 from public.prospect_index pi where pi.company_id = c.id and pi.client_ids @> array[p_client_id]))
    ))
    and ((p_company_ids is not null and c.id = any(p_company_ids[1:50000]))
      or (p_company_ids is null and public.company_matches_filters_v1(c, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb))))
    and (p_people_scope is null or c.id in (select company_id from public.people_scope_company_ids_v1(p_client_id, p_people_scope)))
    and not (c.id = any(coalesce(p_excluded_ids, array[]::text[])))
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 250000), 250000));
$fn$;

create or replace function public.push_companies_to_client_v1(
  p_client_id text, p_company_ids text[] default null, p_search text default '',
  p_filters jsonb default '[]'::jsonb, p_people_scope jsonb default null,
  p_excluded_ids text[] default null, p_actor text default ''
)
returns jsonb
language plpgsql security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare v_ids text[] := array[]::text[]; v_added integer := 0; v_existing integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(null, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);
  select count(*)::integer into v_existing from public.client_companies
  where client_id = p_client_id and company_id = any(v_ids);
  insert into public.client_companies (client_id, company_id, added_by)
  select p_client_id, company_id, 'push:' || left(coalesce(p_actor, ''), 195)
  from unnest(v_ids) selected(company_id)
  on conflict (client_id, company_id) do update set added_by = excluded.added_by;
  v_added := greatest(0, cardinality(v_ids) - v_existing);
  return jsonb_build_object('selected', cardinality(v_ids), 'added', v_added, 'alreadyPresent', v_existing);
end;
$$;

create or replace function public.client_company_prospects(
  p_client_id text, p_company_id text, p_limit integer default 50, p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql stable security definer
set search_path = public
as $$
  with matched as materialized (
    select ps.*
    from public.client_prospects cp
    join public.prospect_summaries ps on ps.id = cp.prospect_id
    where cp.client_id = p_client_id and cp.status = 'active' and ps.company_id = p_company_id
  ), page_rows as (
    select * from matched order by full_name
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows)) from page_rows), '[]'::jsonb),
    (select count(*) from matched);
$$;

revoke execute on function public.client_block_reason_v1(text, text) from public, anon, authenticated;
revoke execute on function public.sync_client_prospects_from_lists() from public, anon, authenticated;
revoke execute on function public.reindex_prospects(text[]) from public, anon, authenticated;
revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) from public, anon, authenticated;
revoke execute on function public.resolve_client_company_selection_v1(text, text[], text[], integer) from public, anon, authenticated;
revoke execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) from public, anon, authenticated;
revoke execute on function public.push_companies_to_client_v1(text, text[], text, jsonb, jsonb, text[], text) from public, anon, authenticated;
revoke execute on function public.client_company_prospects(text, text, integer, integer) from public, anon, authenticated;
revoke all on public.client_summaries from anon, authenticated;

grant execute on function public.client_block_reason_v1(text, text) to service_role;
grant execute on function public.reindex_prospects(text[]) to service_role;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) to service_role;
grant execute on function public.resolve_client_company_selection_v1(text, text[], text[], integer) to service_role;
grant execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) to service_role;
grant execute on function public.push_companies_to_client_v1(text, text[], text, jsonb, jsonb, text[], text) to service_role;
grant execute on function public.client_company_prospects(text, text, integer, integer) to service_role;

analyze public.client_prospects;
analyze public.client_companies;
analyze public.prospect_index;

commit;
