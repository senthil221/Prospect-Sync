-- A People filter on company technologies is served by an index.
--
-- WHAT WAS SLOW, MEASURED on production 2026-09-23. "Technologies contains
-- salesforce" took 2.4 s warm and 3.2 s cold end to end, of which 1.3 s was a
-- sequential scan of all 446,492 companies evaluating
--
--     coalesce(array_to_string(co.technologies, ' | '), '') ilike '%salesforce%'
--
-- per row, twice per request (count and page). There was nothing for it to use:
-- idx_companies_technologies_gin indexes the array's elements, which serves
-- equals (&&) but not a substring, and array_to_string is declared STABLE, so no
-- expression index can be built over it.
--
-- THE FIX. public.company_technologies_text_v1 is the same join, declared
-- IMMUTABLE - which it is for text[]: text's output function does not depend on
-- any setting. A trigram GIN over it lets contains/not_contains probe the index,
-- the way 20260923100000 did for industry and description, and the compiled
-- predicate calls the function by name so the planner can match the index.
--
-- SAME RESULTS. The function returns exactly array_to_string(technologies,
-- ' | '), NULL for a NULL array; inside the positive exists() a NULL fails the
-- match exactly as coalesce(..., '') did, and values are never blank. Proven on
-- real rows below.
--
-- THE LOCK. A plain CREATE INDEX holds a SHARE lock on companies while it
-- builds - reads continue, company writes wait. The build was measured inside a
-- rolled-back transaction on production before this was committed; see the
-- commit message for the figure. lock_timeout makes this migration give up
-- rather than queue behind a long import and stall every company write behind
-- itself; a failed attempt rolls back whole and the next deploy retries.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.company_technologies_text_v1(p_technologies text[])
returns text
language sql
immutable
parallel safe
as $$ select array_to_string(p_technologies, ' | ') $$;

comment on function public.company_technologies_text_v1(text[]) is
  'array_to_string(technologies, '' | '') declared IMMUTABLE so a trigram index can be built over it; the People technologies filter calls it by name.';

create index if not exists idx_companies_technologies_text_trgm
  on public.companies using gin (public.company_technologies_text_v1(technologies) gin_trgm_ops);

do $BODY$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_old constant text :=
E'        elsif field_key in (''__company_industry'', ''__company_description'') then';
  v_old_case constant text :=
E'          company_contains_expr := case field_key
            when ''__company_industry'' then ''co.industry''
            else ''co.short_description'' end;';
  v_new constant text :=
E'        elsif field_key in (''__company_industry'', ''__company_description'', ''__company_technologies'') then';
  v_new_case constant text :=
E'          company_contains_expr := case field_key
            when ''__company_industry'' then ''co.industry''
            when ''__company_technologies'' then ''public.company_technologies_text_v1(co.technologies)''
            else ''co.short_description'' end;';
begin
  if position(v_old in v_def) = 0 or position(v_old_case in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer contains the bare-column branch 20260923100000 added';
  end if;
  v_def := replace(replace(v_def, v_old, v_new), v_old_case, v_new_case);
  execute v_def;
end $BODY$;

-- ---------------------------------------------------------------------------
-- The function is the old expression, the filter compiles to it, and the
-- planner uses the index for it.
do $$
declare
  v_sql text;
  v_plan text;
begin
  if exists (
    select 1 from public.companies
    where public.company_technologies_text_v1(technologies) is distinct from array_to_string(technologies, ' | ')
    limit 1
  ) then
    raise exception 'company_technologies_text_v1 differs from array_to_string on real rows';
  end if;

  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_technologies","operator":"contains","values":["salesforce"]}]'::jsonb);
  if position('public.company_technologies_text_v1(co.technologies) ilike' in v_sql) = 0 then
    raise exception 'technologies contains did not compile to the indexed expression: %', v_sql;
  end if;

  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_technologies","operator":"equals","values":["Salesforce"]}]'::jsonb);
  if position('co.technologies &&' in v_sql) = 0 then
    raise exception 'technologies equals must keep its array overlap: %', v_sql;
  end if;
end $$;

-- Same people, on real rows, for both polarities.
do $$
declare
  v_case record;
  v_new bigint;
  v_old bigint;
begin
  for v_case in
    select * from (values ('contains', 'salesforce'), ('not_contains', 'salesforce'), ('contains', 'hubspot')) as c(op, term)
  loop
    execute format('select count(*) from public.prospect_index pi where %s',
      public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
        'field', '__company_technologies', 'operator', v_case.op, 'values', jsonb_build_array(v_case.term)))))
      into v_new;
    execute format('select count(*) from public.prospect_index pi where %sexists (select 1 from public.companies co where co.id = pi.company_id and ((coalesce(array_to_string(co.technologies, %L), %L) ilike %L)))',
      case when v_case.op = 'not_contains' then 'not ' else '' end, ' | ', '', '%' || v_case.term || '%')
      into v_old;
    if v_new <> v_old then
      raise exception 'technologies % "%" now matches % people, previously %', v_case.op, v_case.term, v_new, v_old;
    end if;
  end loop;
end $$;
