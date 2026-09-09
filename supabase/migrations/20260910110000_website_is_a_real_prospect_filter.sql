-- Make __website filter something on the People side.
--
-- __website is a filter field the compiler does not know. All three prospect
-- predicate builders carry a CASE mapping a field id to a column, all three have
-- a '__company_domain' arm, and none has a '__website' arm - so __website falls
-- through to the default empty string. The results are silently, dangerously
-- wrong rather than an error:
--
--   __website empty      ->  btrim(coalesce('', '')) = ''   true for every row
--   __website contains x ->  ('' ilike '%x%')               true for no row
--
-- Measured on production before this migration: a People query filtered to
-- "__website empty" returned all 681,785 people, against 23,568 that actually
-- have no company domain.
--
-- WHY IT HAS GONE UNNOTICED. The People filter panel does not offer __website;
-- it is a Companies field, and the company predicate builders do know it
-- (company_prefilter_sql and company_matches_filters_v1 both have the arm, which
-- is why filtering companies by website has always worked). Nothing in the
-- People UI can reach it. It is reachable through a saved view or a hand-built
-- URL, and there the failure is the bad kind: a view meant to find people with
-- no website quietly matches the entire database, and a push built from it goes
-- to everyone.
--
-- The fix is an alias, not a new concept: __website means the same column
-- __company_domain already means. Both arms are kept so existing saved views of
-- either spelling behave identically.
--
-- Patched from the deployed definitions rather than restated, and asserted
-- rather than assumed - see 20260910090000 for why, and 20260910093000 for what
-- happens when a patch is believed instead of checked.

begin;

do $patch$
declare
  v_targets constant text[][] := array[
    array['prospect_filter_sql_v1',
          'when ''__company_domain'' then ''pi.company_domain''',
          'when ''__company_domain'' then ''pi.company_domain'' when ''__website'' then ''pi.company_domain'''],
    array['prospect_prefilter_sql',
          'when ''__company_domain'' then ''pi.company_domain''',
          'when ''__company_domain'' then ''pi.company_domain'' when ''__website'' then ''pi.company_domain'''],
    array['prospect_index_matches_v1',
          'when ''__company_domain'' then (p_row).company_domain',
          'when ''__company_domain'' then (p_row).company_domain when ''__website'' then (p_row).company_domain']
  ];
  v_name text;
  v_marker text;
  v_replacement text;
  v_def text;
  v_index integer;
begin
  for v_index in 1 .. array_length(v_targets, 1) loop
    v_name := v_targets[v_index][1];
    v_marker := v_targets[v_index][2];
    v_replacement := v_targets[v_index][3];

    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    if v_def is null then
      raise exception '%: not deployed; nothing to patch', v_name;
    end if;
    -- Already carries the arm, from an earlier run or a later rewrite.
    if position('''__website''' in v_def) > 0 then
      continue;
    end if;
    if position(v_marker in v_def) = 0 then
      raise exception '%: no __company_domain arm in the expected shape; refusing to patch blindly', v_name;
    end if;

    execute replace(v_def, v_marker, v_replacement);
  end loop;
end;
$patch$;

-- __website must now compile to the same column __company_domain does, in every
-- builder, and select the same rows.
do $$
declare
  v_website text := public.prospect_filter_sql_v1('', '[{"field":"__website","operator":"empty","values":[]}]'::jsonb);
  v_domain text := public.prospect_filter_sql_v1('', '[{"field":"__company_domain","operator":"empty","values":[]}]'::jsonb);
  v_website_count bigint;
  v_domain_count bigint;
  v_name text;
begin
  if v_website is distinct from v_domain then
    raise exception '__website compiles to % but __company_domain compiles to %', v_website, v_domain;
  end if;
  if position('company_domain' in coalesce(v_website, '')) = 0 then
    raise exception '__website still does not reference company_domain: %', v_website;
  end if;

  execute 'select count(*) from public.prospect_index pi where ' || v_website into v_website_count;
  execute 'select count(*) from public.prospect_index pi where ' || v_domain into v_domain_count;
  if v_website_count is distinct from v_domain_count then
    raise exception '__website selects % rows, __company_domain selects %', v_website_count, v_domain_count;
  end if;
  if v_website_count = (select count(*) from public.prospect_index) then
    raise exception '__website empty still matches every row (%); the alias did not take', v_website_count;
  end if;

  foreach v_name in array array['prospect_filter_sql_v1', 'prospect_prefilter_sql', 'prospect_index_matches_v1'] loop
    if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = v_name) not like '%''__website''%' then
      raise exception '% was not patched', v_name;
    end if;
  end loop;
end;
$$;

commit;
