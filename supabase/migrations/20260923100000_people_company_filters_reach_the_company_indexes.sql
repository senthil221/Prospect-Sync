-- People filtered by company industry or description use the company indexes.
--
-- WHAT WAS SLOW, MEASURED on production 2026-09-23. A People filter on the
-- company profile compiles to exists (select 1 from public.companies co where
-- co.id = pi.company_id and <predicate>). The planner already resolves that
-- company-first: it finds the matching companies, then probes
-- idx_prospect_index_company_id. The whole cost was finding the companies,
-- because the predicate read
--
--     coalesce(co.short_description, '') ilike '%blockchain%'
--
-- and idx_companies_short_description_trgm / idx_companies_industry_trgm index
-- the bare column, not the coalesce expression. Every such request did a
-- parallel sequential scan of all 446,492 companies, twice (count and page):
--
--     company lookup alone        coalesce form   bare column
--     description "blockchain"      1,844 ms         29-69 ms
--     description "software"        2,862 ms          564 ms
--     industry "software"             434 ms           42 ms
--
-- End to end, description filters took 3.5-4 s warm and 10.2 s cold - a 504.
--
-- WHY DROPPING THE COALESCE CHANGES NO RESULT. Inside the exists() the
-- predicate is always positive - not_contains is expressed as NOT EXISTS
-- around it - and every value is non-blank (blank values are dropped when
-- raw_values is built). For a non-blank v, '' ilike '%v%' is false and
-- NULL ilike '%v%' is null, which fails the where clause the same way. The
-- migration proves it on real rows below.
--
-- The coalesce stays everywhere else it is load-bearing: equals, empty and
-- not_empty, and prospect_index_matches_v1, which evaluates the same filter
-- row by row and still agrees with it.
--
-- NOT HERE. __company_technologies reads array_to_string(co.technologies),
-- which no index can serve (array_to_string is STABLE) - 1.3 s of company
-- scan, measured. Fixing that needs a new index, which is its own change.
-- ---------------------------------------------------------------------------

do $BODY$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_old constant text :=
E'        else
          company_contains_expr := company_expr;
        end if;';
  v_new constant text :=
E'        elsif field_key in (''__company_industry'', ''__company_description'') then
          -- The bare column, so the trigram GIN on it can serve the ilike: a
          -- NULL fails the positive match exactly as coalesce(..., '''') does.
          -- See 20260923100000.
          company_contains_expr := case field_key
            when ''__company_industry'' then ''co.industry''
            else ''co.short_description'' end;
        else
          company_contains_expr := company_expr;
        end if;';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer contains the contains branch this migration replaces';
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'prospect_filter_sql_v1 contains the replaced text more than once';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $BODY$;

-- ---------------------------------------------------------------------------
-- The compiled predicate is the bare column for contains and not_contains,
-- and keeps coalesce where it matters.
do $$
declare
  v_sql text;
begin
  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_description","operator":"contains","values":["blockchain"]}]'::jsonb);
  if position('co.short_description ilike' in v_sql) = 0 or position('coalesce' in v_sql) > 0 then
    raise exception 'description contains did not compile to the bare column: %', v_sql;
  end if;

  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_industry","operator":"not_contains","values":["mining"]}]'::jsonb);
  if position('not exists' in v_sql) = 0 or position('co.industry ilike' in v_sql) = 0 then
    raise exception 'industry not_contains must be NOT EXISTS over the bare column: %', v_sql;
  end if;

  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_industry","operator":"equals","values":["Mining"]}]'::jsonb);
  if position('coalesce(co.industry' in v_sql) = 0 then
    raise exception 'industry equals must keep its coalesce: %', v_sql;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Same people, on real rows. For each operator and term, the new compiled
-- predicate must match exactly the people the old coalesce form matched.
do $$
declare
  v_case record;
  v_new_sql text;
  v_old_sql text;
  v_new bigint;
  v_old bigint;
begin
  for v_case in
    select * from (values
      ('__company_industry', 'contains', 'mining', 'co.industry'),
      ('__company_industry', 'not_contains', 'software', 'co.industry'),
      ('__company_description', 'contains', 'blockchain', 'co.short_description'),
      ('__company_description', 'not_contains', 'blockchain', 'co.short_description')
    ) as c(field, op, term, col)
  loop
    v_new_sql := public.prospect_filter_sql_v1('',
      jsonb_build_array(jsonb_build_object('field', v_case.field, 'operator', v_case.op,
        'values', jsonb_build_array(v_case.term))));
    v_old_sql := format('%sexists (select 1 from public.companies co where co.id = pi.company_id and ((coalesce(%s, %L) ilike %L)))',
      case when v_case.op = 'not_contains' then 'not ' else '' end,
      v_case.col, '', '%' || v_case.term || '%');

    execute format('select count(*) from public.prospect_index pi where %s', v_new_sql) into v_new;
    execute format('select count(*) from public.prospect_index pi where %s', v_old_sql) into v_old;
    if v_new <> v_old then
      raise exception '% % "%" now matches % people, previously %',
        v_case.field, v_case.op, v_case.term, v_new, v_old;
    end if;
  end loop;
end $$;
