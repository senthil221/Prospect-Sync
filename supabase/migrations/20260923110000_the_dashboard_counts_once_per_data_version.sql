-- The dashboard counts people and companies once per data version.
--
-- WHAT IT COST, MEASURED on production 2026-09-23. dashboard_workspace counted
-- public.prospects (827,085 rows) and public.companies (446,492) on every page
-- load: 216-266 ms warm, 1.3 s with a cold cache, and 8.2 s at 01:40 UTC when
-- it ran beside a People page and a Companies page on the 2-vCPU box. Both are
-- whole-table scans, so the cost grows with the data even though the answer
-- only changes when somebody writes.
--
-- WHAT IT DOES NOW. The two counts are stored in public.dashboard_snapshot
-- (20260911120000) under the key 'workspaceCounts', stamped with the data
-- version vector they were counted at. A load whose vector matches reads the
-- row; one that does not recounts and stores the new answer. So the numbers
-- stay exact - there is no refresh cycle to wait for, unlike the worker-built
-- snapshots - and a quiet database pays a primary-key read instead of two scans.
--
-- WHICH TABLES. People are counted on prospect_index, not prospects: the
-- version sequence is bumped by prospect_index's triggers, so that is the table
-- the version actually describes, and it is the same total the People page
-- header shows. The two are kept equal by every write path (827,085 each today).
--
-- RACES. The vector is read before counting. A write that lands mid-count moves
-- the vector past the stored one, so the next load recounts; a stored answer is
-- never trusted beyond the version it was counted at. Two concurrent recounts
-- both upsert the same row and the later one wins, which is equally correct.
--
-- The function writes, so it becomes plpgsql VOLATILE. supabase.rpc() calls it
-- with POST, which PostgREST runs read-write.
-- ---------------------------------------------------------------------------

create or replace function public.dashboard_workspace()
returns table(result jsonb)
language plpgsql
volatile
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
declare
  v_versions jsonb := public.data_versions_v1(array['prospect', 'company']);
  v_counts jsonb;
begin
  select s.payload into v_counts
  from public.dashboard_snapshot s
  where s.key = 'workspaceCounts' and s.data_version = v_versions;

  if v_counts is null then
    v_counts := jsonb_build_object(
      'prospects', (select count(*) from public.prospect_index),
      'companies', (select count(*) from public.companies));
    insert into public.dashboard_snapshot (key, payload, data_version, computed_at)
    values ('workspaceCounts', v_counts, v_versions, now())
    on conflict (key) do update
      set payload = excluded.payload,
          data_version = excluded.data_version,
          computed_at = excluded.computed_at;
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

revoke execute on function public.dashboard_workspace() from public, anon, authenticated;
grant execute on function public.dashboard_workspace() to service_role;

-- ---------------------------------------------------------------------------
-- The numbers are the true counts, the second load reads rather than recounts,
-- and a version change forces a recount.
do $$
declare
  v_first jsonb;
  v_second jsonb;
  v_computed timestamptz;
  v_cfg text[];
begin
  delete from public.dashboard_snapshot where key = 'workspaceCounts';

  select result into v_first from public.dashboard_workspace();
  if (v_first->'stats'->>'prospects')::bigint <> (select count(*) from public.prospect_index)
     or (v_first->'stats'->>'companies')::bigint <> (select count(*) from public.companies) then
    raise exception 'the dashboard counts are not the true counts: %', v_first->'stats';
  end if;
  if not exists (select 1 from public.dashboard_snapshot where key = 'workspaceCounts'
                 and data_version = public.data_versions_v1(array['prospect', 'company'])) then
    raise exception 'the first load did not store its counts';
  end if;

  select computed_at into v_computed from public.dashboard_snapshot where key = 'workspaceCounts';
  select result into v_second from public.dashboard_workspace();
  if v_second->'stats' <> v_first->'stats' then
    raise exception 'a second load at the same version returned different stats';
  end if;
  if (select computed_at from public.dashboard_snapshot where key = 'workspaceCounts') <> v_computed then
    raise exception 'a second load at the same version recounted instead of reading';
  end if;

  -- A stored answer from another version must never be served.
  update public.dashboard_snapshot
     set payload = '{"prospects": -1, "companies": -1}'::jsonb,
         data_version = '{"prospect": -1, "company": -1}'::jsonb
   where key = 'workspaceCounts';
  select result into v_second from public.dashboard_workspace();
  if (v_second->'stats'->>'prospects')::bigint < 0 then
    raise exception 'the dashboard served counts from a different data version';
  end if;

  select p.proconfig into v_cfg from pg_proc p where p.oid = 'public.dashboard_workspace()'::regprocedure;
  if not (array_to_string(v_cfg, ',') like '%statement_timeout=30s%') then
    raise exception 'dashboard_workspace lost its statement_timeout: %', v_cfg;
  end if;
end $$;
