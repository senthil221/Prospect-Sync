-- Bulk delete prospects straight out of the People (master) database.
--
-- Explicit id deletes run from the route via the PostgREST client. This function
-- powers "delete everything matching the current search/filters" (all pages) in a
-- single set-based statement. Deleting a prospect cascades to its identifiers,
-- list memberships, list rows, and prospect_index row (all FK on delete cascade),
-- so nothing else needs cleaning up. Companies are intentionally left in place --
-- the Company database is separate storage.
--
-- Uses the same index-friendly pre-filter as the workspace query so a filtered
-- delete never sequentially scans the whole index.

create or replace function public.delete_prospects_matching_v1(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_excluded_ids text[] default '{}'
)
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $fn$
declare
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_sql text;
  v_deleted integer;
begin
  v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);

  v_sql := format($q$
    delete from public.prospects p
    where p.id in (select pi.id from public.prospect_index pi where %s)
      and not (p.id = any($1))
  $q$, v_match_clause);

  execute v_sql using coalesce(p_excluded_ids, '{}'::text[]);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$fn$;

revoke execute on function public.delete_prospects_matching_v1(text, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.delete_prospects_matching_v1(text, jsonb, text[]) to service_role;
