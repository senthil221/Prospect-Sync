-- Stop one slow filter from taking the workspace down for everyone.
--
-- Reported symptom was three errors at once on the Companies tab with Company
-- description enabled:
--
--   Failed to execute 'json' on 'Response': Unexpected end of JSON input
--   Timed out acquiring connection from connection pool
--   canceling statement due to statement timeout
--
-- They are one event, not three bugs. PostgREST has PGRST_DB_POOL=15
-- connections for the whole application and waits only
-- PGRST_DB_POOL_ACQUISITION_TIMEOUT=10s for a free one. A slow listing holds a
-- connection for its entire run; the page issues several requests at once and
-- the user reloads because it is slow; within seconds all 15 are held. Every
-- other request then fails on pool acquisition -- including ones that would have
-- returned in milliseconds -- and the ones that return an empty body surface as
-- the JSON parse error. So a single expensive filter degrades the product for
-- every user, not just the person who ran it.
--
-- 20260829160000 raised these two functions to a 45s statement_timeout so that
-- Boolean search (~21s, and the one operator still without an index) would
-- complete instead of always failing. Against a 15-connection pool that was the
-- wrong trade: it let one request monopolise a connection for 45 seconds.
--
-- 30s keeps Boolean working with headroom while cutting the worst-case hold by a
-- third. Everything else now finishes in under three seconds and never comes
-- near either bound, so this only ever bites the genuinely pathological query --
-- which is exactly the one that should be shed rather than allowed to queue
-- behind itself.
--
-- ALTER FUNCTION rather than CREATE OR REPLACE on purpose: the bodies belong to
-- 20260831130211, and redefining them here would silently roll that back.

begin;

alter function public.filter_companies_v4(text, jsonb, text, jsonb, integer, integer)
  set statement_timeout = '30s';

alter function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer)
  set statement_timeout = '30s';

commit;
