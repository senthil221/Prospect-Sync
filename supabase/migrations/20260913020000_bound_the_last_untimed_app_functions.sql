-- The eight SECURITY DEFINER functions the application calls that still had no
-- statement_timeout of their own. Measured 2026-09-13 against production:
--
--   function                                  timeout   observed max   source
--   apply_email_provider_scan_v1(jsonb)       NONE          5,260ms    pg_stat_statements
--   client_company_prospects(...)             NONE              0ms    pg_stat_statements
--   complete_company_import_v1(text)          NONE              0ms    pg_stat_statements
--   enqueue_reindex(text[],text)              NONE              0ms    pg_stat_statements
--   export_parts_present_v1(uuid)             NONE              2ms    pg_stat_statements
--   import_company_batch_v2(...)              NONE              0ms    pg_stat_statements
--   merge_prospects(text,text)                NONE              0ms    pg_stat_statements
--   purge_system_event_log_v1()               NONE              2ms    pg_stat_statements
--
-- READ THE MAXIMA WITH CARE. pg_stat_statements was last reset 2026-09-01 and
-- track_functions is 'none', so pg_stat_user_functions is empty and proves
-- nothing about whether these run. These are cheap functions today; the reason
-- to bound them is what they become at 2M rows, not what they cost now.
--
-- WHAT THIS IS AND IS NOT WORTH. Nothing here is currently unbounded: the
-- authenticator role carries statement_timeout=120s, and every one of these is
-- reached through PostgREST as that role, so 120s is already the real ceiling.
-- So the honest accounting is:
--
--   - The three set BELOW 120s are a real change. They make an interactive
--     endpoint fail visibly instead of holding one of 24 pool connections for
--     two minutes.
--   - The five set AT 120s change no behaviour today. They state the bound at
--     the function instead of inheriting it from a role setting somewhere else,
--     so that changing the role cannot silently un-bound an import path.
--
-- Calling the second group a fix would be overselling it. It is documentation
-- that the database enforces.
--
-- WHY A TIMEOUT IS SAFE ON THESE SPECIFICALLY. None of the eight contains an
-- EXCEPTION handler (checked: prosrc has no 'exception when' in any of them),
-- so a cancellation propagates as 57014 rather than being swallowed and turned
-- into a committed wrong answer or a job marked permanently failed.
--
--   This is not a general rule, and the counter-example matters:
--   prospect_operations.run_queue_unit_v1 also has no statement_timeout, and it
--   must keep it that way. Its handler is EXCEPTION WHEN OTHERS OR
--   query_canceled followed by fail_v1(), so a cancelled statement there does
--   not retry - it marks the export or operation FAILED. Adding a ceiling to it
--   would convert "this export is slow" into "this export is broken", which is
--   the opposite of what was asked for. It is already bounded anyway: the
--   prospect_ops_worker role has statement_timeout=5min and rolconnlimit=2, so
--   it cannot outlive five minutes and cannot exhaust the pool.
--
-- The ceilings are set ABOVE each observed maximum with wide margin. Nothing
-- that works today starts failing because of this file.

begin;

-- Baseline: refuse to run if any of these already carries a timeout, which
-- would mean the premise of this migration is stale.
do $$
declare
  v_sig text;
  v_cfg text;
begin
  foreach v_sig in array array[
    'public.apply_email_provider_scan_v1(jsonb)',
    'public.client_company_prospects(text,text,integer,integer)',
    'public.complete_company_import_v1(text)',
    'public.enqueue_reindex(text[],text)',
    'public.export_parts_present_v1(uuid)',
    'public.import_company_batch_v2(text,jsonb,integer)',
    'public.merge_prospects(text,text)',
    'public.purge_system_event_log_v1()'
  ]
  loop
    if to_regprocedure(v_sig) is null then
      raise exception 'cannot bound a function that does not exist: %', v_sig;
    end if;
    select array_to_string(proconfig, ',') into v_cfg from pg_proc where oid = to_regprocedure(v_sig);
    if coalesce(v_cfg, '') like '%statement_timeout=%' then
      raise exception '% already has a timeout (%); this migration assumed it did not', v_sig, v_cfg;
    end if;
  end loop;
end;
$$;

-- Interactive. A company drawer that hangs for two minutes is worse than one
-- that says it could not load. Measured 341ms for the equivalent read against
-- the worst company in the table (5,265 prospects), so 30s is ~88x headroom.
alter function public.client_company_prospects(text, text, integer, integer) set statement_timeout = '30s';

-- Interactive, and trivially cheap: 2ms observed. It answers "which parts of
-- this export exist yet", polled while a download is being prepared.
alter function public.export_parts_present_v1(uuid) set statement_timeout = '15s';

-- A queue insert on the write path. Sub-millisecond observed.
alter function public.enqueue_reindex(text[], text) set statement_timeout = '30s';

-- 5,260ms observed on a bulk apply. Scales with the batch handed to it.
alter function public.apply_email_provider_scan_v1(jsonb) set statement_timeout = '60s';

-- Writes that scale with the size of what the user is merging or purging.
alter function public.merge_prospects(text, text) set statement_timeout = '60s';
alter function public.purge_system_event_log_v1() set statement_timeout = '60s';

-- Import paths. Finishing matters more than latency here, so these get the
-- same 120s the role already imposes - stated at the function so that it
-- survives a change to the role.
alter function public.complete_company_import_v1(text) set statement_timeout = '120s';
alter function public.import_company_batch_v2(text, jsonb, integer) set statement_timeout = '120s';

do $$
declare
  v record;
  v_cfg text;
begin
  for v in
    select * from (values
      ('public.client_company_prospects(text,text,integer,integer)', 'statement_timeout=30s'),
      ('public.export_parts_present_v1(uuid)',                       'statement_timeout=15s'),
      ('public.enqueue_reindex(text[],text)',                        'statement_timeout=30s'),
      ('public.apply_email_provider_scan_v1(jsonb)',                 'statement_timeout=60s'),
      ('public.merge_prospects(text,text)',                          'statement_timeout=60s'),
      ('public.purge_system_event_log_v1()',                         'statement_timeout=60s'),
      ('public.complete_company_import_v1(text)',                    'statement_timeout=120s'),
      ('public.import_company_batch_v2(text,jsonb,integer)',         'statement_timeout=120s')
    ) as t(signature, expected)
  loop
    select array_to_string(proconfig, ',') into v_cfg
    from pg_proc where oid = to_regprocedure(v.signature);
    if v_cfg is null or position(v.expected in v_cfg) = 0 then
      raise exception '% did not take its timeout: proconfig is %', v.signature, coalesce(v_cfg, '<null>');
    end if;
    -- ALTER FUNCTION ... SET replaces proconfig wholesale if misused. The
    -- search_path on these is what keeps a SECURITY DEFINER function from
    -- resolving a name against a caller-controlled schema; losing it would be
    -- a privilege-escalation hole, so this checks rather than trusts.
    if position('search_path=' in v_cfg) = 0 then
      raise exception '% lost its pinned search_path: proconfig is %', v.signature, v_cfg;
    end if;
  end loop;
end;
$$;

-- run_queue_unit_v1 is deliberately absent. See the note above: its exception
-- handler turns a cancellation into a failed job, and it is already bounded by
-- the prospect_ops_worker role.
do $$
declare
  v_cfg text;
begin
  select array_to_string(proconfig, ',') into v_cfg
  from pg_proc where oid = to_regprocedure('prospect_operations.run_queue_unit_v1(text,text,integer)');
  if coalesce(v_cfg, '') like '%statement_timeout=%' then
    raise exception 'run_queue_unit_v1 must not be given a statement_timeout: %', v_cfg;
  end if;
end;
$$;

-- ALTER FUNCTION carries no body, so nothing here can drift from the deployed
-- definition.
commit;
