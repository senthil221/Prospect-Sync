-- Verification for the 2026-08-25 migration set.
--
-- Read-only. Run it in any Supabase SQL Editor (cloud or self-hosted) after
-- applying the five migrations. Every row should read PASS.
--
-- Covers, in order:
--   20260825000000_fix_list_workspace_raw_data
--   20260825010000_master_isolation
--   20260825020000_company_merge_modes
--   20260825030000_title_classifier
--   20260825040000_title_keyword_seed
--
-- The filter-wiring checks matter most on a database whose function bodies differ
-- from the ones this was written against: that migration splices new WHEN arms into
-- already-deployed function definitions and SKIPS SILENTLY when it cannot find the
-- arm to splice after. A FAIL there means the classifier columns exist but nothing
-- can filter on them.

with checks(sort_key, area, check_name, ok, detail) as (

  -- 1. list_workspace repair -------------------------------------------------
  select 1, 'list view', 'list_workspace no longer reads the dropped list_memberships.raw_data',
    coalesce(pg_get_functiondef(to_regprocedure('public.list_workspace(text,text,integer,integer)')) not ilike '%lm.raw_data%', false),
    coalesce((select 'reads list_rows: ' || (pg_get_functiondef(to_regprocedure('public.list_workspace(text,text,integer,integer)')) ilike '%public.list_rows%')::text), 'function missing')

  union all
  select 2, 'list view', 'idx_list_rows_list_prospect exists',
    exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'idx_list_rows_list_prospect'),
    ''

  -- 2. Master isolation ------------------------------------------------------
  union all
  select 10, 'isolation', 'cleanup_orphaned_master_records is GONE (cannot delete master rows)',
    to_regprocedure('public.cleanup_orphaned_master_records(text[])') is null,
    ''

  union all
  select 11, 'isolation', 'delete_client_with_cleanup never touches prospects/companies',
    coalesce(
      pg_get_functiondef(to_regprocedure('public.delete_client_with_cleanup(text,boolean)')) not ilike '%delete from public.prospects%'
      and pg_get_functiondef(to_regprocedure('public.delete_client_with_cleanup(text,boolean)')) not ilike '%cleanup_orphaned%', false),
    ''

  union all
  select 12, 'isolation', 'delete_list_with_cleanup never touches prospects/companies',
    coalesce(
      pg_get_functiondef(to_regprocedure('public.delete_list_with_cleanup(text,boolean)')) not ilike '%delete from public.prospects%'
      and pg_get_functiondef(to_regprocedure('public.delete_list_with_cleanup(text,boolean)')) not ilike '%cleanup_orphaned%', false),
    ''

  union all
  select 13, 'isolation', 'delete_import_with_cleanup never touches prospects/companies',
    coalesce(
      pg_get_functiondef(to_regprocedure('public.delete_import_with_cleanup(text,boolean)')) not ilike '%delete from public.prospects%'
      and pg_get_functiondef(to_regprocedure('public.delete_import_with_cleanup(text,boolean)')) not ilike '%cleanup_orphaned%', false),
    ''

  union all
  select 14, 'isolation', 'remove_prospect_from_client_v1 also clears list_rows.prospect_id',
    coalesce(pg_get_functiondef(to_regprocedure('public.remove_prospect_from_client_v1(text,text)')) ilike '%update public.list_rows%', false),
    ''

  union all
  select 15, 'push to list', 'start_list_push_v1 exists',
    to_regprocedure('public.start_list_push_v1(text,text)') is not null, ''
  union all
  select 16, 'push to list', 'add_prospects_to_list_v1 exists',
    to_regprocedure('public.add_prospects_to_list_v1(text,text,text[])') is not null, ''
  union all
  select 17, 'push to list', 'finish_list_push_v1 exists',
    to_regprocedure('public.finish_list_push_v1(text)') is not null, ''
  union all
  select 18, 'push to list', 'remove_prospects_from_list_v1 exists',
    to_regprocedure('public.remove_prospects_from_list_v1(text,text[])') is not null, ''
  union all
  select 19, 'push to list', 'prospect_ids_matching_v1 uses keyset paging (p_after_id, not p_offset)',
    to_regprocedure('public.prospect_ids_matching_v1(text,jsonb,text[],integer,text)') is not null
      and to_regprocedure('public.prospect_ids_matching_v1(text,jsonb,text[],integer,integer)') is null,
    ''

  -- 3. Company merge modes ---------------------------------------------------
  union all
  select 30, 'company merge', 'company_imports.merge_mode column exists',
    exists (select 1 from information_schema.columns
            where table_schema = 'public' and table_name = 'company_imports' and column_name = 'merge_mode'),
    coalesce((select 'default ' || column_default from information_schema.columns
              where table_schema = 'public' and table_name = 'company_imports' and column_name = 'merge_mode'), '')

  union all
  select 31, 'company merge', 'merge_mode constrained to enrich/overwrite/skip',
    exists (select 1 from pg_constraint where conname = 'company_imports_merge_mode_check'), ''

  union all
  select 32, 'company merge', 'import_company_batch_v3 exists and reads merge_mode',
    coalesce(pg_get_functiondef(to_regprocedure('public.import_company_batch_v3(text,jsonb,integer)')) ilike '%merge_mode%', false), ''

  union all
  select 33, 'company merge', 'import_company_batch_v2 still callable (forwards to v3)',
    to_regprocedure('public.import_company_batch_v2(text,jsonb,integer)') is not null, ''

  -- 4. Title classifier ------------------------------------------------------
  union all
  select 50, 'classifier', 'unaccent extension installed',
    exists (select 1 from pg_extension where extname = 'unaccent'), ''

  union all
  select 51, 'classifier', 'keyword + state tables exist',
    (select count(*) from information_schema.tables
     where table_schema = 'public'
       and table_name in ('title_seniority_keywords','title_department_keywords','title_classifier_state')) = 3, ''

  union all
  select 52, 'classifier', 'classify_job_title_v1 / normalize_job_title_v1 exist',
    to_regprocedure('public.classify_job_title_v1(text,text)') is not null
      and to_regprocedure('public.normalize_job_title_v1(text)') is not null, ''

  union all
  select 53, 'classifier', 'derived columns on prospects',
    (select count(*) from information_schema.columns
     where table_schema = 'public' and table_name = 'prospects'
       and column_name in ('title_seniority','title_department','title_sub_department',
                           'title_secondary_departments','title_is_former','title_normalized','title_classified_at')) = 7, ''

  union all
  select 54, 'classifier', 'mirrored columns on prospect_index',
    (select count(*) from information_schema.columns
     where table_schema = 'public' and table_name = 'prospect_index'
       and column_name in ('title_seniority','title_department','title_sub_department','title_is_former','title_normalized')) = 5, ''

  union all
  select 55, 'classifier', 'classify-on-write triggers installed',
    (select count(*) from pg_trigger
     where not tgisinternal
       and tgname in ('trg_prospects_classify_title_insert','trg_prospects_classify_title_update','trg_prospect_index_fill_title_class')) = 3, ''

  union all
  select 56, 'classifier', 'reclassify + gaps + filter-values functions exist',
    to_regprocedure('public.reclassify_prospect_titles_v1(integer)') is not null
      and to_regprocedure('public.title_classification_gaps_v1(integer,text)') is not null
      and to_regprocedure('public.title_class_filter_values_v1(text,text,text,integer)') is not null, ''

  -- 5. Keyword data ----------------------------------------------------------
  union all
  select 70, 'keywords', 'seniority keywords loaded (expect 211)',
    (select count(*) from public.title_seniority_keywords) = 211,
    (select 'found ' || count(*)::text from public.title_seniority_keywords)

  union all
  select 71, 'keywords', 'department keywords loaded (expect 357)',
    (select count(*) from public.title_department_keywords) = 357,
    (select 'found ' || count(*)::text from public.title_department_keywords)

  union all
  select 72, 'keywords', 'all 18 departments present',
    (select count(distinct department) from public.title_department_keywords) = 18,
    (select 'found ' || count(distinct department)::text from public.title_department_keywords)

  -- 6. Filter wiring (the silent-skip risk) ----------------------------------
  union all
  select 90, 'filter wiring', 'prospect_index_matches_v1 knows the classifier fields',
    coalesce(pg_get_functiondef(to_regprocedure('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)')) like '%\_\_title\_department%', false), ''

  union all
  select 91, 'filter wiring', 'prospect_prefilter_sql knows the classifier fields',
    coalesce(pg_get_functiondef(to_regprocedure('public.prospect_prefilter_sql(text,jsonb)')) like '%\_\_title\_department%', false), ''

  union all
  select 92, 'filter wiring', 'search_prospect_workspace_v11 knows the classifier fields',
    coalesce(pg_get_functiondef(to_regprocedure('public.search_prospect_workspace_v11(text,jsonb,text,text,integer,integer,text,jsonb,boolean)')) like '%\_\_title\_department%', false),
    case when to_regprocedure('public.search_prospect_workspace_v11(text,jsonb,text,text,integer,integer,text,jsonb,boolean)') is null then 'function not present' else '' end

  union all
  select 93, 'filter wiring', 'search_prospect_export_v1 knows the classifier fields',
    coalesce(pg_get_functiondef(to_regprocedure('public.search_prospect_export_v1(text,jsonb,text,timestamptz,text,integer,boolean)')) like '%\_\_title\_department%', false),
    case when to_regprocedure('public.search_prospect_export_v1(text,jsonb,text,timestamptz,text,integer,boolean)') is null then 'function not present' else '' end

  -- 7. Behaviour smoke test (proves the keywords actually classify) -----------
  union all
  select 100, 'behaviour', 'AVP Sales -> vp / Sales',
    (select seniority = 'vp' and department = 'Sales' from public.classify_job_title_v1('AVP Sales')),
    (select seniority || ' / ' || coalesce(nullif(department,''),'-') from public.classify_job_title_v1('AVP Sales'))

  union all
  select 101, 'behaviour', 'Assistant Manager - Accounts -> entry / Finance (demotion override)',
    (select seniority = 'entry' and department = 'Finance' from public.classify_job_title_v1('Assistant Manager - Accounts')),
    (select coalesce(nullif(seniority,''),'-') || ' / ' || coalesce(nullif(department,''),'-') from public.classify_job_title_v1('Assistant Manager - Accounts'))

  union all
  select 102, 'behaviour', 'Former CEO | Advisor -> Undefined + is_former',
    (select seniority = '' and is_former from public.classify_job_title_v1('Former CEO | Advisor')),
    (select coalesce(nullif(seniority,''),'-') || ' is_former=' || is_former::text from public.classify_job_title_v1('Former CEO | Advisor'))

  union all
  select 103, 'behaviour', 'Manager - FP&A -> manager / Finance / FP&A (ampersand acronym)',
    (select seniority = 'manager' and department = 'Finance' and sub_department = 'FP&A' from public.classify_job_title_v1('Manager - FP&A')),
    (select coalesce(nullif(seniority,''),'-') || ' / ' || coalesce(nullif(department,''),'-') || ' / ' || coalesce(nullif(sub_department,''),'-') from public.classify_job_title_v1('Manager - FP&A'))

  union all
  select 104, 'behaviour', 'Headhunter -> Undefined (whole-word match, not substring)',
    (select seniority = '' and department = '' from public.classify_job_title_v1('Headhunter')),
    (select coalesce(nullif(seniority,''),'-') || ' / ' || coalesce(nullif(department,''),'-') from public.classify_job_title_v1('Headhunter'))

  union all
  select 105, 'behaviour', 'MD at a hospital -> Undefined (healthcare mitigation)',
    (select seniority = '' from public.classify_job_title_v1('MD', 'Apollo Hospitals Ltd')),
    (select coalesce(nullif(seniority,''),'-') from public.classify_job_title_v1('MD', 'Apollo Hospitals Ltd'))

  union all
  select 106, 'behaviour', 'Executive Assistant to MD -> entry / Admin (phrase demotion override)',
    (select seniority = 'entry' and department = 'Admin' from public.classify_job_title_v1('Executive Assistant to MD')),
    (select coalesce(nullif(seniority,''),'-') || ' / ' || coalesce(nullif(department,''),'-') from public.classify_job_title_v1('Executive Assistant to MD'))

  union all
  select 107, 'behaviour', 'Executive Assistant to the MD -> entry / Admin (five-token scan)',
    (select seniority = 'entry' and department = 'Admin' from public.classify_job_title_v1('Executive Assistant to the MD')),
    (select coalesce(nullif(seniority,''),'-') || ' / ' || coalesce(nullif(department,''),'-') from public.classify_job_title_v1('Executive Assistant to the MD'))

  -- 8. Backfill progress -----------------------------------------------------
  union all
  select 120, 'backfill', 'every prospect has been classified at least once',
    (select count(*) from public.prospects where title_classified_at is null) = 0,
    (select count(*)::text || ' still unclassified -- POST /api/prospects/classify until remaining=false'
     from public.prospects where title_classified_at is null)

  -- 9. Release 1A: no untimed hot function ------------------------------------
  --
  -- 20260902000040 sets these through ALTER FUNCTION, so a later
  -- CREATE OR REPLACE without a SET statement_timeout clause silently drops
  -- them. proconfig is the authoritative record either way.
  union all
  select 130, 'timeouts', 'linked_prospect_total_v1 has a statement timeout',
    coalesce((select proconfig::text[] && array['statement_timeout=20s']
      from pg_proc where oid = to_regprocedure('public.linked_prospect_total_v1(text)')), false),
    coalesce((select array_to_string(proconfig, ', ')
      from pg_proc where oid = to_regprocedure('public.linked_prospect_total_v1(text)')), 'function missing')

  union all
  select 131, 'timeouts', 'prospect_filter_values_v3 has a statement timeout',
    coalesce((select proconfig::text[] && array['statement_timeout=30s']
      from pg_proc where oid = to_regprocedure('public.prospect_filter_values_v3(text,text,text,integer)')), false),
    coalesce((select array_to_string(proconfig, ', ')
      from pg_proc where oid = to_regprocedure('public.prospect_filter_values_v3(text,text,text,integer)')), 'function missing')

  union all
  select 132, 'timeouts', 'search_prospect_export_v1 has a statement timeout',
    coalesce((select proconfig::text[] && array['statement_timeout=60s']
      from pg_proc where oid = to_regprocedure('public.search_prospect_export_v1(text,jsonb,text,timestamptz,text,integer,boolean)')), false),
    coalesce((select array_to_string(proconfig, ', ')
      from pg_proc where oid = to_regprocedure('public.search_prospect_export_v1(text,jsonb,text,timestamptz,text,integer,boolean)')), 'function missing')

  -- Nothing else on the interactive read path may be untimed.
  union all
  select 133, 'timeouts', 'no SECURITY DEFINER search/filter function is left untimed',
    not exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.prosecdef
        and (p.proname like 'search\_%' or p.proname like '%\_filter\_values%' or p.proname like 'filter\_companies%')
        and not coalesce(array_to_string(p.proconfig, ',') like '%statement_timeout%', false)
    ),
    coalesce((select string_agg(p.proname, ', ')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prosecdef
        and (p.proname like 'search\_%' or p.proname like '%\_filter\_values%' or p.proname like 'filter\_companies%')
        and not coalesce(array_to_string(p.proconfig, ',') like '%statement_timeout%', false)), '')
)
select
  area,
  check_name,
  case when ok then 'PASS' else 'FAIL' end as status,
  nullif(detail, '') as detail
from checks
order by sort_key;
