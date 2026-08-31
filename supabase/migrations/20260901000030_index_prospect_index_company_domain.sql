-- Index the People-side company domain filter.
--
-- prospect_prefilter_sql emits `lower(pi.company_domain) = any (...)` for the
-- __company_domain field, and nothing indexed that expression -- so a pasted list
-- of domains on the People tab scanned all 674,804 rows. Measured on production
-- with 500 domains:
--
--   Seq Scan, 674,052 rows removed by filter, ~790 MB read ..... 765 ms
--   Index Scan on this index .................................... 9.9 ms
--
-- The index is 9 MB against a 1.3 GB heap, which is a good trade for 77x.
--
-- This is the People-side twin of the Companies fix in 20260901000000. There the
-- equality could be routed to the already-indexed normalized_domain column;
-- prospect_index has no such column, so the expression gets its own index and the
-- generated SQL stays as it is.
--
-- On production this index was built with CREATE INDEX CONCURRENTLY, outside the
-- migration runner: prospect_index is the main read table, and a plain CREATE
-- INDEX takes ACCESS EXCLUSIVE for the whole build, which would stall every
-- reader. migrate.sh wraps each file in BEGIN/COMMIT and CONCURRENTLY cannot run
-- inside a transaction, so the concurrent build cannot live here.
--
-- IF NOT EXISTS therefore makes this a no-op on any database where the index was
-- already built by hand -- production included -- while a fresh replay still gets
-- it. On a fresh database the table is empty or small, so the exclusive lock this
-- form takes costs nothing.
--
-- If this ever needs rebuilding on a live database, do it the same way:
--   create index concurrently if not exists idx_prospect_index_company_domain_lower
--     on public.prospect_index (lower(company_domain));

begin;

create index if not exists idx_prospect_index_company_domain_lower
  on public.prospect_index (lower(company_domain));

commit;
