-- ICP validation is a client decision. Keep it off the global company row so
-- one client's validation never changes another client's company workspace.

create table if not exists public.client_company_icp_validations (
  client_id text not null references public.clients(id) on delete cascade,
  company_id text not null references public.companies(id) on delete cascade,
  validated_at timestamptz not null default now(),
  validated_by text not null default '',
  primary key (client_id, company_id)
);

create index if not exists idx_client_company_icp_validations_company
  on public.client_company_icp_validations (company_id, client_id);

alter table public.client_company_icp_validations enable row level security;
revoke all on public.client_company_icp_validations from anon, authenticated;
grant select, insert, update, delete on public.client_company_icp_validations to service_role;

-- Resolve pasted websites and company names against the complete client scope.
-- Exact normalized matching avoids silently selecting similarly named companies.
create or replace function public.resolve_client_company_selection_v1(
  p_client_id text,
  p_domains text[] default null,
  p_names text[] default null,
  p_limit integer default 50000
)
returns table(company_id text)
language sql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
  select c.id
  from public.companies c
  where (
      c.normalized_domain = any(coalesce(p_domains, array[]::text[]))
      or c.normalized_name = any(coalesce(p_names, array[]::text[]))
    )
    and exists (
      select 1
      from public.client_prospects cp
      join public.prospects p on p.id = cp.prospect_id
      where cp.client_id = p_client_id
        and p.company_id = c.id
    )
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 50000), 50000));
$fn$;

-- Company validation is an eligibility umbrella for that client. New client
-- memberships inherit it automatically, and an individual clear cannot make a
-- prospect in a validated company ineligible while the umbrella is active.
create or replace function public.inherit_company_icp_validation_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id text;
begin
  if new.icp_verified then return new; end if;

  select p.company_id into v_company_id
  from public.prospects p
  where p.id = new.prospect_id;

  if v_company_id is not null and exists (
    select 1
    from public.client_company_icp_validations validation
    where validation.client_id = new.client_id
      and validation.company_id = v_company_id
  ) then
    new.icp_verified := true;
    new.verified_at := now();
    new.verified_by := 'company:' || v_company_id;
  end if;

  return new;
end;
$$;

drop trigger if exists inherit_company_icp_validation on public.client_prospects;
create trigger inherit_company_icp_validation
before insert or update of client_id, prospect_id, icp_verified on public.client_prospects
for each row execute function public.inherit_company_icp_validation_v1();

create or replace function public.set_company_icp_validated_v1(
  p_client_id text,
  p_validated boolean,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $fn$
declare
  v_ids text[] := array[]::text[];
  v_updated integer := 0;
  v_prospects_updated integer := 0;
  v_prospect_ids text[] := array[]::text[];
  v_reindex record;
  v_queued integer := 0;
  v_prefilter text;
  v_match_clause text;
  v_excluded_clause text := '';
  v_people_clause text := '';
  v_sql text;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;

  if p_company_ids is not null and cardinality(p_company_ids) > 0 then
    select coalesce(array_agg(distinct requested.company_id order by requested.company_id), array[]::text[])
    into v_ids
    from unnest(p_company_ids[1:50000]) requested(company_id)
    where exists (
      select 1 from public.prospect_index pi
      where pi.company_id = requested.company_id and pi.client_ids @> array[p_client_id]
    );
  else
    v_prefilter := public.company_prefilter_sql(coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb));
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)',
        coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text);

    if p_excluded_ids is not null and cardinality(p_excluded_ids) > 0 then
      v_excluded_clause := format(' and not (c.id = any (%L::text[]))', p_excluded_ids);
    end if;
    if p_people_scope is not null then
      v_people_clause := format(
        ' and c.id in (select company_id from public.people_scope_company_ids_v1(%L, %L::jsonb))',
        p_client_id, p_people_scope::text
      );
    end if;

    v_sql := format($q$
      select coalesce(array_agg(selected.id order by selected.id), array[]::text[])
      from (
        select c.id
        from public.companies c
        where (%1$s)
          and exists (
            select 1 from public.prospect_index pi
            where pi.company_id = c.id and pi.client_ids @> array[%2$L]
          )%3$s%4$s
        order by c.id
        limit 250000
      ) selected
    $q$, v_match_clause, p_client_id, v_people_clause, v_excluded_clause);
    execute v_sql into v_ids;
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'selected', 0);
  end if;

  if p_validated then
    insert into public.client_company_icp_validations (client_id, company_id, validated_at, validated_by)
    select p_client_id, company_id, now(), left(coalesce(p_actor, ''), 200)
    from unnest(v_ids) selected(company_id)
    on conflict (client_id, company_id) do nothing;
    get diagnostics v_updated = row_count;
  else
    delete from public.client_company_icp_validations validation
    where validation.client_id = p_client_id and validation.company_id = any(v_ids);
    get diagnostics v_updated = row_count;
  end if;

  select coalesce(array_agg(cp.prospect_id order by cp.prospect_id), array[]::text[])
  into v_prospect_ids
  from public.client_prospects cp
  join public.prospects p on p.id = cp.prospect_id
  where cp.client_id = p_client_id and p.company_id = any(v_ids);

  if p_validated then
    update public.client_prospects cp
    set icp_verified = true,
      verified_at = now(),
      verified_by = 'company:' || p.company_id
    from public.prospects p
    where p.id = cp.prospect_id
      and cp.client_id = p_client_id
      and p.company_id = any(v_ids)
      and not cp.icp_verified;
  else
    update public.client_prospects cp
    set icp_verified = false,
      verified_at = null,
      verified_by = ''
    from public.prospects p
    where p.id = cp.prospect_id
      and cp.client_id = p_client_id
      and p.company_id = any(v_ids)
      and cp.verified_by = 'company:' || p.company_id;
  end if;
  get diagnostics v_prospects_updated = row_count;

  if cardinality(v_prospect_ids) > 0 then
    select * into v_reindex
    from public.reindex_scope_v1(p_prospect_ids => v_prospect_ids);
    v_queued := coalesce(v_reindex.queued, 0);
  end if;

  return jsonb_build_object(
    'updated', v_updated,
    'selected', cardinality(v_ids),
    'eligibleProspects', cardinality(v_prospect_ids),
    'prospectsUpdated', v_prospects_updated,
    'queued', v_queued
  );
end;
$fn$;

revoke execute on function public.inherit_company_icp_validation_v1() from public, anon, authenticated;
revoke execute on function public.resolve_client_company_selection_v1(text, text[], text[], integer) from public, anon, authenticated;
revoke execute on function public.set_company_icp_validated_v1(text, boolean, text[], text, jsonb, jsonb, text[], text) from public, anon, authenticated;
grant execute on function public.resolve_client_company_selection_v1(text, text[], text[], integer) to service_role;
grant execute on function public.set_company_icp_validated_v1(text, boolean, text[], text, jsonb, jsonb, text[], text) to service_role;

analyze public.client_company_icp_validations;
