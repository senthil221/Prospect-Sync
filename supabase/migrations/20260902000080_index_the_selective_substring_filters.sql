-- Index the substring filters that are selective, and record why the rest are not.
--
-- The audit recorded Parallel Seq Scan for `contains` on full_name (plan A) and
-- company_country (plan F). Measured on production at 20260902000030, every
-- candidate column did the same thing: a full pass over the 1.3 GB heap,
-- 170,527 buffers, whatever the filter matched.
--
-- Section 6.7 asks for a decision per column against a selective fixture rather
-- than an open-ended candidate pool. Measured selectivity decided it, and it did
-- not always agree with the Tier 1 / Tier 2 guess -- "united states" was
-- expected to be broad and is 1.2% of this database, which is India-heavy.
--
--   column            fixture          matches   share    before      after   index
--   full_name         %rajesh%           4,081   0.60%    530 ms    36.9 ms   34 MB   (plan A)
--   first_name        %rajesh%           3,944   0.58%    365 ms    34.2 ms   20 MB
--   last_name         %sharma%          16,739   2.48%    392 ms   101.2 ms   19 MB
--   linkedin_url      %rajesh%           3,413   0.51%    465 ms    31.8 ms   75 MB
--   company_domain    %shop%               720   0.11%    367 ms     5.6 ms   31 MB
--   personal_email    %gmail%            1,255   0.19%    325 ms    10.9 ms  1.4 MB
--   tag_text          %priority%             0   0.00%    465 ms     0.3 ms  0.9 MB
--   company_country   %united states%    8,140   1.21%    569 ms    27.6 ms  4.7 MB   (plan F)
--
-- Buffers fall with the time: full_name went 170,527 -> 4,107, company_domain
-- 170,527 -> 509. Not built, with reasons, so a later reader does not have to
-- rediscover them:
--
--   company_state    %maharashtra%    150,828   22%    a sequential scan is the
--                                                      correct plan at this share
--   esp              %google%         216,564   32%    likewise
--   company_city     %gurugram%        31,521  4.7%    but Mumbai alone is 107,140
--                                                      (16%), so the same filter is
--                                                      selective or broad depending
--                                                      on the value; left out until
--                                                      the log study in section 6.1
--                                                      says which people actually use
--   email_provider_type              45,964   6.8%    a handful of short, low
--                                                      cardinality values; a trigram
--                                                      index over them is mostly
--                                                      overhead
--
-- TWO THINGS THIS COSTS, both measured, neither hidden:
--
-- 1. A substring shorter than three characters gets WORSE, not better. pg_trgm
--    extracts no trigram from a two-character pattern, so the index matches
--    every row and the recheck re-reads the heap without parallelism:
--
--      full_name ilike '%vp%'   before: Parallel Seq Scan   ~530 ms
--                               after:  Bitmap Heap Scan,  1,107 ms
--                                       674,652 rows removed by index recheck
--
--    This is inherent to pg_trgm and already true of the title, company_name and
--    search_text indexes that predate this migration. It is left as it is: a
--    two-character substring on a name is rare, 1.1 s is still inside the p95
--    budget, and the fix belongs with the runtime classifier in section 6.1,
--    which can route a pattern it knows the index cannot serve.
--
-- 2. Writes get slower. Measured by building the index set prospect_index
--    already had on a temporary copy of real rows, timing an insert of 10,000,
--    then adding these eight and timing another 10,000:
--
--      index set as it was ......... 2,292 ms / 10k       2,057 ms / 10k
--      plus these eight ............ 2,794 ms / 10k  (+21.9%)
--      plus seven, no linkedin_url .                      2,384 ms / 10k  (+15.9%)
--
--    Run-to-run variance on the baseline was about 10%, so the honest figure is
--    a 16-22% increase in INDEX MAINTENANCE. That is not the same as the
--    section 2 budget, which is end-to-end import throughput: an import also
--    parses, deduplicates, upserts prospects and syncs company counts, none of
--    which these indexes touch. The end-to-end number is not measured here and
--    should be, on the next real import, against that 10% budget.
--
--    linkedin_url is the one to reconsider first if it has to come out: 75 MB of
--    the 186 MB added, the largest single write cost, and the bulk case for that
--    field is a pasted list of URLs, which the UI turns into `equals` above 25
--    values -- an equality this trigram index does not serve. That path wants a
--    btree on lower(linkedin_url), the shape 20260901000030 built for
--    company_domain, and it is still missing.
--
-- Total index size on prospect_index: 563 MB -> 749 MB, against a 1,332 MB heap.
-- All 36 indexes report indisvalid = true.
--
-- Broad values still choose the sequential scan, which is the point of indexing
-- for selectivity rather than for the presence of a filter:
--
--   company_country ilike '%india%'  433,808 rows (64%)  Parallel Seq Scan, 526 ms
--
-- HOW THESE WERE BUILT. On production each was created with
-- CREATE INDEX CONCURRENTLY, outside the migration runner, one at a time, with
-- pg_index.indisvalid checked after each -- exactly as 20260901000030 documents.
-- migrate.sh wraps every file in BEGIN/COMMIT with lock_timeout = 5s, and
-- CONCURRENTLY cannot run inside a transaction, so the concurrent form cannot
-- live here. IF NOT EXISTS therefore makes this file a no-op on production and
-- a correct build on a fresh replay, where the table is small enough that the
-- exclusive lock costs nothing.
--
-- To rebuild any of these on a live database, use the concurrent form:
--   create index concurrently if not exists <name>
--     on public.prospect_index using gin (<column> gin_trgm_ops);
--
-- One note on shape: personal_email and tag_text were first built as PARTIAL
-- indexes (WHERE column <> ''), since 99.7% of personal_email and all but 50
-- tag_text rows are blank. The planner could not use them: it cannot prove that
-- `personal_email ilike '%gmail%'` implies `personal_email <> ''`, so the query
-- fell back to a sequential scan and the 536 kB index sat unused. They are full
-- indexes here. An empty string yields no trigrams, so the blank rows cost
-- almost nothing anyway -- the full personal_email index is 1.4 MB.

begin;

create index if not exists idx_prospect_index_full_name_trgm
  on public.prospect_index using gin (full_name gin_trgm_ops);

create index if not exists idx_prospect_index_first_name_trgm
  on public.prospect_index using gin (first_name gin_trgm_ops);

create index if not exists idx_prospect_index_last_name_trgm
  on public.prospect_index using gin (last_name gin_trgm_ops);

create index if not exists idx_prospect_index_linkedin_trgm
  on public.prospect_index using gin (linkedin_url gin_trgm_ops);

create index if not exists idx_prospect_index_company_domain_trgm
  on public.prospect_index using gin (company_domain gin_trgm_ops);

create index if not exists idx_prospect_index_personal_email_trgm
  on public.prospect_index using gin (personal_email gin_trgm_ops);

create index if not exists idx_prospect_index_tag_text_trgm
  on public.prospect_index using gin (tag_text gin_trgm_ops);

create index if not exists idx_prospect_index_company_country_trgm
  on public.prospect_index using gin (company_country gin_trgm_ops);

commit;
