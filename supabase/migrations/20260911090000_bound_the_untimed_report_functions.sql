-- Four functions behind user-facing tabs had no statement_timeout at all, and
-- one has a ceiling it is already touching. Measured against real application
-- traffic (service_role only - my own psql diagnostics excluded):
--
--   function                      timeout   mean      max      calls
--   find_duplicate_candidates     NONE      38,240ms  60,747ms   23
--   data_quality_overview         NONE      12,234ms  34,215ms   23
--   analyze_prospect_index        NONE      15,805ms  26,047ms   13
--   dashboard_workspace           NONE       1,068ms  12,560ms  125
--   prospect_index_drift          30s       13,335ms  29,751ms   17
--
-- prospect_index_drift is 249ms from its own ceiling. At any more data it stops
-- working, and the Data Quality tab loses half its content - so this raises it
-- rather than leaving a feature to fail on the next import.
--
-- WHY THIS MATTERS MORE THAN IT LOOKS. An untimed query is not just slow: it
-- holds a PostgREST connection with nothing able to reclaim it. The pool is 24.
-- On 2026-09-10 at 18:00 UTC a Data Quality open ran data_quality_overview and
-- prospect_index_drift together; ordinary /api/prospects requests went from ~1s
-- to 5-8s under the contention, the interactive admission queue filled, and
-- browsing returned 503 and 500 to people who had never opened that tab. The
-- admission slots added alongside this migration cap the concurrency; these
-- timeouts cap the duration. Neither alone is enough.
--
-- The ceilings are set ABOVE each function's observed maximum, not below it.
-- The point is to stop a runaway holding a connection forever, not to break a
-- feature that legitimately takes half a minute. Nothing that works today
-- starts failing because of this file.

begin;

-- 60.7s observed. 120s leaves room for growth in a near-quadratic join while
-- still being a bound; the two-slot analytics queue is what stops it hurting
-- anyone else in the meantime.
alter function public.find_duplicate_candidates(integer) set statement_timeout = '120s';

-- 34.2s observed.
alter function public.data_quality_overview() set statement_timeout = '90s';

-- 26.0s observed. Runs on the import-completion path, where finishing matters
-- more than latency.
alter function public.analyze_prospect_index() set statement_timeout = '120s';

-- 12.6s observed on a page load. Tighter, because the dashboard hanging for a
-- minute is worse than the dashboard saying it could not load.
alter function public.dashboard_workspace() set statement_timeout = '30s';

-- 29.75s observed against a 30s ceiling.
alter function public.prospect_index_drift() set statement_timeout = '90s';

do $$
declare
  v record;
  v_expected text;
begin
  for v in
    select * from (values
      ('public.find_duplicate_candidates(integer)', 'statement_timeout=120s'),
      ('public.data_quality_overview()',            'statement_timeout=90s'),
      ('public.analyze_prospect_index()',           'statement_timeout=120s'),
      ('public.dashboard_workspace()',              'statement_timeout=30s'),
      ('public.prospect_index_drift()',             'statement_timeout=90s')
    ) as t(signature, expected)
  loop
    if to_regprocedure(v.signature) is null then
      raise exception 'timed a function that does not exist: %', v.signature;
    end if;
    select array_to_string(proconfig, ',') into v_expected
    from pg_proc where oid = to_regprocedure(v.signature);
    if v_expected is null or position(v.expected in v_expected) = 0 then
      raise exception '% did not take its timeout: proconfig is %', v.signature, coalesce(v_expected, '<null>');
    end if;
  end loop;
end;
$$;

-- ALTER FUNCTION carries no body, so nothing here can drift from the deployed
-- definition - the same reason 20260902000040 used ALTER rather than replacing.
commit;
