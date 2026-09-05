-- Read-only baseline for the reported company-description -> People journey.
-- Run with psql; each statement is bounded and only aggregate results leave DB.
\timing on
\pset format unaligned
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '1s';
SELECT jsonb_build_array(jsonb_build_object(
  'field','__company_keywords','operator','contains',
  'scopes',jsonb_build_array('name','keywords','description'),
  'values',to_jsonb(string_to_array('IT services,IT consulting,managed IT services,managed service provider,MSP,IT solutions provider,technology consulting,IT outsourcing,IT support services,information technology services,IT staffing,staff augmentation,cloud services provider,cloud migration,cloud consulting,infrastructure as a service,AWS consulting partner,Azure consulting partner,Google Cloud partner,data center services,hosting services,DevOps services,custom software development,software development company,application development,systems integration,enterprise software solutions,SaaS development,web development company,mobile app development,ERP implementation,CRM implementation,cybersecurity services,managed security services,MSSP,IT security consulting,network security services,IT compliance risk management,data analytics services,business intelligence consulting,data engineering services,AI ML consulting,data warehousing services,network services,IT infrastructure management,unified communications provider,help desk services,hardware procurement,value-added reseller,system integrator,digital transformation consulting',','))
))::text AS filters \gset
SELECT 'reported list' AS case_name, jsonb_array_length(:'filters'::jsonb->0->'values') AS terms;
SELECT format('EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT count(*) FROM public.companies c WHERE %s',
  public.company_full_scan_filter_sql_v1('', :'filters'::jsonb)) \gexec
SELECT format('EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT count(*) FROM public.companies c WHERE c.keywords && %L::text[] OR lower(c.name) LIKE ANY (%L::text[]) OR lower(c.short_description) LIKE ANY (%L::text[])',
  public.keyword_tag_variants_v1(array(select jsonb_array_elements_text(:'filters'::jsonb->0->'values'))),
  array(select '%%' || lower(v) || '%%' from jsonb_array_elements_text(:'filters'::jsonb->0->'values') v),
  array(select '%%' || lower(v) || '%%' from jsonb_array_elements_text(:'filters'::jsonb->0->'values') v)) \gexec
SELECT total_count,scope_capped,jsonb_array_length(result_rows) AS page_rows
FROM public.search_prospect_workspace_v12(p_company_scope=>jsonb_build_object('search','','filters',:'filters'::jsonb),p_with_total=>true);
ROLLBACK;
