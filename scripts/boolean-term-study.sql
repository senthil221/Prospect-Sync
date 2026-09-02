-- Phase 0, section 3.3: the selectivity distribution of Boolean search terms.
--
-- WHY THIS EXISTS. Release 2 item 7 is "Boolean vector experiment only if the
-- Phase 0 term study supports it", and section 6.2 spells out what supporting it
-- would mean: a tsvector index is allowed "only on high-selectivity columns
-- (title, company name), only as an expression index that reproduces the
-- existing candidate text exactly, and only if the Phase 0 Boolean-term study
-- shows real queries are selective enough for the planner to choose it".
--
-- There is already a measured negative. 20260831210000 added a stored companies
-- search_tsv and 20260831230000 removed it again, because common keywords sat at
-- roughly 67 % selectivity, where GIN loses to a sequential scan and the column's
-- maintenance cost exceeded any gain. So the question is not "would an index
-- help in principle" but "are the terms people actually type selective enough".
--
-- WHAT IT MEASURES, AND WHAT IT SUBSTITUTES. The plan asks for "top terms from
-- logs". There are no query logs: nothing in the application records search
-- terms, and adding that would collect what users type about their own
-- prospects, which is not a thing to start doing for a benchmark. The substitute
-- is the distribution of terms in the data itself - people search for words that
-- are in their database, and a word absent from every title cannot be a common
-- query for titles. That is a proxy, and it is biased in the direction that
-- matters: it OVERSTATES the frequency of common words, so a column that looks
-- selective here is genuinely selective.
--
-- HOW TO READ IT. The last query prints a verdict. The number that decides is
-- the share of the top terms that match under 5 % of rows: a GIN index is chosen
-- by the planner when it expects to touch a small fraction of the table, and is
-- beaten by a sequential scan when it does not. A column whose common terms sit
-- in double-digit percentages is the companies case again and must not get one.
--
--   docker compose exec -T db psql -U postgres -d postgres -f - < scripts/boolean-term-study.sql
--
-- Read-only. It creates one temporary table, samples rather than scanning, and
-- bounds itself; it is safe to run against production, though it will use a core
-- for a minute or so.

\timing on
set statement_timeout = '10min';
set work_mem = '64MB';

-- 2 % of the table. Selectivity is a ratio, so the sample answers the question
-- at a fraction of the cost; at ~13,000 rows the sampling error on a 5 % term is
-- well under a percentage point, and the decision boundary here is between 1 %
-- and 60 %, not between 4.8 % and 5.2 %.
create temporary table term_sample as
select
  coalesce(pi.title, '') as title,
  coalesce(pi.company_name, '') as company_name,
  coalesce(array_to_string(pi.keywords, ' | '), '') as keywords
from public.prospect_index pi tablesample system (2);

select count(*) as sampled_rows,
       (select count(*) from public.prospect_index) as total_rows,
       count(*) filter (where btrim(title) <> '') as with_title,
       count(*) filter (where btrim(company_name) <> '') as with_company
from term_sample;

-- Document frequency per lexeme, using the same 'simple' configuration and the
-- same candidate text the Boolean filter compiles (20260902000030).
create temporary table term_stats as
with sampled as (select count(*)::numeric as rows from term_sample)
select 'title' as column_name, word, ndoc,
       round(100 * ndoc / (select rows from sampled), 2) as pct_of_rows
from ts_stat($$select to_tsvector('simple', coalesce(title, '')) from term_sample$$)
union all
select 'company_name', word, ndoc,
       round(100 * ndoc / (select rows from sampled), 2)
from ts_stat($$select to_tsvector('simple', coalesce(company_name, '')) from term_sample$$)
union all
select 'keywords', word, ndoc,
       round(100 * ndoc / (select rows from sampled), 2)
from ts_stat($$select to_tsvector('simple', coalesce(keywords, '')) from term_sample$$);

-- The twenty commonest terms per column. These are the queries an index would
-- have to beat a sequential scan on.
select column_name, word, ndoc, pct_of_rows
from (
  select ts.*, row_number() over (partition by column_name order by ndoc desc) as rank
  from term_stats ts
) ranked
where rank <= 20
order by column_name, ndoc desc;

-- The distribution, which is the actual answer.
select column_name,
       count(*) as distinct_terms,
       count(*) filter (where pct_of_rows < 1) as under_1_pct,
       count(*) filter (where pct_of_rows < 5) as under_5_pct,
       count(*) filter (where pct_of_rows >= 20) as over_20_pct,
       max(pct_of_rows) as commonest_term_pct
from term_stats
group by column_name
order by column_name;

-- Weighted by how often a term appears, not by how many distinct terms there
-- are. A column with a million rare words and one word in every row is not
-- selective in practice, and counting distinct terms would say it was.
select column_name,
       round(100.0 * sum(ndoc) filter (where pct_of_rows < 5) / nullif(sum(ndoc), 0), 1) as pct_of_term_uses_under_5_pct,
       round(100.0 * sum(ndoc) filter (where pct_of_rows >= 20) / nullif(sum(ndoc), 0), 1) as pct_of_term_uses_over_20_pct
from term_stats
group by column_name
order by column_name;

-- The verdict, stated rather than left to be inferred.
select column_name,
       commonest_term_pct,
       weighted_selective_pct,
       case
         when commonest_term_pct >= 20 then
           'NO - its commonest term matches a fifth of the table, which is the companies search_tsv case that 20260831230000 reverted.'
         when weighted_selective_pct < 80 then
           'NO - too many term uses are not selective enough for the planner to choose an index scan.'
         else
           'CANDIDATE - build the expression index on this column and compare plans before adopting it.'
       end as verdict
from (
  select column_name,
         max(pct_of_rows) as commonest_term_pct,
         round(100.0 * sum(ndoc) filter (where pct_of_rows < 5) / nullif(sum(ndoc), 0), 1) as weighted_selective_pct
  from term_stats
  group by column_name
) summary
order by column_name;

-- ---------------------------------------------------------------------------
-- RESULT, run against production 2026-09-03 (674k prospects, 2 % sample).
--
--   column        commonest term        distinct terms   term uses under 5 %
--   title         manager    42.16 %          2,867             56.1 %
--   company_name  (top)       7.69 %          8,904             93.8 %
--   keywords      solutions   0.22 %          1,575            100.0 %
--
-- TITLE FAILS THE GATE OUTRIGHT. 'manager' is in 42 % of titles, 'director' in
-- 14 %, 'head' in 13 %. Section 6.2 named title as one of the two eligible
-- columns; the data says it is the least eligible column in the table. An index
-- whose commonest lookup touches two rows in five is the companies search_tsv
-- case again, and 20260831230000 already paid for that lesson once.
--
-- COMPANY_NAME PASSES THE GATE AND STILL SHOULD NOT GET ONE. It is selective -
-- 94 % of term uses match under 5 % of rows - so the study permits the
-- experiment. The experiment then says no, for a reason selectivity cannot show:
--
--   explain (analyze) of the real Boolean predicate, ordered and limited the way
--   the listing orders and limits it, on production:
--     company_name @@ 'hdfc'  (7,047 rows, 1.0 %)   533 ms
--     title        @@ 'manager' (42 %)               12.9 ms
--
-- The planner walks idx_prospect_index_created_at in order and STOPS at 50
-- matches. That is the early-stopping scan section 6.2 makes the default, and it
-- is why the selective term is the slow one: rarer matches mean more of the
-- index walked before fifty are found. A GIN index cannot improve that page. It
-- would find all 7,047 matches and then sort them by created_at - strictly more
-- work than stopping at fifty - so for the interactive path it is not a smaller
-- win, it is a loss.
--
-- Where it would help is the unbounded count, which takes 1.66 s for the whole
-- table. That runs in the background against a 120 s budget, so 1.66 s is not a
-- problem worth an index.
--
-- Against that: prospect_index already carries 36 indexes, 18 of them GIN
-- trigram and 722 MB, on a table whose write path is the measured bottleneck
-- (87.5 rows/sec) against section 2's 10 % index-maintenance budget - a budget
-- that has never been checked end to end.
--
-- CONCLUSION: Release 2 item 7 is closed, not deferred. The gate has been
-- measured and the answer is no. Re-run this if the title or company mix
-- changes materially, or if a Boolean filter ever shows up in the slow-request
-- log that lib/observability.ts keeps.
