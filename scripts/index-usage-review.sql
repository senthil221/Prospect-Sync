-- Which indexes on prospect_index earn what they cost?
--
-- Release 4 item 1 asks for an index-usage review and safe removals. This is the
-- evidence half. It does not drop anything: idx_scan is a cumulative count, and
-- a young index with no scans has not been rejected by the planner so much as
-- never asked, so the age of the index matters as much as its count. Check the
-- migration that created one before concluding anything about it.
--
-- Read-only.

select
  s.indexrelname as index_name,
  s.idx_scan as scans,
  pg_size_pretty(pg_relation_size(s.indexrelid)) as size,
  i.indexdef
from pg_stat_user_indexes s
join pg_indexes i on i.schemaname = s.schemaname and i.indexname = s.indexrelname
where s.relname = 'prospect_index'
order by s.idx_scan asc, pg_relation_size(s.indexrelid) desc;

select
  count(*) as indexes,
  count(*) filter (where idx_scan = 0) as never_scanned,
  pg_size_pretty(sum(pg_relation_size(indexrelid))) as index_bytes,
  pg_size_pretty(sum(pg_relation_size(indexrelid)) filter (where idx_scan = 0)) as never_scanned_bytes,
  pg_size_pretty(pg_relation_size('public.prospect_index')) as table_bytes
from pg_stat_user_indexes where relname = 'prospect_index';

-- Counters are cumulative since this, so a null means "since the database was
-- created" and the numbers above cover the whole life of the table.
select stats_reset from pg_stat_database where datname = current_database();

-- ---------------------------------------------------------------------------
-- RESULT, production 2026-09-03. 681,085 prospects.
--
--   36 indexes, 914 MB of index against a 1,332 MB table.
--   14 never scanned, 116 MB, all of them 8 to 23 days old - so they have had
--   real use and the planner has never once chosen them.
--
-- THE TWO THAT MATTER, AND WHY THEY ARE NOT THE SAME CASE:
--
--   idx_prospect_index_work_email_trgm   74 MB, 0 scans, created 20260825.
--     Serves `__work_email contains`. The People filter panel does not offer
--     __work_email - its Email filter is __email, which compiles to
--     concat_ws(' ', work_email, personal_email) and no index covers a concat.
--     So this index serves a filter the product does not expose. The clearest
--     removal candidate on the table.
--
--   idx_prospect_index_linkedin_trgm     92 MB, 1 scan, created 20260902.
--     Bigger, barely used, and one day old - but __linkedin IS offered in the
--     panel with an exact/contains toggle, so `contains` is reachable and
--     dropping it would make an offered feature scan. Leave it; revisit when the
--     counter has had a month rather than a day.
--
-- THE OPERATOR THE PRODUCT ACTUALLY USES HAS NO INDEX. `equals` compiles to
-- lower(pi.work_email) = any (...) through the prefilter - the index-friendly
-- form, no coalesce - and there is no lower(work_email) btree to match it.
-- Measured: 2,000 exact work emails takes 802 ms, against 243 ms for 2,000
-- company domains, which do have idx_prospect_index_company_domain_lower
-- (10,502 scans, 9 MB - the best value index on the table).
--
-- The small never-scanned GIN indexes over arrays - blocked_client_ids,
-- icp_verified_client_ids, client_names, list_names, keywords, 14 MB together -
-- are cheap to maintain precisely because most rows hold empty arrays, and they
-- back real features nobody has exercised yet. Not worth removing.
--
-- NONE OF THIS IS URGENT. It is roughly 75 MB of a 2.2 GB table-plus-index, and
-- a few percent of import time. It belongs to Release 4, and it should be done
-- when the write path is being measured anyway rather than on its own.
