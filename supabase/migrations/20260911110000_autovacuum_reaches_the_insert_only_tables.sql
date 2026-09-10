-- Three of the largest tables in this database have never been autovacuumed.
-- Not "not recently" - never, since they were created:
--
--   table                  rows   visible  heap fetches  inserts  updates  autovacuums
--   client_prospects     686,357    46.7%      670,982   18,577    2,357        0
--   prospect_identifiers 2,651,370  87.0%            -   46,084        0        0
--   list_memberships     712,611    87.8%            -   20,689      223        0
--   prospects            681,785    72.8%      182,067   13,992  2,015,662     34
--   companies            418,797    83.2%            -    1,467  2,691,860     53
--   list_rows            726,422    91.1%            -   20,912    726,424     12
--
-- WHY. Autovacuum's main trigger is dead tuples, and an insert creates none. A
-- table that is only ever appended to therefore never crosses the threshold, no
-- matter how large it grows. autovacuum_vacuum_insert_scale_factor exists for
-- exactly this, but its default of 0.2 means waiting for the table to grow by a
-- fifth - 137,000 rows on client_prospects - before the visibility map is
-- touched at all.
--
-- WHAT IT COSTS. A stale visibility map turns an index-only scan back into an
-- index scan plus a heap lookup per row. Measured on production:
--
--   select count(*) from client_prospects
--     -> Parallel Index Only Scan ... Heap Fetches: 670,982
--
-- 670,982 fetches for 686,357 rows: the index-only scan is falling back to the
-- heap for essentially every row, which is the whole of the benefit gone. The
-- same shape cost prospect_index 63,085 fetches a call until 20260910150000,
-- where a VACUUM took it to 100% and the scan from 232ms to 69ms.
--
-- WHAT THIS DOES NOT DO. Settings only govern future autovacuums; they cannot
-- repair the map that is stale now, and VACUUM cannot run inside a transaction,
-- which every migration here is. A one-off VACUUM (ANALYZE) over these six
-- tables is needed once alongside this, after which autovacuum keeps them.
--
-- 0.05 rather than the 0.02 given to prospect_index. These are large but far
-- less hot, the box has 2 vCPUs shared with PostgreSQL's own work, and
-- autovacuum that runs too eagerly competes with the imports it is meant to
-- support. Five percent of client_prospects is ~34,000 rows, against 137,000
-- on the default.

begin;

-- Insert-only: these never reached the dead-tuple trigger, so insert_scale_factor
-- is the setting that matters. The vacuum one is set too, cheaply, so a future
-- change that starts updating them is covered without another migration.
alter table public.client_prospects set (
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.05
);
alter table public.list_memberships set (
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.05
);
alter table public.prospect_identifiers set (
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.05
);

-- Update-heavy: these do get autovacuumed, just late. companies takes 2.69
-- million updates and waits for 20% of 418,797 rows - about 84,000 dead tuples -
-- before it runs, which is why it sits at 83.2%.
alter table public.companies set (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.05
);
alter table public.prospects set (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.05
);
alter table public.list_rows set (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.05
);

do $$
declare
  v_table text;
  v_options text;
begin
  foreach v_table in array array[
    'client_prospects', 'list_memberships', 'prospect_identifiers',
    'companies', 'prospects', 'list_rows'
  ] loop
    select array_to_string(reloptions, ',') into v_options
    from pg_class where oid = ('public.' || v_table)::regclass;

    if v_options is null then
      raise exception '% kept its default autovacuum settings', v_table;
    end if;
    if position('autovacuum_vacuum_insert_scale_factor=0.05' in v_options) = 0 then
      raise exception '% did not take the insert scale factor - that is the one that matters for an append-only table: %',
        v_table, v_options;
    end if;
    if position('autovacuum_vacuum_scale_factor=0.05' in v_options) = 0 then
      raise exception '% did not take the vacuum scale factor: %', v_table, v_options;
    end if;
  end loop;

  -- prospect_index keeps the tighter 0.02 from 20260910150000; this must not
  -- have loosened it.
  select array_to_string(reloptions, ',') into v_options
  from pg_class where oid = 'public.prospect_index'::regclass;
  if position('autovacuum_vacuum_scale_factor=0.02' in v_options) = 0 then
    raise exception 'prospect_index lost its tighter setting: %', v_options;
  end if;
end;
$$;

commit;
