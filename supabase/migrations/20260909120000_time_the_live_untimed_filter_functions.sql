-- Put a statement timeout on the two live SECURITY DEFINER filter functions
-- that never got one.
--
-- scripts/verify-migrations.sql has a check named "no SECURITY DEFINER
-- search/filter function is left untimed", and it fails on production against
-- twelve functions. Ten of them are superseded versions that nothing calls any
-- more (search_prospect_workspace v3-v8, prospect_filter_values, filter_companies,
-- search_prospect_export_v2). Two are live:
--
--   filter_companies_v4        the Companies workspace listing and every company
--                              filter, called from app/api/companies/route.ts
--   prospect_filter_values_v2  the filter-value autocomplete, called from
--                              app/api/prospects/filter-values/route.ts
--
-- WHY THIS MATTERS MORE THAN IT LOOKS. These run as SECURITY DEFINER, and
-- service_role carries no statement_timeout of its own - authenticator's 120s
-- does not apply to a definer function's own execution context. So the only
-- bound on a slow company filter today is the client giving up, and lib/admission.ts
-- already records why that is not a bound at all: "abandoning an HTTP request
-- does not reliably cancel its database statement. Production measurement: an
-- export abandoned at 2.1s held its backend for 7.9 s." A pathological filter can
-- therefore hold a connection from a pool of 24 long after the browser has gone.
--
-- 30s matches prospect_filter_values_v3, the timed sibling of one of these.
--
-- WHY ALTER RATHER THAN CREATE OR REPLACE. A timeout is function metadata, so
-- ALTER sets it without restating the body. Re-declaring these bodies to add one
-- SET line would mean copying a deployed definition into a migration and hoping
-- the copy is faithful - which is the drift this repository has already been bitten
-- by once, when search_prospect_export_v1 carried its own copy of the filter CASE
-- and the copies diverged. Nothing here touches behaviour, arguments, or plans.

begin;

alter function public.filter_companies_v4(
  p_search text, p_filters jsonb, p_client_id text, p_people_scope jsonb,
  p_limit integer, p_offset integer, p_known_versions jsonb
) set statement_timeout = '30s';

alter function public.prospect_filter_values_v2(
  p_field text, p_search text, p_client_id text, p_limit integer
) set statement_timeout = '30s';

commit;
