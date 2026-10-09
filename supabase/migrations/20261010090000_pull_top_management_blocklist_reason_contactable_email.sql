-- Three small asks from 2026-10-10:
--
-- 1. PULL PEOPLE BY TOP MANAGEMENT. pull_master_people_v1 accepts the
--    __title_top_management filter (20261008110000) beside job title,
--    management level and department.
--
-- 2. BLOCKLIST FILTER BY REASON. The blocklist list, count, export, bulk reason
--    change and bulk remove all select through client_blocklist_selection_v1.
--    Rather than add a parameter to five functions and their routes, the
--    existing p_kind text carries the reason after a bar: 'domain|ICP Invalid',
--    '|Campaign Reply', '|(none)' for entries saved with no reason. A plain
--    'domain' / 'email' / '' means what it always did.
--
-- 3. CONTACTABLE NEEDS AN EMAIL. A person counts as contactable for a client
--    only with a work email (740,799 of 845,334 people have one; nobody has
--    only a personal email), so "Not contactable" now also lists people with
--    no email. Compiler and row matcher change together.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

do $patch$
declare
  v_definition text;
  v_anchor text;
begin
  -- 1. Pull.
  select pg_get_functiondef('public.pull_master_people_v1(text,text[],text,jsonb,jsonb,text[],jsonb,boolean,text,text)'::regprocedure) into v_definition;
  if position('__title_top_management' in v_definition) = 0 then
    v_anchor := $old$('__title', '__title_seniority', '__title_seniority_tier', '__title_department', '__title_sub_department')$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'pull_master_people_v1: field list anchor is not unique';
    end if;
    v_definition := replace(v_definition, v_anchor,
      $new$('__title', '__title_seniority', '__title_seniority_tier', '__title_department', '__title_sub_department',
          '__title_top_management')$new$);
    execute replace(v_definition,
      $old$'A pull filters people by job title, management level and department only.'$old$,
      $new$'A pull filters people by job title, management level, top management and department only.'$new$);
  end if;

  -- 3. Contactable, compiled.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if position('Contactable needs a work email' in v_definition) = 0 then
    v_anchor := $old$          where cp.prospect_id = pi.id and cp.status = 'active' and cp.client_id = any (%L::text[])$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1: Contactable anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$          where cp.prospect_id = pi.id and cp.status = 'active' and cp.client_id = any (%L::text[])
            /* Contactable needs a work email (20261010090000). */ and btrim(coalesce(pi.work_email, '')) <> ''$new$);
  end if;

  -- 3. Contactable, row matcher.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  if position('Contactable needs a work email' in v_definition) = 0 then
    v_anchor := $old$                  where cp.prospect_id = (p_row).id and cp.status = 'active'$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_index_matches_v1: Contactable anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$                  where cp.prospect_id = (p_row).id and cp.status = 'active'
                    /* Contactable needs a work email (20261010090000). */ and btrim(coalesce((p_row).work_email, '')) <> ''$new$);
  end if;
end;
$patch$;

-- 2. Blocklist selection by reason.
create or replace function public.client_blocklist_selection_v1(
  p_client_id text, p_ids text[] default null::text[], p_all_matching boolean default false,
  p_search text default ''::text, p_kind text default ''::text, p_date_from date default null::date,
  p_date_to date default null::date, p_excluded_ids text[] default null::text[],
  p_selected_before timestamp with time zone default null::timestamp with time zone, p_limit integer default 250000)
returns table(entry_id text)
language sql
stable security definer
set search_path to 'public'
set statement_timeout to '30s'
as $$
  -- p_kind is '<kind>' or '<kind>|<reason>' (20261010090000); '(none)' is the
  -- reason of an entry saved without one.
  with f as (
    select split_part(coalesce(p_kind, ''), '|', 1) as kind,
           case when position('|' in coalesce(p_kind, '')) > 0
                then nullif(split_part(p_kind, '|', 2), '') end as reason
  )
  select b.id
  from public.client_blocklist b, f
  where b.client_id = p_client_id
    and (
      (not coalesce(p_all_matching, false) and p_ids is not null and b.id = any(p_ids))
      or (coalesce(p_all_matching, false)
        and (btrim(coalesce(p_search, '')) = '' or b.value ilike '%' || p_search || '%')
        and (btrim(f.kind) = '' or b.kind = f.kind)
        and (f.reason is null or b.reason = case f.reason when '(none)' then '' else f.reason end)
        and (p_date_from is null or b.created_at >= (p_date_from::text || 'T00:00:00Z')::timestamptz)
        and (p_date_to is null or b.created_at < ((p_date_to + 1)::text || 'T00:00:00Z')::timestamptz)
        and (p_selected_before is null or b.created_at <= p_selected_before))
    )
    and not (b.id = any(coalesce(p_excluded_ids, array[]::text[])))
  order by b.created_at desc, b.id
  limit greatest(1, least(coalesce(p_limit, 250001), 250001));
$$;

revoke execute on function public.client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamp with time zone, integer) from public, anon, authenticated;
grant execute on function public.client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamp with time zone, integer) to service_role;

-- Proof, read-only.
do $proof$
declare
  v_client text;
  v_all bigint;
  v_icp bigint;
  v_expected bigint;
  v_filters jsonb;
  v_compiled bigint;
  v_matched bigint;
begin
  select client_id into v_client from public.client_blocklist where reason = 'ICP Invalid' group by 1 order by count(*) desc limit 1;
  if v_client is not null then
    select count(*) into v_all from public.client_blocklist_selection_v1(v_client, null, true, '', '', null, null, null, null, 250001);
    select count(*) into v_icp from public.client_blocklist_selection_v1(v_client, null, true, '', 'domain|ICP Invalid', null, null, null, null, 250001);
    select count(*) into v_expected from public.client_blocklist where client_id = v_client and kind = 'domain' and reason = 'ICP Invalid';
    if v_icp <> least(v_expected, 250001) or v_all < v_icp then
      raise exception 'Blocklist reason proof: % ICP Invalid selected, % expected, % in all', v_icp, v_expected, v_all;
    end if;
  end if;

  if position('__title_top_management' in pg_get_functiondef('public.pull_master_people_v1(text,text[],text,jsonb,jsonb,text[],jsonb,boolean,text,text)'::regprocedure)) = 0 then
    raise exception 'Pull proof: top management is not accepted';
  end if;

  select client_id into v_client from public.client_prospects group by 1 order by count(*) desc limit 1;
  if v_client is not null then
    v_filters := jsonb_build_array(jsonb_build_object('field', '__contactable', 'operator', 'contains', 'values', jsonb_build_array(v_client)));
    execute format('select count(*) filter (where %s), count(*) filter (where public.prospect_index_matches_v1(pi, '''', %L::jsonb))
                      from (select * from public.prospect_index pi where %L = any(pi.client_ids) limit 20000) pi',
      public.prospect_filter_sql_v1('', v_filters), v_filters, v_client) into v_compiled, v_matched;
    if v_compiled <> v_matched then
      raise exception 'Contactable proof: compiled % vs matcher %', v_compiled, v_matched;
    end if;
    execute format('select count(*) from (select * from public.prospect_index pi where %L = any(pi.client_ids) limit 20000) pi
                     where (%s) and btrim(coalesce(pi.work_email, '''')) = ''''',
      v_client, public.prospect_filter_sql_v1('', v_filters)) into v_compiled;
    if v_compiled <> 0 then
      raise exception 'Contactable proof: % contactable people have no email', v_compiled;
    end if;
  end if;
  raise notice 'Pull / blocklist reason / contactable proof passed.';
end;
$proof$;
