-- An import finds each row's company without reading every blank-domain company.
--
-- WHAT WENT WRONG, MEASURED. On 2026-09-21 the import worker timed out 7 times
-- between 07:34 and 08:46 UTC: process_staged_batch_v1 carries a 120 s ceiling,
-- and batches that normally take 10 s were taking 65-118 s. Replaying one of
-- them on production inside a rolled-back transaction (the 946-row "Kapable TAM
-- 2" import, which succeeded at 118 s on its second attempt) and timing each
-- step of the row loop:
--
--     company lookup      30.2 s     <- this
--     company upsert       2.4 s
--     memberships          2.2 s
--     everything else      1.3 s
--
-- The lookup is one query per row:
--
--     where (d <> '' and c.normalized_domain = d)
--        or (n <> '' and c.normalized_name = n and (d = '' or ...))
--
-- d and n are plpgsql variables, so after five rows the plan is generic, and
-- the generic plan is a BitmapOr that probes idx_companies_normalized_domain
-- for normalized_domain = d REGARDLESS of whether d is blank - the d <> ''
-- guard is only a filter applied afterwards. 102,850 companies have a blank
-- domain. So every row with no domain read all 102,850 of them to discard
-- them: up to 980 ms a row, 33.6 s across the 256 such rows in that batch.
-- It grows with every company imported without a domain.
--
-- THE FIX. Two lookups in the order the ORDER BY already preferred: by domain
-- when there is one, then by name. The guards move out of the SQL into plpgsql
-- IFs, so a blank value never reaches an index probe. Same answer: the old
-- ORDER BY put any domain match first and fell back to a name match, each by
-- created_at, which is exactly what the two LIMIT 1 lookups return. The name
-- branch keeps each function's own blank-domain test verbatim - coalesce() in
-- the People import, a plain = '' in the Company import - so neither changes
-- which company a name matches. Proven against real rows below.
--
-- import_company_batch_v1 carries the same query but nothing calls it any more;
-- it is left alone.
-- ---------------------------------------------------------------------------

do $BODY$
declare
  v_def text;
  v_old constant text :=
E'      select c.id into company_id_value
      from public.companies c
      where (normalized_domain_value <> '''' and c.normalized_domain = normalized_domain_value)
         or (normalized_name_value <> '''' and c.normalized_name = normalized_name_value
           and (normalized_domain_value = '''' or coalesce(c.normalized_domain, '''') = ''''))
      order by case when normalized_domain_value <> '''' and c.normalized_domain = normalized_domain_value then 0 else 1 end, c.created_at
      limit 1;';
  v_new constant text :=
E'      -- By domain, then by name - never an index probe for a blank value.
      -- See 20260923130000.
      if normalized_domain_value <> '''' then
        select c.id into company_id_value
        from public.companies c
        where c.normalized_domain = normalized_domain_value
        order by c.created_at
        limit 1;
      end if;
      if company_id_value is null and normalized_name_value <> '''' then
        select c.id into company_id_value
        from public.companies c
        where c.normalized_name = normalized_name_value
          and (normalized_domain_value = '''' or coalesce(c.normalized_domain, '''') = '''')
        order by c.created_at
        limit 1;
      end if;';
begin
  v_def := pg_get_functiondef('public.import_prospect_batch_v2(text,text,jsonb)'::regprocedure);
  if position(v_old in v_def) = 0 then
    raise exception 'import_prospect_batch_v2 no longer contains the company lookup this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $BODY$;

do $BODY$
declare
  v_def text;
  v_old constant text :=
E'    select c.id into company_id_value from public.companies c
    where (normalized_domain_value <> '''' and c.normalized_domain = normalized_domain_value)
       or (normalized_name_value <> '''' and c.normalized_name = normalized_name_value
         and (normalized_domain_value = '''' or c.normalized_domain = ''''))
    order by case when normalized_domain_value <> '''' and c.normalized_domain = normalized_domain_value then 0 else 1 end, c.created_at
    limit 1;';
  v_new constant text :=
E'    -- By domain, then by name - never an index probe for a blank value.
    -- See 20260923130000.
    if normalized_domain_value <> '''' then
      select c.id into company_id_value from public.companies c
      where c.normalized_domain = normalized_domain_value
      order by c.created_at
      limit 1;
    end if;
    if company_id_value is null and normalized_name_value <> '''' then
      select c.id into company_id_value from public.companies c
      where c.normalized_name = normalized_name_value
        and (normalized_domain_value = '''' or c.normalized_domain = '''')
      order by c.created_at
      limit 1;
    end if;';
begin
  v_def := pg_get_functiondef('public.import_company_batch_v3(text,jsonb,integer)'::regprocedure);
  if position(v_old in v_def) = 0 then
    raise exception 'import_company_batch_v3 no longer contains the company lookup this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $BODY$;

-- ---------------------------------------------------------------------------
-- Both functions now carry the two-step lookup and neither keeps the OR form.
do $$
declare
  v_fn text;
  v_def text;
begin
  foreach v_fn in array array[
    'public.import_prospect_batch_v2(text,text,jsonb)',
    'public.import_company_batch_v3(text,jsonb,integer)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    if position('See 20260923130000' in v_def) = 0
       or position('or (normalized_name_value <> ''''' in v_def) > 0 then
      raise exception '% did not take the two-step company lookup', v_fn;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Same company, on real rows. For a sample of real (domain, name) pairs - with
-- domain, without, and with a domain nobody has - the two-step lookup must pick
-- exactly the company the OR query picked, under both blank-domain tests.
-- Custom plans, so the old form is not itself slow here for the reason above.
set local plan_cache_mode = force_custom_plan;
do $$
declare
  r record;
  v_old text;
  v_new text;
  v_checked integer := 0;
  v_blank_checked integer := 0;
begin
  for r in
    (select coalesce(normalized_domain, '') as d, coalesce(normalized_name, '') as n
       from public.companies where coalesce(normalized_domain, '') = '' and normalized_name <> ''
      order by id limit 300)
    union all
    (select normalized_domain, coalesce(normalized_name, '')
       from public.companies where normalized_domain <> '' order by id limit 300)
    union all
    (select 'no-such-domain-' || id, coalesce(normalized_name, '')
       from public.companies where normalized_name <> '' order by id desc limit 100)
  loop
    -- People import form: coalesce() on the blank-domain test.
    select c.id into v_old from public.companies c
    where (r.d <> '' and c.normalized_domain = r.d)
       or (r.n <> '' and c.normalized_name = r.n and (r.d = '' or coalesce(c.normalized_domain, '') = ''))
    order by case when r.d <> '' and c.normalized_domain = r.d then 0 else 1 end, c.created_at
    limit 1;
    v_new := null;
    if r.d <> '' then
      select c.id into v_new from public.companies c where c.normalized_domain = r.d order by c.created_at limit 1;
    end if;
    if v_new is null and r.n <> '' then
      select c.id into v_new from public.companies c
      where c.normalized_name = r.n and (r.d = '' or coalesce(c.normalized_domain, '') = '')
      order by c.created_at limit 1;
    end if;
    if v_new is distinct from v_old then
      raise exception 'People lookup for domain "%" name "%" now finds %, previously %', r.d, r.n, v_new, v_old;
    end if;

    -- Company import form: plain = '' on the blank-domain test.
    select c.id into v_old from public.companies c
    where (r.d <> '' and c.normalized_domain = r.d)
       or (r.n <> '' and c.normalized_name = r.n and (r.d = '' or c.normalized_domain = ''))
    order by case when r.d <> '' and c.normalized_domain = r.d then 0 else 1 end, c.created_at
    limit 1;
    v_new := null;
    if r.d <> '' then
      select c.id into v_new from public.companies c where c.normalized_domain = r.d order by c.created_at limit 1;
    end if;
    if v_new is null and r.n <> '' then
      select c.id into v_new from public.companies c
      where c.normalized_name = r.n and (r.d = '' or c.normalized_domain = '')
      order by c.created_at limit 1;
    end if;
    if v_new is distinct from v_old then
      raise exception 'Company lookup for domain "%" name "%" now finds %, previously %', r.d, r.n, v_new, v_old;
    end if;

    v_checked := v_checked + 1;
    if r.d = '' then v_blank_checked := v_blank_checked + 1; end if;
  end loop;

  if v_checked < 100 then
    raise notice 'only % company lookups were compared; the equivalence is weakly proven here', v_checked;
  end if;
end $$;
