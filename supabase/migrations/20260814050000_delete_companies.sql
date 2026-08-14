-- Delete companies straight out of the Company (master) database.
--
-- Deleting a company sets company_id to null on any linked prospect (FK on delete
-- set null), so people survive in the People database and simply lose the company
-- link; company_sources cascade out, company_import_rows.company_id nulls. We then
-- reindex those prospects so the flat prospect_index drops the stale company name /
-- location it had denormalized. People are never deleted by a company delete.

create or replace function public.delete_companies_by_ids_v1(p_ids text[])
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  affected_prospects text[];
  deleted integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  select coalesce(array_agg(p.id), '{}'::text[]) into affected_prospects
  from public.prospects p where p.company_id = any(p_ids);
  delete from public.companies where id = any(p_ids);
  get diagnostics deleted = row_count;
  perform public.reindex_prospects(affected_prospects);
  return deleted;
end;
$$;

-- "Delete everything matching the current Company-tab search/filters" (all pages).
-- Uses the same index-friendly pre-filter + scalar matcher as filter_companies_v4.
create or replace function public.delete_companies_matching_v1(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_excluded_ids text[] default '{}'
)
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '300s'
as $fn$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_sql text;
  target_ids text[];
  affected_prospects text[];
  deleted integer;
begin
  v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);

  v_sql := format($q$
    select coalesce(array_agg(c.id), '{}'::text[])
    from public.companies c
    where (%s) and not (c.id = any($1))
  $q$, v_match_clause);

  execute v_sql using coalesce(p_excluded_ids, '{}'::text[]) into target_ids;
  if target_ids is null or array_length(target_ids, 1) is null then return 0; end if;

  select coalesce(array_agg(p.id), '{}'::text[]) into affected_prospects
  from public.prospects p where p.company_id = any(target_ids);

  delete from public.companies where id = any(target_ids);
  get diagnostics deleted = row_count;
  perform public.reindex_prospects(affected_prospects);
  return deleted;
end;
$fn$;

revoke execute on function public.delete_companies_by_ids_v1(text[]) from public, anon, authenticated;
revoke execute on function public.delete_companies_matching_v1(text, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.delete_companies_by_ids_v1(text[]) to service_role;
grant execute on function public.delete_companies_matching_v1(text, jsonb, text[]) to service_role;
