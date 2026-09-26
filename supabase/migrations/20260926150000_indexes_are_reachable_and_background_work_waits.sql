-- Queries reach their indexes, and whole-database background work waits for
-- the data to settle.
--
-- EVIDENCE. Slow-plan logging (auto_explain >2s, nested, on the app role since
-- 2026-09-23) recorded 206 slow plans over 72 hours in 46 shapes. Two causes
-- dominate, and both are fixed here:
--
-- 1. A predicate shape the planner cannot turn into an index lookup.
--
--    a. search_prospect_workspace_cursor_v1 (20260926083856) expresses its
--       position as
--          created_at < X or (created_at = X and id > Y)
--       With the (created_at DESC, id) index, that OR is only ever a Filter:
--       measured on production for a cursor 400,000 rows deep, the scan
--       removed 400,001 rows to return 50 - exactly the work OFFSET does,
--       which is what a cursor exists to avoid. Adding the implied bound
--       created_at <= X as its own conjunct lets it become the Index Cond:
--       measured 55 ms -> 0.4 ms, 16 rows discarded instead of 400,001. The
--       rows returned are identical - the new conjunct is implied by the OR.
--
--    b. prospect_title_taxonomy_v1 and title_class_filter_values_v1 are
--       LANGUAGE sql with an optional client:
--          (p_client_id is null or pi.client_ids @> array[p_client_id])
--       A SQL function's parameters are plan-time unknowns, so the OR cannot
--       use idx_prospect_index_client_ids and every client-scoped call scanned
--       all 827,000 rows: 25.4 s in the log for one client's taxonomy. (The
--       filter-values form, p_client_id = any(client_ids), cannot use the GIN
--       index even without the OR.) Both now choose their predicate before
--       planning, so a client call reads only that client's rows and an
--       unscoped call reads everything, as before.
--
-- 2. Whole-database summaries recomputed during imports.
--
--    refresh_dashboard_snapshots_v1 recomputes whenever the data version has
--    moved. Every import batch moves it, so during an import the worker kept
--    recomputing: 12 runs of up to 130 s (709 s in 72 h, the largest single
--    consumer in the log; data quality alone is 44 s of full scans) - each
--    thrown away seconds later by the next batch, and each evicting the cache
--    the interactive pages were reading from. It now waits until the versions
--    have been unchanged for 4 minutes (the worker checks every 5), so it runs
--    once after an import instead of throughout it. A snapshot is never left
--    more than 60 minutes behind a moving database, so a day of continuous
--    imports still refreshes hourly. The tabs already show "computed at" and
--    whether the numbers are current, so nothing presents stale data as fresh.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

-- 1a. The cursor seeks.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.search_prospect_workspace_cursor_v1(text,jsonb,integer,text,timestamptz,text,boolean,jsonb)'::regprocedure);
  v_old constant text :=
E'        and (%3$L::timestamptz is null
          or pi.created_at < %3$L::timestamptz
          or (pi.created_at = %3$L::timestamptz and pi.id > %4$L))';
  v_new constant text :=
E'        -- created_at <= X is implied by the OR below; as its own conjunct it
        -- is what lets the index seek (20260926150000).
        and (%3$L::timestamptz is null
          or (pi.created_at <= %3$L::timestamptz
            and (pi.created_at < %3$L::timestamptz
              or (pi.created_at = %3$L::timestamptz and pi.id > %4$L))))';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'search_prospect_workspace_cursor_v1 no longer has the cursor predicate this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end $BODY$;

revoke execute on function public.search_prospect_workspace_cursor_v1(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_cursor_v1(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) to service_role;

-- 1b. The client-scoped taxonomy reads the client's rows. The body is the one
-- from before, unchanged apart from the scope predicate, which is chosen here
-- and inlined so the planner sees either nothing or an indexable @>.
create or replace function public.prospect_title_taxonomy_v1(p_client_id text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
declare
  v_scope text := case
    when nullif(btrim(coalesce(p_client_id, '')), '') is null then 'true'
    else format('pi.client_ids @> array[%L]', p_client_id)
  end;
  v_result jsonb;
begin
  execute format($sql$
  with counted as materialized (
    select
      grouping(pi.title_seniority) as g_seniority,
      grouping(pi.title_department) as g_department,
      grouping(pi.title_sub_department) as g_sub,
      pi.title_seniority, pi.title_department, pi.title_sub_department,
      count(*) as n
    from public.prospect_index pi
    where %s
    group by grouping sets ((pi.title_seniority), (pi.title_department), (pi.title_sub_department))
  ),
  tier_counts as (
    select btrim(coalesce(title_seniority, '')) as key, sum(n) as n
    from counted where g_seniority = 0 group by 1
  ),
  department_counts as (
    select btrim(coalesce(title_department, '')) as key, sum(n) as n
    from counted where g_department = 0 group by 1
  ),
  sub_counts as (
    select btrim(coalesce(title_sub_department, '')) as key, sum(n) as n
    from counted where g_sub = 0 group by 1
  ),
  tiers as (
    select coalesce(jsonb_agg(jsonb_build_object('value', t.tier, 'count', coalesce(c.n, 0)) order by t.tier), '[]'::jsonb) as value
    from (select distinct tier from public.title_seniority_keywords where tier <> 'none') t
    left join tier_counts c on c.key = t.tier
  ),
  subs_by_department as (
    select k.department,
      jsonb_agg(jsonb_build_object('name', k.sub_department, 'count', coalesce(s.n, 0)) order by k.sub_department) as subs
    from (select distinct department, sub_department from public.title_department_keywords where btrim(coalesce(sub_department, '')) <> '') k
    left join sub_counts s on s.key = k.sub_department
    group by k.department
  ),
  departments as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'name', d.department,
      'count', coalesce(c.n, 0),
      'subs', coalesce(sd.subs, '[]'::jsonb)
    ) order by d.department), '[]'::jsonb) as value
    from (select distinct department from public.title_department_keywords) d
    left join department_counts c on c.key = d.department
    left join subs_by_department sd on sd.department = d.department
  )
  select jsonb_build_object(
    'tiers', (select value from tiers),
    'departments', (select value from departments),
    'undefinedSeniority', (select coalesce(n, 0) from tier_counts where key = ''),
    'undefinedDepartment', (select coalesce(n, 0) from department_counts where key = '')
  )
  $sql$, v_scope) into v_result;
  return v_result;
end;
$function$;
revoke execute on function public.prospect_title_taxonomy_v1(text) from public, anon, authenticated;
grant execute on function public.prospect_title_taxonomy_v1(text) to service_role;

create or replace function public.title_class_filter_values_v1(
  p_field text,
  p_search text default '',
  p_client_id text default null,
  p_limit integer default 50
)
returns table(value text, match_count bigint)
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
declare
  v_column text := case p_field
    when '__title_department' then 'pi.title_department'
    when '__title_sub_department' then 'pi.title_sub_department'
    when '__title_seniority_tier' then 'pi.title_seniority'
  end;
  v_scope text := case
    when p_client_id is null then 'true'
    else format('pi.client_ids @> array[%L]', p_client_id)
  end;
  v_needle text := btrim(coalesce(p_search, ''));
begin
  -- An unknown field matched nothing before (its candidate was ''); it still does.
  if v_column is null then
    return;
  end if;
  return query execute format($sql$
    select %1$s as value, count(*)::bigint as match_count
    from public.prospect_index pi
    where %1$s <> '' and %2$s and (%3$L = '' or %1$s ilike '%%' || %3$L || '%%')
    group by %1$s
    order by count(*) desc, %1$s
    limit %4$s
  $sql$, v_column, v_scope, v_needle, greatest(1, least(coalesce(p_limit, 50), 100)));
end;
$function$;
revoke execute on function public.title_class_filter_values_v1(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.title_class_filter_values_v1(text, text, text, integer) to service_role;

-- 2. The snapshot refresh waits for the data to settle.
create table if not exists prospect_operations.snapshot_settle (
  singleton boolean primary key default true check (singleton),
  observed_versions jsonb not null,
  observed_at timestamptz not null default now()
);
revoke all on prospect_operations.snapshot_settle from public, anon, authenticated;

create or replace function prospect_operations.refresh_dashboard_snapshots_v1()
returns integer
language plpgsql
volatile
security definer
set search_path to 'public'
set statement_timeout to '300s'
as $function$
declare
  v_versions jsonb := public.data_versions_v1(array['prospect', 'company']);
  v_refreshed integer := 0;
  v_started timestamptz;
  v_payload jsonb;
  v_key text;
  v_observed prospect_operations.snapshot_settle%rowtype;
  v_oldest timestamptz;
begin
  -- Settle first (20260926150000). A version seen for the first time starts
  -- the clock and refreshes nothing - unless a snapshot is already an hour
  -- behind, so continuous imports cannot starve the tabs forever.
  select * into v_observed from prospect_operations.snapshot_settle where singleton;
  if v_observed.observed_versions is distinct from v_versions then
    insert into prospect_operations.snapshot_settle (singleton, observed_versions, observed_at)
    values (true, v_versions, now())
    on conflict (singleton) do update
      set observed_versions = excluded.observed_versions, observed_at = excluded.observed_at;
    select min(s.computed_at) into v_oldest from public.dashboard_snapshot s
    where s.key in ('dataQuality', 'indexDrift', 'titleTaxonomy');
    if v_oldest is not null and v_oldest > now() - interval '60 minutes' then
      return 0;
    end if;
  elsif v_observed.observed_at > now() - interval '4 minutes' then
    return 0;
  end if;

  foreach v_key in array array['dataQuality', 'indexDrift', 'titleTaxonomy'] loop
    -- Same version means the stored answer is the answer.
    if exists (
      select 1 from public.dashboard_snapshot s
      where s.key = v_key and s.data_version = v_versions
    ) then
      continue;
    end if;

    v_started := clock_timestamp();
    v_payload := case v_key
      when 'dataQuality' then public.data_quality_overview()
      when 'indexDrift' then public.prospect_index_drift()
      when 'titleTaxonomy' then public.prospect_title_taxonomy_v1(null)
    end;

    insert into public.dashboard_snapshot (key, payload, data_version, computed_at, duration_ms)
    values (v_key, coalesce(v_payload, '{}'::jsonb), v_versions, now(),
            (extract(epoch from clock_timestamp() - v_started) * 1000)::integer)
    on conflict (key) do update
      set payload = excluded.payload,
          data_version = excluded.data_version,
          computed_at = excluded.computed_at,
          duration_ms = excluded.duration_ms;
    v_refreshed := v_refreshed + 1;
  end loop;

  return v_refreshed;
end;
$function$;
revoke execute on function prospect_operations.refresh_dashboard_snapshots_v1() from public, anon, authenticated;
grant execute on function prospect_operations.refresh_dashboard_snapshots_v1() to prospect_operator, service_role;

-- ---------------------------------------------------------------------------
-- Proofs, on real rows.
set local plan_cache_mode = force_custom_plan;
do $$
declare
  v_client text;
  v_old jsonb;
  v_new jsonb;
  v_field text;
  v_old_values text;
  v_new_values text;
  v_c record;
  v_got text[];
  v_want text[];
begin
  -- The taxonomy and the filter values are the same answers as before, for
  -- the whole database and for a real client.
  select client_id into v_client from public.client_prospects
  where client_id <> 'prospect-sync-no-client' group by client_id order by count(*) desc limit 1;

  foreach v_field in array array['__title_department', '__title_sub_department', '__title_seniority_tier'] loop
    select string_agg(value || '=' || match_count, ',' order by match_count desc, value) into v_new_values
    from public.title_class_filter_values_v1(v_field, '', v_client, 100);
    -- The previous body, verbatim in its logic: candidate <> '', the client as
    -- = any(client_ids), most frequent first, 100 at most.
    select string_agg(value || '=' || n, ',' order by n desc, value) into v_old_values
    from (
      select candidate.value, count(*)::bigint as n
      from public.prospect_index pi
      cross join lateral (
        select case v_field
          when '__title_department' then pi.title_department
          when '__title_sub_department' then pi.title_sub_department
          when '__title_seniority_tier' then pi.title_seniority
          else '' end as value
      ) candidate
      where candidate.value <> '' and v_client = any(pi.client_ids)
      group by candidate.value
      order by count(*) desc, candidate.value
      limit 100
    ) old_values;
    if v_new_values is distinct from v_old_values then
      raise exception 'filter values for % changed for client %', v_field, v_client;
    end if;
  end loop;

  if exists (select 1 from public.title_class_filter_values_v1('__not_a_field', '', null, 10)) then
    raise exception 'an unknown field must still match nothing';
  end if;

  v_new := public.prospect_title_taxonomy_v1(v_client);
  if (select sum((t->>'count')::bigint) from jsonb_array_elements(v_new->'tiers') t)
       + coalesce((v_new->>'undefinedSeniority')::bigint, 0)
     > (select count(*) from public.prospect_index pi where pi.client_ids @> array[v_client]) then
    raise exception 'the client taxonomy counts more people than the client has';
  end if;
  if (select count(*) from public.prospect_index pi
       where pi.client_ids @> array[v_client] and btrim(coalesce(pi.title_seniority, '')) = 'manager')
     <> coalesce((select (t->>'count')::bigint from jsonb_array_elements(v_new->'tiers') t where t->>'value' = 'manager'), 0) then
    raise exception 'the client taxonomy manager count is wrong';
  end if;

  -- The cursor returns exactly the rows OFFSET returns, at a boundary deep in
  -- the table and on a tie-free first page.
  select created_at, id into v_c from public.prospect_index order by created_at desc, id offset 200000 limit 1;
  select array(select e->>'id' from jsonb_array_elements(w.result_rows) e) into v_got
  from public.search_prospect_workspace_cursor_v1('', '[]'::jsonb, 50, null, v_c.created_at, v_c.id, false,
    public.data_versions_v1(array['prospect'])) w;
  v_want := array(select id from public.prospect_index order by created_at desc, id offset 200001 limit 50);
  if v_got is distinct from v_want then
    raise exception 'the cursor page after row 200,000 differs from OFFSET';
  end if;
end $$;
