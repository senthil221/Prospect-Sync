set statement_timeout = '15s';

select p.oid::regprocedure::text || chr(9) || md5(concat_ws(
  E'\x1f',
  p.prosrc,
  pg_catalog.pg_get_function_identity_arguments(p.oid),
  pg_catalog.pg_get_function_result(p.oid),
  p.prolang::regproc::text,
  p.provolatile::text,
  p.proparallel::text,
  p.prosecdef::text,
  p.proleakproof::text,
  coalesce(pg_catalog.array_to_string(p.proconfig, E'\x1e'), ''),
  pg_catalog.pg_get_userbyid(p.proowner),
  coalesce(p.proacl::text, '')
))
from pg_catalog.pg_proc p
where p.oid in (
  pg_catalog.to_regprocedure('public.data_versions_v1(text[])'),
  pg_catalog.to_regprocedure('public.prospect_filter_sql_v1(text,jsonb)'),
  pg_catalog.to_regprocedure('public.prospect_filters_need_company_lookup_v1(jsonb)'),
  pg_catalog.to_regprocedure('public.prospect_prefilter_sql(text,jsonb)'),
  pg_catalog.to_regprocedure(
    'public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'
  ),
  pg_catalog.to_regprocedure(
    'public.search_prospect_workspace_v13(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'
  )
)
order by p.oid::regprocedure::text;
