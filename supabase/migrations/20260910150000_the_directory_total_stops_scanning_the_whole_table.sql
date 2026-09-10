-- /api/companies timed out at 20s twice in two days, and every logged request
-- to it today was over 5s: 7,897ms, 20,129ms (504) and 10,400ms. The endpoint
-- runs three queries in parallel; two answer in ~100ms and this one averaged
-- 1,301ms with a 27,291ms maximum over 323 calls. It is the whole problem.
--
-- WHY IT IS BIMODAL. The function is SECURITY DEFINER with SET clauses, so it
-- cannot be inlined, so its plan is cached and PostgreSQL switches to a GENERIC
-- plan after about five calls. A generic plan cannot fold `$1 = ''` away, so the
-- empty-search branch - which is every ordinary page load - was planned as if it
-- had to evaluate two ILIKEs per row:
--
--   custom plan   Index Only Scan, Heap Fetches 0, 0 reads          ~80ms
--   generic plan  Parallel Seq Scan, 155,322 reads (the whole 1.3GB) ~500ms warm
--
-- Warm, that seq scan costs 500ms. Cold - and prospect_index is 1,332MB against
-- 2,048MB of shared_buffers, with import and classification batches churning the
-- cache continuously - those 155,322 reads are physical, and that is the 27s.
--
-- Branching in plpgsql instead of OR-ing the parameter into the predicate gives
-- each case its own plan. The empty branch then has no parameter in it at all,
-- so its plan is the index-only scan under every plan mode, not just the lucky
-- ones. Measured under force_generic_plan, which is the failing case:
--
--   empty    155,322 reads -> 0 reads, 77ms
--   search   155,322 reads -> 33,346 reads, 1,155ms
--
-- The search branch improves too, and for a second reason: the trigram indexes
-- idx_prospect_index_company_trgm and idx_prospect_index_company_domain_trgm
-- already existed but were unreachable, because an OR that includes a test on
-- the parameter cannot be answered by an index on the columns. Separated, the
-- planner picks them up as a bitmap OR.
--
-- The 20s statement_timeout is deliberately carried across. CREATE OR REPLACE
-- drops proconfig, and 20260902000040 exists precisely to put it there; losing
-- it here would undo that migration silently and only verify-migrations.sql
-- would notice.

begin;

create or replace function public.linked_prospect_total_v1(p_search text default ''::text)
returns bigint
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '20s'
as $function$
declare
  v_search text := btrim(coalesce(p_search, ''));
begin
  -- No parameter in this predicate, so it plans as an index-only scan over
  -- idx_prospect_index_company_id (12MB) rather than the 1,332MB heap.
  if v_search = '' then
    return (
      select count(*)::bigint
      from public.prospect_index pi
      where pi.company_id is not null
    );
  end if;

  return (
    select count(*)::bigint
    from public.prospect_index pi
    where pi.company_id is not null
      and (pi.company_name ilike '%' || v_search || '%'
        or pi.company_domain ilike '%' || v_search || '%')
  );
end;
$function$;

comment on function public.linked_prospect_total_v1(text) is
  'Prospects that belong to a company, optionally narrowed by company name or domain. Branches so the unfiltered total stays index-only under a generic plan.';

-- CREATE OR REPLACE keeps existing privileges; restated so this file is the
-- whole story rather than a diff against 20260901000050.
revoke execute on function public.linked_prospect_total_v1(text) from public, anon, authenticated;
grant execute on function public.linked_prospect_total_v1(text) to service_role;

-- The index-only scan above is only fast while the visibility map is current -
-- a stale map turns it back into heap fetches, which is the other half of what
-- made this slow: the map had drifted to 92.3% and the scan was doing 63,085
-- heap fetches (232ms) until a manual VACUUM took it to 100% (69ms, 0 fetches).
--
-- prospect_index takes continuous inserts and updates from the import and
-- classification workers. On the defaults autovacuum waits for 20% of 682,585
-- rows - about 136,000 - before it runs, so the map spends most of its life
-- stale. insert_scale_factor matters as much as the vacuum one here: inserts
-- leave no dead tuples to trigger a vacuum but do leave pages not-all-visible.
alter table public.prospect_index set (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02
);

-- A rewrite that returns a different number is worse than a slow one.
do $$
declare
  v_expected_total bigint;
  v_expected_search bigint;
  v_actual_total bigint;
  v_actual_search bigint;
  v_config text[];
begin
  select count(*)::bigint into v_expected_total
  from public.prospect_index pi where pi.company_id is not null;

  select count(*)::bigint into v_expected_search
  from public.prospect_index pi
  where pi.company_id is not null
    and (pi.company_name ilike '%tech%' or pi.company_domain ilike '%tech%');

  v_actual_total := public.linked_prospect_total_v1('');
  v_actual_search := public.linked_prospect_total_v1('tech');

  if v_actual_total <> v_expected_total then
    raise exception 'unfiltered total changed: got %, expected %', v_actual_total, v_expected_total;
  end if;
  if v_actual_search <> v_expected_search then
    raise exception 'search total changed: got %, expected %', v_actual_search, v_expected_search;
  end if;
  -- Whitespace and null must keep meaning "no search", as the old btrim/coalesce did.
  if public.linked_prospect_total_v1('   ') <> v_expected_total then
    raise exception 'a whitespace search no longer means unfiltered';
  end if;
  if public.linked_prospect_total_v1(null) <> v_expected_total then
    raise exception 'a null search no longer means unfiltered';
  end if;

  -- 20260902000040 put this timeout here; CREATE OR REPLACE must not have lost it.
  select proconfig into v_config from pg_proc
  where oid = to_regprocedure('public.linked_prospect_total_v1(text)');
  if not (v_config @> array['statement_timeout=20s']) then
    raise exception 'the 20s statement timeout did not survive the replace: %', v_config;
  end if;
  if not (v_config @> array['search_path=public']) then
    raise exception 'search_path did not survive the replace: %', v_config;
  end if;
end;
$$;

commit;
