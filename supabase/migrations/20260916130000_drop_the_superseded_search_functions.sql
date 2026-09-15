-- Drop nine superseded search functions.
--
-- WHY THEY MATTER AT ALL, GIVEN NOTHING CALLS THEM. verify-migrations check 133
-- says no SECURITY DEFINER search/filter function may be left untimed, and it
-- has been FAILING on these nine for as long as the check has existed. A report
-- with a permanent FAIL in it stops being read, and then the next real failure
-- arrives in a report nobody reads. That is the whole reason for this file.
--
-- They are also not harmless. Every one is SECURITY DEFINER, granted to
-- service_role, and has NO statement_timeout - so anything that did reach one
-- would run unbounded against 683,784 prospects. That is precisely the failure
-- 20260911090000 and 20260913020000 exist to prevent on their live successors.
--
-- WHAT IS BEING DROPPED, AND WHAT IS NOT. The live three are
-- search_prospect_workspace_v12, search_prospect_export_v5 and
-- filter_companies_v4, and none of them is touched. Note that
-- filter_companies_v4 is a DIFFERENT function from filter_companies - the
-- signature is stated explicitly below for exactly that reason, and the
-- assertions check the live three survive.
--
-- THE EVIDENCE, gathered on production before writing this:
--
--   1. No function body calls any of them. The only apparent hit was
--      resolve_company_action_selection_v1 containing "filter_companies", which
--      turned out to be a COMMENT mentioning filter_companies_v4. The check
--      below matches name||'(' rather than the bare name so it cannot be
--      fooled by that again.
--   2. Zero catalog dependents (pg_depend), so nothing is dropped with them.
--   3. Granted to postgres and service_role only - never anon or authenticated
--      - so the application is the only thing that could ever have called one.
--   4. The application calls exactly three RPCs from these families, by literal
--      name, with no version fallback: filter_companies_v4,
--      search_prospect_export_v5, search_prospect_workspace_v12.
--   5. 30 days of PostgREST logs: 180 RPC calls, of which
--      filter_companies_v4 113, search_prospect_workspace_v12 34, and NONE to
--      any of the nine.
--   6. The blue/green rollback target is the image before this one, which is
--      the same generation of the app and also calls v12. A rollback cannot
--      reach them either.
--
-- DROPPED WITH RESTRICT, WHICH IS THE DEFAULT AND IS DELIBERATE. If anything
-- does depend on one of these, the migration fails and nothing is lost. CASCADE
-- would turn a wrong premise into silent collateral damage.
-- ---------------------------------------------------------------------------

-- Each one exists, at exactly this signature. A typo here would otherwise drop
-- nothing and report success, leaving the FAIL in place with a migration
-- claiming to have fixed it.
do $$
declare
  v_target text;
  v_missing text[] := array[]::text[];
begin
  foreach v_target in array array[
    'public.filter_companies(text,text[],text[],text[],text,integer,integer)',
    'public.search_prospect_export_v2(text,jsonb,text,jsonb,timestamptz,text,integer,boolean)',
    'public.search_prospect_workspace(text,jsonb,integer,integer)',
    'public.search_prospect_workspace_v3(text,jsonb,text,text,integer,integer)',
    'public.search_prospect_workspace_v4(text,jsonb,text,text,integer,integer,text)',
    'public.search_prospect_workspace_v5(text,jsonb,text,text,integer,integer,text)',
    'public.search_prospect_workspace_v6(text,jsonb,text,text,integer,integer,text)',
    'public.search_prospect_workspace_v7(text,jsonb,text,text,integer,integer,text)',
    'public.search_prospect_workspace_v8(text,jsonb,text,text,integer,integer,text,jsonb)'
  ] loop
    if to_regprocedure(v_target) is null then
      v_missing := v_missing || v_target;
    end if;
  end loop;

  -- Already dropped by an earlier run: that is fine, and the assertions at the
  -- foot still have to pass.
  if cardinality(v_missing) = 9 then
    raise notice 'all nine superseded functions are already gone';
  elsif cardinality(v_missing) > 0 then
    raise exception 'these targets do not exist at the stated signature: %', array_to_string(v_missing, '; ');
  end if;
end $$;

-- Nothing calls them. Re-checked here rather than only before writing the file,
-- because the gap between the two is where a new caller would have appeared.
do $$
declare
  v_name text;
  v_callers text;
begin
  foreach v_name in array array['filter_companies', 'search_prospect_export_v2',
    'search_prospect_workspace', 'search_prospect_workspace_v3', 'search_prospect_workspace_v4',
    'search_prospect_workspace_v5', 'search_prospect_workspace_v6', 'search_prospect_workspace_v7',
    'search_prospect_workspace_v8'] loop
    -- name||'(' , not the bare name: "filter_companies_v4" contains
    -- "filter_companies" but not "filter_companies(", and a prose mention in a
    -- comment has no parenthesis after it either.
    select string_agg(n.nspname || '.' || p.proname, ', ')
      into v_callers
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not in ('pg_catalog', 'information_schema')
       and p.proname <> v_name
       and p.prosrc like '%' || v_name || '(%';
    if v_callers is not null then
      raise exception '% is still called by %', v_name, v_callers;
    end if;
  end loop;
end $$;

drop function if exists public.filter_companies(text,text[],text[],text[],text,integer,integer);
drop function if exists public.search_prospect_export_v2(text,jsonb,text,jsonb,timestamptz,text,integer,boolean);
drop function if exists public.search_prospect_workspace(text,jsonb,integer,integer);
drop function if exists public.search_prospect_workspace_v3(text,jsonb,text,text,integer,integer);
drop function if exists public.search_prospect_workspace_v4(text,jsonb,text,text,integer,integer,text);
drop function if exists public.search_prospect_workspace_v5(text,jsonb,text,text,integer,integer,text);
drop function if exists public.search_prospect_workspace_v6(text,jsonb,text,text,integer,integer,text);
drop function if exists public.search_prospect_workspace_v7(text,jsonb,text,text,integer,integer,text);
drop function if exists public.search_prospect_workspace_v8(text,jsonb,text,text,integer,integer,text,jsonb);

-- ---------------------------------------------------------------------------
-- The three the application actually calls are untouched, and still bounded.
-- This is the assertion that matters: the risk in this file is not dropping too
-- little, it is dropping the wrong one of a near-identical pair.
do $$
declare
  v_live text;
  v_cfg text[];
begin
  foreach v_live in array array[
    'public.filter_companies_v4(text,jsonb,text,jsonb,integer,integer,jsonb)',
    'public.search_prospect_export_v5(text,jsonb,text,jsonb,timestamptz,text,integer,boolean,text[])',
    'public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'
  ] loop
    if to_regprocedure(v_live) is null then
      raise exception 'the live function % is gone; this migration dropped the wrong one', v_live;
    end if;
    select p.proconfig into v_cfg from pg_proc p where p.oid = to_regprocedure(v_live);
    if not (array_to_string(v_cfg, ',') like '%statement_timeout%') then
      raise exception '% has no statement_timeout: %', v_live, v_cfg;
    end if;
  end loop;
end $$;

-- And verify-migrations check 133 now passes. Stated in the same terms as the
-- check, so this file cannot claim to have fixed something the report still
-- reports.
do $$
declare
  v_left text;
begin
  select string_agg(p.proname, ', ') into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef
     and (p.proname like 'search\_%' or p.proname like '%\_filter\_values%' or p.proname like 'filter\_companies%')
     and not coalesce(array_to_string(p.proconfig, ',') like '%statement_timeout%', false);
  if v_left is not null then
    raise exception 'still untimed after the drops: %', v_left;
  end if;
end $$;
