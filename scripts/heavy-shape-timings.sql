-- Where do the heavy shapes actually break?
--
-- Not "20 concurrent users" - one user doing something enormous. A large domain
-- paste, a lot of filters, and a pivot from one to the other. Timed against the
-- 10s ceiling the interactive functions declare.
--
-- Named arguments throughout, deliberately: the first attempt at this passed
-- 'desc' positionally into p_client_id and every shape returned 0 rows in 24 ms,
-- which looked like excellent news and measured nothing.

\timing on
set statement_timeout = '30s';

create temporary table dom as
select c.domain
from public.companies c
join (select company_id, count(*) as people from public.prospect_index
      where company_id is not null group by company_id) p on p.company_id = c.id
where btrim(coalesce(c.domain, '')) <> ''
order by p.people desc
limit 5000;

select 'domains with the most people behind them' as note, count(*) from dom;

\set p_all '{"search":"","limit":250000,"filters":[]}'

-- ---- 1. COMPANY LISTING: the bulk domain paste ---------------------------

\echo '=== company listing: 100 domains ==='
select total_count, total_capped from public.filter_companies_v4(
  p_filters => jsonb_build_array(jsonb_build_object('field','__website','operator','equals',
    'values', to_jsonb(array(select domain from dom limit 100)))), p_limit => 50);

\echo '=== company listing: 1000 domains ==='
select total_count, total_capped from public.filter_companies_v4(
  p_filters => jsonb_build_array(jsonb_build_object('field','__website','operator','equals',
    'values', to_jsonb(array(select domain from dom limit 1000)))), p_limit => 50);

\echo '=== company listing: 5000 domains (the cap) ==='
select total_count, total_capped from public.filter_companies_v4(
  p_filters => jsonb_build_array(jsonb_build_object('field','__website','operator','equals',
    'values', to_jsonb(array(select domain from dom limit 5000)))), p_limit => 50);

-- ---- 2. THE PIVOT ---------------------------------------------------------

\echo '=== pivot resolve: 5000 domains -> company ids ==='
select count(*) as companies from public.company_scope_ids_v2(null,
  jsonb_build_object('search','','limit',250000,'filters', jsonb_build_array(jsonb_build_object(
    'field','__website','operator','equals',
    'values', to_jsonb(array(select domain from dom limit 5000))))));

-- ---- 3. PEOPLE UNDER THAT PIVOT ------------------------------------------

\echo '=== people listing under a 1000-domain pivot, page 1 + exact total ==='
select total_count, total_capped, scope_capped from public.search_prospect_workspace_v12(
  p_search => '', p_filters => '[]'::jsonb, p_limit => 50, p_with_total => true,
  p_company_scope => jsonb_build_object('search','','limit',250000,'filters', jsonb_build_array(
    jsonb_build_object('field','__website','operator','equals',
      'values', to_jsonb(array(select domain from dom limit 1000))))));

\echo '=== people listing under a 5000-domain pivot, page 1 + exact total ==='
select total_count, total_capped, scope_capped from public.search_prospect_workspace_v12(
  p_search => '', p_filters => '[]'::jsonb, p_limit => 50, p_with_total => true,
  p_company_scope => jsonb_build_object('search','','limit',250000,'filters', jsonb_build_array(
    jsonb_build_object('field','__website','operator','equals',
      'values', to_jsonb(array(select domain from dom limit 5000))))));

-- ---- 4. MANY FILTERS ------------------------------------------------------

\echo '=== people listing: one substring filter ==='
select total_count, total_capped from public.search_prospect_workspace_v12(
  p_search => '', p_limit => 50, p_with_total => true,
  p_filters => '[{"field":"__title","operator":"contains","values":["manager"]}]'::jsonb);

\echo '=== people listing: 30 substring filters ==='
select total_count, total_capped from public.search_prospect_workspace_v12(
  p_search => '', p_limit => 50, p_with_total => true,
  p_filters => (select jsonb_agg(jsonb_build_object('field','__title','operator','contains',
    'values', jsonb_build_array('a','e','i'))) from generate_series(1,30)));

\echo '=== people listing: 60 substring filters (the cap) ==='
select total_count, total_capped from public.search_prospect_workspace_v12(
  p_search => '', p_limit => 50, p_with_total => true,
  p_filters => (select jsonb_agg(jsonb_build_object('field','__title','operator','contains',
    'values', jsonb_build_array('a','e','i'))) from generate_series(1,60)));

-- ---- 5. A LARGE EXACT-VALUE LIST ON PEOPLE -------------------------------

\echo '=== people listing: 5000 exact company domains as a people filter ==='
select total_count, total_capped from public.search_prospect_workspace_v12(
  p_search => '', p_limit => 50, p_with_total => true,
  p_filters => jsonb_build_array(jsonb_build_object('field','__company_domain','operator','equals',
    'values', to_jsonb(array(select domain from dom limit 5000)))));

-- ---- 6. THE WORST REALISTIC COMBINATION ----------------------------------

\echo '=== 5000-domain pivot + 5 title filters + exact total ==='
select total_count, total_capped, scope_capped from public.search_prospect_workspace_v12(
  p_search => '', p_limit => 50, p_with_total => true,
  p_filters => (select jsonb_agg(jsonb_build_object('field','__title','operator','contains',
    'values', jsonb_build_array('manager','director'))) from generate_series(1,5)),
  p_company_scope => jsonb_build_object('search','','limit',250000,'filters', jsonb_build_array(
    jsonb_build_object('field','__website','operator','equals',
      'values', to_jsonb(array(select domain from dom limit 5000))))));

-- ---------------------------------------------------------------------------
-- RESULT, production 2026-09-03, 681,085 prospects / 418k companies, 2 vCPU.
-- Against the 10s ceiling the interactive functions declare:
--
--   company listing, 100 domains                        44 ms     0.4 %
--   company listing, 1,000 domains                     259 ms     2.6 %
--   company listing, 5,000 domains (the cap)           617 ms     6 %
--   pivot resolve, 5,000 domains -> company ids        157 ms     1.6 %
--   people under a 1,000-domain pivot + exact total    445 ms     4.5 %
--   people under a 5,000-domain pivot + exact total    712 ms     7 %
--   people, one substring filter                     1,071 ms    11 %
--   people, 30 substring filters                       854 ms     8.5 %
--   people, 60 substring filters (the cap)           1,740 ms    17 %
--   people, 5,000 exact domains as a people filter     886 ms     9 %
--   5,000-domain pivot + 5 title filters + total     2,508 ms    25 %
--
-- READ THE COUNTS TOO. Every people shape reports total_capped = true at
-- 50,000, which is not a coincidence and not cheating: 20260902000060 stops
-- counting there on purpose, and "Count them all" hands the rest to the worker.
-- Part of why these are fast is that the count is bounded; the page itself is
-- bounded by LIMIT regardless.
--
-- WHAT THIS DOES NOT MEASURE. Concurrency - these are one connection at a time.
-- Under 20 concurrent listings on 2026-09-02 the heaviest shape took about
-- 6.5 s of real query time, so contention, not shape, is what consumes the
-- budget. It also does not measure growth: section 2 targets 1.5 M prospects
-- against 681 k today, and scan-bound shapes grow roughly with the table, which
-- would put the worst combination near 5.5 s - inside the ceiling, with less
-- room than this table suggests.
--
-- 30 seconds of statement_timeout is deliberate: a shape that cannot finish
-- should say so rather than hang. None needed it.
