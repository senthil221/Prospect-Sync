-- Interactive reads get time limits sized to what they actually cost.
--
-- WHY IT MATTERS. PostgREST does not cancel a query when the browser gives up
-- (measured earlier: an export abandoned after 2.1 s held its backend for the
-- full 7.9 s). So a function's statement_timeout is the only bound on how long
-- an abandoned request keeps one of ~24 shared connections - and a limit far
-- above what the query really needs buys nothing but a longer pile-up when the
-- database is having a bad minute.
--
-- HOW THE NUMBERS WERE CHOSEN. pg_stat_statements on production, every call
-- since 2026-09-01, per function: the slowest call ever observed, and the
-- typical one. Each limit below is roughly 1.5-3x the slowest real call, so no
-- request that has ever succeeded would now fail:
--
--   function                              was    slowest seen    now
--   client_company_workspace_v2           30s    10.9 s (p95 3 s) 20s
--   prospect_filter_values_v3             30s     8.3 s           15s
--   prospect_title_taxonomy_v1            30s    28.6 s before 20260926150000
--                                                 fixed its client path (34-106 ms now);
--                                                 the unscoped call is the worker's,
--                                                 which runs under its own 300 s    15s
--   title_class_filter_values_v1          30s    61 ms since 20260926150000     10s
--   list_workspace                        30s     1.2 s           10s
--   client_company_prospects              30s     1.5 s           10s
--   dashboard_workspace                   30s    14.1 s before its count cache
--                                                 (20260923110000); 1-3 ms now,
--                                                 ~1.3 s on a cold recount       10s
--
-- WHAT IS DELIBERATELY NOT TIGHTENED. Three functions are genuinely slow -
-- filter_companies_v4 (35 s worst, 3 s average), find_duplicate_candidates
-- (61 s worst, 16 s average) and enrichment_preview_v1 (45 s worst). A lower
-- limit would turn their slow pages into errors without making them faster;
-- they need their own fixes. Bulk writes keep their limits too: the work they
-- do is bounded by the selection, and 20260926170000 already took their
-- re-indexing off the request.
--
-- The authenticator role's 120 s backstop - which covers every PostgREST query
-- that has no limit of its own, such as the client_summaries and
-- company_summaries views (7.3 s and 6 s worst) - is lowered to 30 s in the
-- bootstrap script, where role settings live.
-- ---------------------------------------------------------------------------

alter function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer) set statement_timeout = '20s';
alter function public.prospect_filter_values_v3 set statement_timeout = '15s';
alter function public.prospect_title_taxonomy_v1(text) set statement_timeout = '15s';
alter function public.title_class_filter_values_v1(text, text, text, integer) set statement_timeout = '10s';
alter function public.list_workspace set statement_timeout = '10s';
alter function public.client_company_prospects(text, text, integer, integer) set statement_timeout = '10s';
alter function public.dashboard_workspace() set statement_timeout = '10s';

do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('client_company_workspace_v2', '20s'), ('prospect_filter_values_v3', '15s'),
      ('prospect_title_taxonomy_v1', '15s'), ('title_class_filter_values_v1', '10s'),
      ('list_workspace', '10s'), ('client_company_prospects', '10s'), ('dashboard_workspace', '10s')
    ) as expected(fn, limit_value)
  loop
    if exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = r.fn
        and not (('statement_timeout=' || r.limit_value) = any(coalesce(p.proconfig, array[]::text[])))
    ) then
      raise exception '% did not take statement_timeout=%', r.fn, r.limit_value;
    end if;
  end loop;
end $$;
