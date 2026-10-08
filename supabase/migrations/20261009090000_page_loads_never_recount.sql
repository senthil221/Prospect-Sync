-- Page loads never recount the database: the Overview and Clients caches are
-- served as they stand and refreshed by the operations worker.
--
-- 2026-10-09: the Overview failed with "canceling statement due to statement
-- timeout" and the Clients list took 12s. Both caches were recomputed on the
-- page request when stale: dashboard_workspace() counted prospect_index (3.3 GB)
-- and companies (4.5 GB) whenever its snapshot's data version was behind, and
-- client_summaries_v1() recounted every client once its cache was five minutes
-- old. After an idle evening the database cache is cold, those counts run past
-- PostgREST's 8s limit, and the page errors. refresh_dashboard_snapshots_v1 (the
-- operations worker, every five minutes) refreshed neither.
--
--   dashboard_workspace   serves the last workspaceCounts snapshot, of any
--                         version; with none at all, pg_class row estimates.
--   client_summaries_v1   an aged but same-version cache is served as is; a
--                         cache behind the data (an import, a blocklist) is
--                         still recomputed, so counts move when the data does.
--   refresh_dashboard_snapshots_v1  also refreshes workspaceCounts (with the
--                         other snapshots, after the settle) and the client
--                         summary cache (whenever it is behind or 5 min old).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.dashboard_workspace()
 RETURNS TABLE(result jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '10s'
AS $function$
declare
  v_counts jsonb;
begin
  -- The last snapshot, whatever version it was taken at: the operations
  -- worker refreshes it (20261009090000). Counting 1.3M rows here timed the
  -- Overview out whenever the database cache was cold. With no snapshot at
  -- all, the planner's row estimates stand in until the worker's first run.
  select s.payload into v_counts
  from public.dashboard_snapshot s
  where s.key = 'workspaceCounts';

  if v_counts is null then
    v_counts := jsonb_build_object(
      'prospects', (select greatest(reltuples, 0)::bigint from pg_class where oid = 'public.prospect_index'::regclass),
      'companies', (select greatest(reltuples, 0)::bigint from pg_class where oid = 'public.companies'::regclass));
  end if;

  return query
  select jsonb_build_object(
    'stats', jsonb_build_object(
      'prospects', (v_counts->>'prospects')::bigint,
      'companies', (v_counts->>'companies')::bigint,
      'clients', (select count(*) from public.clients),
      'lists', (select count(*) from public.lists),
      'rowsImported', (select coalesce(sum(processed_rows), 0) from public.imports),
      'duplicatesDetected', (select coalesce(sum(duplicates_linked), 0) from public.imports)
    ),
    'recentImports', coalesce((
      select jsonb_agg(to_jsonb(recent) order by recent.created_at desc)
      from (
        select *
        from (
          select i.id, 'prospects'::text as kind, i.file_name, i.data_source, i.status,
            i.processed_rows, i.unique_added, i.duplicates_linked, i.created_at,
            c.name as client_name, l.name as list_name,
            0::integer as added_count, 0::integer as updated_count, 0::integer as skipped_count
          from public.imports i
          left join public.clients c on c.id = i.client_id
          left join public.lists l on l.id = i.list_id
          where i.status = 'completed'

          union all

          select ci.id, 'companies'::text as kind, ci.file_name, ci.data_source, ci.status,
            ci.processed_rows, 0::integer as unique_added, 0::integer as duplicates_linked,
            ci.created_at, null::text as client_name, null::text as list_name,
            ci.added_count, ci.updated_count, ci.skipped_count
          from public.company_imports ci
          where ci.status = 'completed'
        ) all_imports
        order by created_at desc
        limit 6
      ) recent
    ), '[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.client_summaries_v1(p_client_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
declare
  v_version bigint := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  v_cache public.client_summary_cache%rowtype;
  v_counts jsonb;
  v_cache_valid boolean := false;
  v_cache_found boolean := false;
begin
  select * into v_cache from public.client_summary_cache where id;
  v_cache_found := found;
  v_cache_valid := v_cache_found
    and v_cache.version = v_version
    and v_cache.computed_at > now() - interval '5 minutes'
    and not exists (select 1 from public.clients c where not (v_cache.counts ? c.id));

  if v_cache_valid then
    v_counts := v_cache.counts;
  elsif p_client_id is null and v_cache_found
        and v_cache.version = v_version
        and not exists (select 1 from public.clients c where not (v_cache.counts ? c.id)) then
    -- Nothing changed, the cache only aged (an idle evening). Serve it; the
    -- operations worker refreshes it (20261009090000). Recounting every client
    -- here on a cold database took 12s and timed the Clients list out.
    v_counts := v_cache.counts;
  elsif p_client_id is not null then
    -- client_summaries' NOT MATERIALIZED CTEs let this predicate reach the
    -- membership scans. Do not publish a partial object as the global cache.
    select coalesce(jsonb_object_agg(s.id, jsonb_build_object(
             'prospect_count', s.prospect_count,
             'icp_verified_count', s.icp_verified_count,
             'blocked_count', s.blocked_count,
             'company_count', s.company_count)), '{}'::jsonb)
      into v_counts
      from public.client_summaries s
     where s.id = p_client_id;
  else
    select coalesce(jsonb_object_agg(s.id, jsonb_build_object(
             'prospect_count', s.prospect_count,
             'icp_verified_count', s.icp_verified_count,
             'blocked_count', s.blocked_count,
             'company_count', s.company_count)), '{}'::jsonb)
      into v_counts
      from public.client_summaries s;
    insert into public.client_summary_cache (id, version, computed_at, counts)
    values (true, v_version, now(), v_counts)
    on conflict (id) do update
      set version = excluded.version,
          computed_at = excluded.computed_at,
          counts = excluded.counts;
  end if;

  -- Metadata is deliberately live even on a cache hit. New clients and unknown
  -- ids therefore retain their existing zero-row/zero-count behavior.
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id,
             'name', c.name,
             'created_at', c.created_at,
             'list_count', (select count(*)::integer from public.lists l where l.client_id = c.id),
             'prospect_count', coalesce((v_counts->c.id->>'prospect_count')::integer, 0),
             'icp_verified_count', coalesce((v_counts->c.id->>'icp_verified_count')::integer, 0),
             'blocked_count', coalesce((v_counts->c.id->>'blocked_count')::integer, 0),
             'company_count', coalesce((v_counts->c.id->>'company_count')::integer, 0),
             'folder_id', c.folder_id,
             'archived_at', c.archived_at)
           order by c.name), '[]'::jsonb)
      from public.clients c
     where p_client_id is null or c.id = p_client_id);
end;
$function$;

CREATE OR REPLACE FUNCTION prospect_operations.refresh_dashboard_snapshots_v1()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '300s'
AS $function$
declare
  v_versions jsonb := public.data_versions_v1(array['prospect', 'company']);
  v_refreshed integer := 0;
  v_started timestamptz;
  v_payload jsonb;
  v_key text;
  v_observed prospect_operations.snapshot_settle%rowtype;
  v_oldest timestamptz;
  v_client_version bigint := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  v_client_counts jsonb;
begin
  -- The Clients list cache (client_summaries_v1), refreshed here so a page
  -- never has to recount every client (20261009090000). It has its own
  -- version, so it sits outside the prospect/company settle below.
  if not exists (select 1 from public.client_summary_cache c
                  where c.id and c.version = v_client_version and c.computed_at > now() - interval '5 minutes'
                    and not exists (select 1 from public.clients k where not (c.counts ? k.id))) then
    select coalesce(jsonb_object_agg(s.id, jsonb_build_object(
             'prospect_count', s.prospect_count,
             'icp_verified_count', s.icp_verified_count,
             'blocked_count', s.blocked_count,
             'company_count', s.company_count)), '{}'::jsonb)
      into v_client_counts
      from public.client_summaries s;
    insert into public.client_summary_cache (id, version, computed_at, counts)
    values (true, v_client_version, now(), v_client_counts)
    on conflict (id) do update
      set version = excluded.version, computed_at = excluded.computed_at, counts = excluded.counts;
    v_refreshed := v_refreshed + 1;
  end if;

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
    where s.key in ('dataQuality', 'indexDrift', 'titleTaxonomy', 'workspaceCounts');
    if v_oldest is not null and v_oldest > now() - interval '60 minutes' then
      return v_refreshed;
    end if;
  elsif v_observed.observed_at > now() - interval '4 minutes' then
    return v_refreshed;
  end if;

  foreach v_key in array array['workspaceCounts', 'dataQuality', 'indexDrift', 'titleTaxonomy'] loop
    -- Same version means the stored answer is the answer.
    if exists (
      select 1 from public.dashboard_snapshot s
      where s.key = v_key and s.data_version = v_versions
    ) then
      continue;
    end if;

    v_started := clock_timestamp();
    v_payload := case v_key
      when 'workspaceCounts' then jsonb_build_object(
        'prospects', (select count(*) from public.prospect_index),
        'companies', (select count(*) from public.companies))
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

revoke execute on function public.dashboard_workspace() from public, anon, authenticated;
grant execute on function public.dashboard_workspace() to service_role;
revoke execute on function public.client_summaries_v1(text) from public, anon, authenticated;
grant execute on function public.client_summaries_v1(text) to service_role;
revoke execute on function prospect_operations.refresh_dashboard_snapshots_v1() from public, anon, authenticated;
grant execute on function prospect_operations.refresh_dashboard_snapshots_v1() to service_role, prospect_operator;
