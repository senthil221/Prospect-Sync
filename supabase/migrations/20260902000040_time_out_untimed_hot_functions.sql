-- Give the last three untimed hot functions a statement timeout.
--
-- Every other function on the read path already carries one:
-- search_prospect_workspace_v12 20s, search_prospect_export_v4 60s,
-- title_class_filter_values_v1 30s, company_filter_values_v2 30s. These three
-- were left with the session default, which for the `authenticator` login is
-- 120s. A single expensive call therefore holds a PostgREST pool connection for
-- two minutes, and the browser that asked for it gave up long before -- so the
-- work continues with nobody waiting for the answer. At 20 concurrent users
-- that is how the pool collapses.
--
--   linked_prospect_total_v1        count(*) over prospect_index for the
--                                   Companies tab's linked-prospect total
--   prospect_filter_values_v3       filter-value autocomplete; the top entry in
--                                   pg_stat_statements by call count
--   search_prospect_export_v1       the superseded export page (the route now
--                                   calls v4 for both scoped and unscoped
--                                   exports); still reachable and still untimed
--                                   until parity retires it
--
-- ALTER FUNCTION ... SET, not CREATE OR REPLACE: the setting is a property of
-- the function, so the bodies are not transcribed here and cannot drift. The
-- trade-off is that a future CREATE OR REPLACE of any of these three without a
-- SET statement_timeout clause silently drops it again -- scripts/verify-migrations.sql
-- checks for that.
--
-- The values match the existing siblings rather than the eventual targets in
-- section 8.2 of the scalability plan (suggestions 3s, interactive counts 10s).
-- A ceiling where there is none today is the fix; lowering it is a separate
-- change that needs the Phase 0 latency measurements behind it, so that a
-- working query is not newly refused on the strength of a guess.

begin;

-- Interactive count, alongside search_prospect_workspace_v12's 20s.
alter function public.linked_prospect_total_v1(text)
  set statement_timeout = '20s';

-- Autocomplete, alongside title_class_filter_values_v1's 30s.
alter function public.prospect_filter_values_v3(text, text, text, integer)
  set statement_timeout = '30s';

-- Export page, alongside search_prospect_export_v4's 60s and the route's
-- maxDuration = 60.
alter function public.search_prospect_export_v1(text, jsonb, text, timestamptz, text, integer, boolean)
  set statement_timeout = '60s';

commit;
