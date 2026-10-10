-- Saved value lists (a pasted 1,500-domain list) filter by joining the list,
-- not by probing it once per row.
--
-- 2026-10-10: the Companies list timed out on a 1,500-domain website list
-- ("This filter combination took longer than the database allows"). A list
-- that large is stored as a filter set and compiled to
--   exists (select 1 from filter_set_values fsv
--            where fsv.filter_set_id = <set> and fsv.normalized_value = lower(<expr>))
-- which the planner ran as one probe per company - 449k probes, 7.2 s warm and
-- past the limit cold. The same predicate written as
--   lower(<expr>) in (select fsv.normalized_value from filter_set_values fsv
--                      where fsv.filter_set_id = <set>)
-- lets it read the set once and hash it: 301 ms, same 3,391 companies.
--
-- Same rows: a set filter allows equals only, never negation, and every
-- expression it compares is coalesced, so NULL never reaches the IN. Patched
-- in the Company compiler and in both places the People compiler emits it (a
-- person's own field, and the person's company).
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

do $patch$
declare
  v_function regprocedure;
  v_definition text;
  v_old constant text := $o$'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))'$o$;
  v_new constant text := $n$'lower(%2$s) in (select fsv.normalized_value from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %1$L::uuid)'$n$;
  v_expected integer;
begin
  foreach v_function in array array['public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure,
                                    'public.prospect_filter_sql_v1(text,jsonb)'::regprocedure] loop
    v_definition := pg_get_functiondef(v_function);
    v_expected := case when v_function = 'public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure then 1 else 2 end;
    if position(v_new in v_definition) = 0 then
      if (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old) <> v_expected then
        raise exception '%: expected the filter set predicate % times', v_function, v_expected;
      end if;
      execute replace(v_definition, v_old, v_new);
    end if;
  end loop;
end;
$patch$;

-- Proof, read-only: on the largest saved set, the compiled filter matches the
-- row matcher for companies.
do $proof$
declare
  v_set uuid;
  v_filters jsonb;
  v_compiled bigint;
  v_matched bigint;
begin
  select filter_set_id into v_set from prospect_filters.filter_set_values group by 1 order by count(*) desc limit 1;
  if v_set is null then
    raise notice 'Filter set proof: no saved sets - compile check only.';
    return;
  end if;
  v_filters := jsonb_build_array(jsonb_build_object('field', '__website', 'operator', 'equals', 'values', '[]'::jsonb, 'setId', v_set));
  if public.company_filter_sql_v3('', v_filters, false) not like '%in (select fsv.normalized_value%' then
    raise exception 'Filter set proof: the company compiler still probes per row';
  end if;
  execute format('select count(*) from public.companies c where %s', public.company_filter_sql_v3('', v_filters, false)) into v_compiled;
  execute format('select count(*) from public.companies c where exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L and fsv.normalized_value = lower(coalesce(c.domain, '''')))', v_set) into v_matched;
  if v_compiled <> v_matched then
    raise exception 'Filter set proof: % compiled vs % by the old predicate', v_compiled, v_matched;
  end if;
  raise notice 'Filter set proof passed (% companies).', v_compiled;
end;
$proof$;
