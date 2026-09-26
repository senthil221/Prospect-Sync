-- The membership tables stay all-visible, so their counts stay index-only.
--
-- MEASURED on production 2026-09-26. The Clients list (client_summaries) took
-- up to 7.3 s in the slow-plan log and 584 ms warm. Its plan is the right one -
-- index-only scans per client - but counting the Unassigned bucket's 811,000
-- memberships did 690,621 heap fetches: an index-only scan can skip the table
-- only for pages the visibility map marks all-visible, and client_prospects is
-- 45% all-visible (client_companies 78%, prospects and list_rows 81%).
--
-- The cause is thresholds, not load. These tables take a steady stream of
-- updates - status, date_added on re-import, blocklist moves - and at the
-- default 5% of ~870,000 rows (43,500 dead or inserted tuples) autovacuum
-- rarely reaches them: client_prospects was last vacuumed 5 days ago with
-- 40,323 dead tuples outstanding. prospect_index was tuned to 2% earlier and
-- is 100% all-visible, which is exactly why People counts there are cheap.
--
-- Same treatment here, sized per table. Vacuuming a few thousand pages more
-- often is cheap; the heap fetches it removes are paid on every count, and
-- far more on a cold cache. ALTER TABLE ... SET (storage parameters) takes a
-- SHARE UPDATE EXCLUSIVE lock, which does not block reads or writes.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

alter table public.client_prospects set (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_insert_scale_factor = 0.01,
  autovacuum_analyze_scale_factor = 0.02
);
alter table public.client_companies set (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02
);
alter table public.prospects set (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02
);
alter table public.list_rows set (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.05
);

do $$
begin
  if not exists (
    select 1 from pg_class
    where oid = 'public.client_prospects'::regclass
      and 'autovacuum_vacuum_scale_factor=0.01' = any(reloptions)
  ) then
    raise exception 'client_prospects did not take its autovacuum settings';
  end if;
end $$;
