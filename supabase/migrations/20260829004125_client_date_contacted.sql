-- Date Contacted is the external business name. Keep the legacy physical
-- columns during the rolling deployment so the active release and candidate
-- release can both use the database without downtime.
alter table public.imports alter column prospect_date_added drop not null;
alter table public.imports alter column prospect_date_added drop default;

alter table public.client_prospects alter column date_added drop not null;
alter table public.client_prospects alter column date_added drop default;

create or replace function public.sync_client_prospects_from_lists()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    insert into public.client_prospects (client_id, prospect_id, added_via, date_added)
    select l.client_id, n.prospect_id, 'import', min(i.prospect_date_added)
    from new_rows n
    join public.lists l on l.id = n.list_id
    left join public.imports i on i.id = n.import_id
    where n.prospect_id is not null
    group by l.client_id, n.prospect_id
    on conflict (client_id, prospect_id) do update
      set date_added = case
        when excluded.date_added is null then public.client_prospects.date_added
        when public.client_prospects.date_added is null then excluded.date_added
        else least(public.client_prospects.date_added, excluded.date_added)
      end;
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

-- The current workspace function hydrates the relationship date only when a
-- client is active. Keep that invariant while changing the JSON contract.
create or replace function public.search_prospect_workspace_v12(
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
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  v_has_scope boolean := v_scope <> '{}'::jsonb;
  v_has_people boolean := (btrim(v_search) <> '' or v_filters <> '[]'::jsonb);
  v_unscoped boolean := (not v_has_people and p_client_id is null and not v_has_scope);
  v_prefilter text;
  v_match_clause text;
  v_scope_cte text;
  v_scope_join text;
  v_order text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_total_expr text;
  v_sql text;
begin
  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text);
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  else
    v_scope_cte := '';
    v_scope_join := '';
  end if;

  v_order := format($o$
    case when %1$L = 'name' and lower(%2$L) = 'asc' then lower(full_name) end asc,
    case when %1$L = 'name' and lower(%2$L) = 'desc' then lower(full_name) end desc,
    case when %1$L = 'company' and lower(%2$L) = 'asc' then lower(company_name) end asc,
    case when %1$L = 'company' and lower(%2$L) = 'desc' then lower(company_name) end desc,
    case when %1$L = 'title' and lower(%2$L) = 'asc' then lower(title) end asc,
    case when %1$L = 'title' and lower(%2$L) = 'desc' then lower(title) end desc,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'asc' then last_contacted_at end asc nulls first,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'desc' then last_contacted_at end desc nulls last,
    case when %1$L = 'created_at' and lower(%2$L) = 'asc' then created_at end asc,
    created_at desc, id
  $o$, p_sort, p_direction);

  if not p_with_total then
    v_total_expr := 'null::bigint';
  elsif v_unscoped then
    v_total_expr := $t$(
      select pg_class.reltuples::bigint
      from pg_class
      join pg_namespace on pg_namespace.oid = pg_class.relnamespace
      where pg_namespace.nspname = 'public' and pg_class.relname = 'prospect_index'
    )$t$;
  else
    v_total_expr := '(select count(*) from matched)';
  end if;

  v_sql := format($q$
    with %1$s matched as materialized (
      select pi.id, pi.created_at, pi.full_name, pi.company_name, pi.title, pi.last_contacted_at
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched order by %5$s limit %6$s offset %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by %5$s) as page_order from ordered_page
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %3$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      %8$s
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause, v_order,
       v_limit::text, v_offset::text, v_total_expr);

  return query execute v_sql;
end;
$fn$;

create or replace function public.set_client_date_contacted_v1(
  p_client_id text,
  p_date_contacted date,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_prospect_ids text[] default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_updated integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  -- The browser submits its local calendar day; UTC may still be on the prior
  -- date in positive-offset timezones, so permit the next UTC date as the API does.
  if p_date_contacted is not null and (p_date_contacted < date '1900-01-01' or p_date_contacted > current_date + 1) then
    raise exception 'Date Contacted must be between 1900-01-01 and today.' using errcode = '22007';
  end if;

  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids[1:50000];
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0);
  end if;

  update public.client_prospects cp
  set date_added = p_date_contacted
  where cp.client_id = p_client_id
    and cp.prospect_id = any(v_ids)
    and cp.date_added is distinct from p_date_contacted;
  get diagnostics v_updated = row_count;

  perform public.record_operation(
    'set_date_contacted', p_client_id, p_actor,
    format('Updated Date Contacted for %s prospects', v_updated), v_updated, v_ids);

  return jsonb_build_object('updated', v_updated);
end;
$$;

revoke execute on function public.sync_client_prospects_from_lists() from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.set_client_date_contacted_v1(text, date, text, jsonb, text[], text[], text) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;
grant execute on function public.set_client_date_contacted_v1(text, date, text, jsonb, text[], text[], text) to service_role;

analyze public.client_prospects;

do $smoke$
declare
  v_row record;
begin
  select * into v_row from public.search_prospect_workspace_v12(
    p_client_id => (select id from public.clients limit 1), p_with_total => false);
end;
$smoke$;
