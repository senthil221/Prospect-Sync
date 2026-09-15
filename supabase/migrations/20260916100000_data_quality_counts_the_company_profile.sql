-- Three more Data Quality checks: # employees, company keywords, company
-- description.
--
-- The tab counted six gaps, all of them person-level or company-identity
-- (email, website, company, title, LinkedIn, staleness). The three added here
-- are the company PROFILE fields the targeting filters actually key on, and
-- they are the largest gaps in the database - so the tab was quietly reporting
-- a cleaner picture than the data supports.
--
-- EVERY TILE OPENS ONTO EXACTLY WHAT IT COUNTED. That rule is stated at length
-- in lib/quality-issues.ts, and it is the reason these three could not be added
-- before 20260916090000: two of them had no People filter to point at. The
-- predicates below are written as the compiler writes them, not as they would
-- read most naturally, so the number and the button cannot drift:
--
--   # employees            __employee_count  number_ranges ["unknown"]
--     -> employee_count_min is null and employee_count_max is null
--   company keywords       __company_keywords  empty
--     -> btrim(coalesce(array_to_string(keywords, ' | '), '')) = ''
--   company description    __company_description  empty
--     -> btrim(coalesce(short_description, '')) = ''
--
-- Keywords is counted through array_to_string rather than array_length because
-- that is what the filter tests: a keywords array holding one empty string has
-- length 1 and is empty to the filter, and the two would have disagreed on
-- exactly those rows. The assertion at the foot of this file is what would have
-- caught that, and it is run against the whole table, not a sample.
--
-- A prospect with no company at all counts as missing all three, which is what
-- the filters answer too - the join is a LEFT JOIN here and a NOT EXISTS there,
-- and both make an absent company indistinguishable from a blank field.
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regprocedure('public.data_quality_overview()') is null then
    raise exception 'data_quality_overview is not deployed; nothing to patch';
  end if;
  -- Ordering matters: the two empty checks need filters that did not exist
  -- before 20260916090000, and a tile with no button breaks the tab's one rule.
  if public.prospect_filter_sql_v1('', '[{"field":"__company_keywords","operator":"empty","values":[]}]'::jsonb)
     not like '%companies%' then
    raise exception 'the People compiler does not know __company_keywords yet; apply 20260916090000 first';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The overview. Spliced, because this function has been redefined once already
-- (20260910093000) and restating it would take that fix back out.
do $patch$
declare
  v_def text;
  v_marker constant text := $m$    'missingDomain', count(*) filter (where trim(coalesce(c.domain, '')) = ''),$m$;
  v_replacement constant text := $r$    'missingDomain', count(*) filter (where trim(coalesce(c.domain, '')) = ''),
    'missingEmployees', count(*) filter (where c.employee_count_min is null and c.employee_count_max is null),
    'missingCompanyKeywords', count(*) filter (where btrim(coalesce(array_to_string(c.keywords, ' | '), '')) = ''),
    'missingCompanyDescription', count(*) filter (where btrim(coalesce(c.short_description, '')) = ''),$r$;
begin
  select pg_get_functiondef('public.data_quality_overview()'::regprocedure) into v_def;

  if position(v_replacement in v_def) > 0 then
    return;
  end if;
  if position(v_marker in v_def) = 0 then
    raise exception 'data_quality_overview no longer counts missingDomain in the expected shape; refusing to patch blindly';
  end if;

  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- ---------------------------------------------------------------------------
-- Recompute the stored snapshot now.
--
-- refresh_dashboard_snapshots_v1 SKIPS a key whose data_version still matches,
-- which is the whole point of the cache - so without this the tab would read
-- three zeroes, show all three checks as "Clear", and stay that way until the
-- next unrelated write moved the prospect or company version. Deleting the row
-- is what makes the refresh do the work.
delete from public.dashboard_snapshot where key = 'dataQuality';
select prospect_operations.refresh_dashboard_snapshots_v1();

-- ---------------------------------------------------------------------------
-- Each tile equals the filter its button applies. Whole table, no sample: these
-- are three counts, and the point of the check is that no row is excepted.
do $$
declare
  v_overview jsonb := public.data_quality_overview();
  v_case jsonb;
  v_tile text;
  v_expected bigint;
  v_actual bigint;
  v_pairs jsonb := $c$[
    ["missingEmployees", [{"field":"__employee_count","operator":"number_ranges","values":["unknown"]}]],
    ["missingCompanyKeywords", [{"field":"__company_keywords","operator":"empty","values":[]}]],
    ["missingCompanyDescription", [{"field":"__company_description","operator":"empty","values":[]}]]
  ]$c$::jsonb;
begin
  for v_case in select value from jsonb_array_elements(v_pairs) loop
    v_tile := v_case->>0;
    if v_overview->v_tile is null then
      raise exception 'data_quality_overview did not report %', v_tile;
    end if;
    v_expected := (v_overview->>v_tile)::bigint;
    execute format('select count(*) from public.prospect_index pi where %s',
      public.prospect_filter_sql_v1('', v_case->1)) into v_actual;
    if v_expected <> v_actual then
      raise exception 'the % tile reads % but its filter selects %', v_tile, v_expected, v_actual;
    end if;
    if v_expected = 0 then
      raise exception 'the % tile counted nothing, so it proves nothing', v_tile;
    end if;
    raise notice '% : % records, and the button opens onto the same %', v_tile, v_expected, v_actual;
  end loop;

  -- The six that were already there are untouched by the splice.
  if (v_overview->>'missingEmail') is null or (v_overview->>'total') is null
     or (v_overview->>'potentialDuplicateGroups') is null then
    raise exception 'the splice dropped an existing data quality key: %', v_overview::text;
  end if;
end $$;

-- And the snapshot the tab actually reads carries them, not just the function.
do $$
declare
  v_payload jsonb;
begin
  select payload into v_payload from public.dashboard_snapshot where key = 'dataQuality';
  if v_payload is null then
    raise exception 'no dataQuality snapshot was written; the tab would be empty';
  end if;
  if v_payload->'missingEmployees' is null
     or v_payload->'missingCompanyKeywords' is null
     or v_payload->'missingCompanyDescription' is null then
    raise exception 'the dataQuality snapshot predates the new checks: %', v_payload::text;
  end if;
end $$;
