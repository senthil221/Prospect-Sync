-- prospect_filter_values and prospect_filter_values_v2 are unreachable.
--
-- app/api/prospects/filter-values called them only when the RPC above them was
-- MISSING from the database - PGRST202 or 42883 - as a cushion for an app
-- deployed ahead of its migrations. That state cannot occur here: update.sh
-- applies migrations before the candidate container is started, and a rollback
-- deliberately does not undo them, so the database is never behind the app.
-- pg_stat_statements agrees: zero executions of either, against 41 of v3.
--
-- They are worth removing rather than leaving parked, because both carry the
-- predicate that 20260910150000 was written to fix -
--
--   btrim(coalesce(p_search, '')) = '' or col ilike '%' || p_search || '%'
--
-- - in a SECURITY DEFINER function with SET clauses, which is the exact
-- combination that cannot be inlined and so gets a generic plan that turns the
-- unfiltered case into a sequential scan. Dead code carrying a known-bad
-- pattern is where the next copy of that bug comes from.
--
-- title_class_filter_values_v1 carries the same predicate and is NOT dropped:
-- it is the live handler for the three classifier fields in that route, not a
-- fallback. It measures 850-875ms identically under custom and generic plans,
-- because it aggregates every row whatever the plan, so the rewrite that helped
-- linked_prospect_total_v1 would buy nothing there.

begin;

-- Never drop the fallbacks on the word of a migration alone. If v3 is not there
-- and working, these two are load-bearing and this migration is wrong.
do $$
declare
  v_rows integer;
begin
  if to_regprocedure('public.prospect_filter_values_v3(text, text, text, integer)') is null then
    raise exception 'prospect_filter_values_v3 is missing; the fallbacks are still load-bearing';
  end if;
  select count(*) into v_rows
  from public.prospect_filter_values_v3('__company', '', null, 5);
  if v_rows = 0 then
    raise exception 'prospect_filter_values_v3 returned no values; refusing to drop its fallbacks';
  end if;
end;
$$;

drop function if exists public.prospect_filter_values(text, text, text, integer);
drop function if exists public.prospect_filter_values_v2(text, text, text, integer);

do $$
begin
  if to_regprocedure('public.prospect_filter_values(text, text, text, integer)') is not null then
    raise exception 'prospect_filter_values survived the drop';
  end if;
  if to_regprocedure('public.prospect_filter_values_v2(text, text, text, integer)') is not null then
    raise exception 'prospect_filter_values_v2 survived the drop';
  end if;
  -- The one that has to keep working.
  if to_regprocedure('public.prospect_filter_values_v3(text, text, text, integer)') is null then
    raise exception 'prospect_filter_values_v3 was dropped by mistake';
  end if;
  if to_regprocedure('public.title_class_filter_values_v1(text, text, text, integer)') is null then
    raise exception 'title_class_filter_values_v1 was dropped by mistake';
  end if;
end;
$$;

commit;
