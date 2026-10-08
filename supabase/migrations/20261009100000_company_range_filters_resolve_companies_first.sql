-- People filtered by company Total Funding or Founded Year find the companies
-- first.
--
-- 2026-10-08: a People search with Total funding (every range ticked) timed
-- out. The range compiled to EXISTS (select from companies where co.id =
-- pi.company_id and <range>), which the planner ran as one company probe per
-- person, walking prospect_index newest first: 845k probes into a 4.5 GB table.
-- Only 9,876 companies have a funding amount, and both columns are indexed
-- (idx_companies_total_funding_amount, idx_companies_founded_year), so the
-- cheap order is the other way round: the matching companies from the index,
-- then their people through idx_prospect_index_company_id.
--
-- The range branch now compiles to pi.company_id IN (select co.id ...). Same
-- rows: a person with no company matched neither form, and the "Not known"
-- half stays a NOT EXISTS, OR-ed as before. Measured warm on production, every
-- funding range: count 453 ms -> 64 ms, first page 2.6 s -> 215 ms.
--
-- Only prospect_filter_sql_v1 changes; the row matcher already evaluates one
-- row at a time. The proof below checks both agree.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

do $patch$
declare
  v_definition text;
  v_anchor text := $old$          company_inner := format('exists (select 1 from public.companies co where co.id = pi.company_id and (%s))',
            array_to_string(value_parts, ' or '));$old$;
begin
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if position('pi.company_id in (select co.id from public.companies co where' in v_definition) = 0 then
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1: company range anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$          -- Companies first, then their people (20261009100000).
          company_inner := format('pi.company_id in (select co.id from public.companies co where (%s))',
            array_to_string(value_parts, ' or '));$new$);
  end if;
end;
$patch$;

-- Proof, read-only: the compiled filter and the row matcher agree on a sample,
-- for funding ranges with and without "Not known", and founded year.
do $proof$
declare
  v_filters jsonb;
  v_compiled bigint;
  v_matched bigint;
begin
  foreach v_filters in array array[
    '[{"field":"__company_total_funding","operator":"number_ranges","values":["0:1000000","1000001:5000000","500000001:"]}]'::jsonb,
    '[{"field":"__company_total_funding","operator":"number_ranges","values":["0:1000000","unknown"]}]'::jsonb,
    '[{"field":"__company_founded_year","operator":"number_ranges","values":["2005:2015"]}]'::jsonb
  ] loop
    if public.prospect_filter_sql_v1('', v_filters) not like '%pi.company_id in (select co.id from public.companies co where%' then
      raise exception 'Company range proof: the compiler still emits a per-row EXISTS for %', v_filters;
    end if;
    execute format('select count(*) filter (where %s), count(*) filter (where public.prospect_index_matches_v1(pi, '''', %L::jsonb))
                      from (select * from public.prospect_index pi limit 20000) pi',
      public.prospect_filter_sql_v1('', v_filters), v_filters) into v_compiled, v_matched;
    if v_compiled <> v_matched then
      raise exception 'Company range proof: compiled % vs matcher % for %', v_compiled, v_matched, v_filters;
    end if;
  end loop;
  raise notice 'Company range proof passed.';
end;
$proof$;
