-- Four Data Quality checks - missing website, # employees, keywords, short
-- description - counted PEOPLE affected by a gap on their company, then opened
-- the People workspace. The number and the button agreed with each other, but
-- neither agreed with the Company database: a company with 300 people and no
-- recorded website counted as one row here for every one of them, and a
-- company with the same gap and zero people never counted at all - the missing
-- 76,880 of them (100,448 companies actually missing a website against 23,568
-- people who happened to be at one).
--
-- These four now count COMPANIES and open the Company database. The other
-- four checks - missing email, title, LinkedIn, and "missing company" itself -
-- stay exactly as they are: each is a gap on the PERSON record with no company
-- row to open instead, and "not touched in 180 days" is person staleness with
-- no company-side question to ask at all.
--
-- THE FOUR NEW NUMBERS ARE NOT COMPUTED FRESH HERE. They are the exact
-- predicates company_filter_sql_v3 already compiles for __website/empty,
-- __employee_count/number_ranges["unknown"], __keywords/empty and
-- __short_description/empty - verified against production before this file was
-- written, both that the compiler produces this SQL and that this SQL returns
-- this count. Written by hand rather than through the compiler because
-- data_quality_overview is one aggregate query and calling back into a STABLE
-- function per row would be the wrong shape for it; the assertion below is what
-- keeps the two from drifting apart the way 20260916100000 already guards its
-- three checks.
--
-- SPLICED, per the pattern 20260916100000 established: this function has now
-- been redefined three times, and restating it from scratch would take one of
-- the earlier fixes back out.
-- ---------------------------------------------------------------------------

do $patch$
declare
  v_def text;
  v_marker constant text := $m$    'staleRecords', count(*) filter (where p.updated_at < now() - interval '180 days'),$m$;
  v_replacement constant text := $r$    'staleRecords', count(*) filter (where p.updated_at < now() - interval '180 days'),
    'companiesTotal', (select count(*) from public.companies),
    'companiesMissingDomain', (select count(*) from public.companies co where btrim(coalesce(co.domain, '')) = ''),
    'companiesMissingEmployees', (select count(*) from public.companies co where co.employee_count_min is null and co.employee_count_max is null),
    'companiesMissingKeywords', (select count(*) from public.companies co where btrim(coalesce(array_to_string(co.keywords, ' | '), '')) = ''),
    'companiesMissingDescription', (select count(*) from public.companies co where btrim(coalesce(co.short_description, '')) = ''),$r$;
begin
  select pg_get_functiondef('public.data_quality_overview()'::regprocedure) into v_def;

  if position(v_replacement in v_def) > 0 then
    return;
  end if;
  if position(v_marker in v_def) = 0 then
    raise exception 'data_quality_overview no longer counts staleRecords in the expected shape; refusing to patch blindly';
  end if;

  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- ---------------------------------------------------------------------------
-- Recompute the stored snapshot now, for the reason 20260916100000 records:
-- the refresher skips a key whose data_version still matches, so without this
-- the four new numbers would read zero and stay "Clear" until an unrelated
-- write happened to move the company version.
delete from public.dashboard_snapshot where key = 'dataQuality';
select prospect_operations.refresh_dashboard_snapshots_v1();

-- ---------------------------------------------------------------------------
-- Each new tile equals the company-side filter its button will apply, over
-- every company - not a sample, since the point is that no row is excepted.
do $$
declare
  v_overview jsonb := public.data_quality_overview();
  v_case jsonb;
  v_tile text;
  v_expected bigint;
  v_actual bigint;
  v_pairs jsonb := $c$[
    ["companiesMissingDomain", [{"field":"__website","operator":"empty","values":[]}]],
    ["companiesMissingEmployees", [{"field":"__employee_count","operator":"number_ranges","values":["unknown"]}]],
    ["companiesMissingKeywords", [{"field":"__keywords","operator":"empty","values":[]}]],
    ["companiesMissingDescription", [{"field":"__short_description","operator":"empty","values":[]}]]
  ]$c$::jsonb;
begin
  for v_case in select value from jsonb_array_elements(v_pairs) loop
    v_tile := v_case->>0;
    if v_overview->v_tile is null then
      raise exception 'data_quality_overview did not report %', v_tile;
    end if;
    v_expected := (v_overview->>v_tile)::bigint;
    execute format('select count(*) from public.companies c where %s',
      public.company_filter_sql_v3('', v_case->1)) into v_actual;
    if v_expected <> v_actual then
      raise exception 'the % tile reads % but its company filter selects %', v_tile, v_expected, v_actual;
    end if;
    if v_expected = 0 then
      raise exception 'the % tile counted nothing, so it proves nothing', v_tile;
    end if;
    raise notice '% : % companies, and the Company DB button opens onto the same %', v_tile, v_expected, v_actual;
  end loop;

  if (v_overview->>'companiesTotal')::bigint <> (select count(*) from public.companies) then
    raise exception 'companiesTotal (%) does not match the companies table (%)',
      v_overview->>'companiesTotal', (select count(*) from public.companies);
  end if;

  -- The eight person-side keys are untouched by the splice.
  if (v_overview->>'missingEmail') is null or (v_overview->>'missingCompany') is null
     or (v_overview->>'staleRecords') is null or (v_overview->>'total') is null then
    raise exception 'the splice dropped an existing data quality key: %', v_overview::text;
  end if;
end $$;

-- And the snapshot the tab actually reads carries the four new keys, not just
-- the function.
do $$
declare
  v_payload jsonb;
begin
  select payload into v_payload from public.dashboard_snapshot where key = 'dataQuality';
  if v_payload is null then
    raise exception 'no dataQuality snapshot was written; the tab would be empty';
  end if;
  if v_payload->'companiesMissingDomain' is null or v_payload->'companiesTotal' is null then
    raise exception 'the dataQuality snapshot predates the company-side checks: %', v_payload::text;
  end if;
end $$;
