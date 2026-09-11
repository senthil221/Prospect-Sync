-- Every filtered search evaluates its predicate twice on every row it scans.
--
-- Both sides build their WHERE the same way: an index-usable prefilter ANDed
-- with the exact filter. That is the right shape when the two differ - the
-- prefilter narrows with an index, the exact filter is the truth. But for a
-- plain search, and for any single-field filter, the two are the same
-- expression, and the query becomes
--
--   where (pi.search_text ilike '%john%') and (pi.search_text ilike '%john%')
--
-- X and X is X. The second copy narrows nothing and costs a full evaluation per
-- row. Measured on production, warm, counting 287,981 matching prospects:
--
--   (pi.title ilike '%manager%') and (pi.title ilike '%manager%')   742ms
--   (pi.title ilike '%manager%')                                    514ms
--
-- 31%, and the People search pays it twice - once in the count CTE and again in
-- the ordered CTE. The company pivot pays it too: the planner's Filter line
-- read ((name OR domain) AND (name OR domain)) across 419,220 rows, 542ms of
-- scan against 379ms with one copy.
--
-- The fix is not to stop combining - when the prefilter really is narrower it
-- earns its place - it is to notice when there is nothing to combine.
--
-- Which rows match does not change. That is what makes this safe, and the
-- assertions check it against the answers this database gives today rather
-- than trusting the reasoning.

begin;

create temp table search_baseline on commit drop as
select
  (select total_count from public.search_prospect_workspace_v12(
     'john', '[]'::jsonb, 'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null)) as plain_search,
  (select total_count from public.search_prospect_workspace_v12(
     '', '[{"id":"f1","field":"__title","operator":"contains","values":["manager"]}]'::jsonb,
     'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null)) as one_filter,
  (select total_count from public.search_prospect_workspace_v12(
     'john', '[{"id":"f1","field":"__title","operator":"contains","values":["manager"]}]'::jsonb,
     'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null)) as search_and_filter,
  (select md5(result_rows::text) from public.search_prospect_workspace_v12(
     '', '[{"id":"f1","field":"__title","operator":"contains","values":["manager"]}]'::jsonb,
     'name', 'asc', 50, 0, null, '{}'::jsonb, true, null)) as page_fingerprint,
  (select count(*)::bigint from prospect_results.uncached_company_scope_ids_v1(
     null, '{"search":"tech"}'::jsonb)) as company_scope;

-- Companies: one small function, rewritten rather than patched.
create or replace function public.company_effective_filter_sql_v1(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.company_filter_sql_v2(p_search, coalesce(p_filters, '[]'::jsonb));
begin
  if v_complete is null then return null; end if;
  -- Combine only when there is something to combine. A prefilter identical to
  -- the exact filter narrows nothing and doubles the per-row cost.
  if v_prefilter <> 'true' and v_prefilter is distinct from v_complete then
    return '(' || v_prefilter || ') and (' || v_complete || ')';
  end if;
  return v_complete;
end;
$function$;

-- People: the same composition inside a much larger function. Patched by
-- reading the live definition and replacing one line, so nothing else in it can
-- drift; the marker is asserted before the replacement is applied.
do $patch$
declare
  v_def text := pg_get_functiondef('public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb)'::regprocedure);
  v_marker constant text := 'case when v_prefilter <> ''true'' then ''('' || v_prefilter || '') and '' else '''' end';
  v_replacement constant text := 'case when v_prefilter <> ''true'' and v_prefilter is distinct from v_complete then ''('' || v_prefilter || '') and '' else '''' end';
begin
  if position(v_marker in v_def) = 0 then
    raise exception 'the prefilter composition is not where this migration expects it; refusing to patch blindly';
  end if;
  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

do $verify$
declare
  v_before record;
  v_sql text;
begin
  select * into v_before from search_baseline;

  -- The generated SQL must no longer repeat itself.
  v_sql := public.company_effective_filter_sql_v1('tech', '[]'::jsonb);
  if v_sql like '%) and (%'
     and btrim(split_part(v_sql, ') and (', 1), '(') = btrim(split_part(v_sql, ') and (', 2), ')') then
    raise exception 'the company filter still ANDs a clause with itself: %', v_sql;
  end if;

  -- And the answers must be identical, which is the part that matters.
  if (select total_count from public.search_prospect_workspace_v12(
        'john', '[]'::jsonb, 'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null))
     is distinct from v_before.plain_search then
    raise exception 'a plain search returns a different count than before';
  end if;
  if (select total_count from public.search_prospect_workspace_v12(
        '', '[{"id":"f1","field":"__title","operator":"contains","values":["manager"]}]'::jsonb,
        'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null))
     is distinct from v_before.one_filter then
    raise exception 'a single-filter search returns a different count than before';
  end if;
  -- Search AND filter is the case where the prefilter genuinely differs from the
  -- exact filter, so this proves the combining path is still intact.
  if (select total_count from public.search_prospect_workspace_v12(
        'john', '[{"id":"f1","field":"__title","operator":"contains","values":["manager"]}]'::jsonb,
        'created_at', 'desc', 50, 0, null, '{}'::jsonb, true, null))
     is distinct from v_before.search_and_filter then
    raise exception 'combining a search with a filter no longer returns the same count';
  end if;
  -- Not just the count: the page itself, row for row.
  if (select md5(result_rows::text) from public.search_prospect_workspace_v12(
        '', '[{"id":"f1","field":"__title","operator":"contains","values":["manager"]}]'::jsonb,
        'name', 'asc', 50, 0, null, '{}'::jsonb, true, null))
     is distinct from v_before.page_fingerprint then
    raise exception 'the first page of a filtered search changed';
  end if;
  if (select count(*)::bigint from prospect_results.uncached_company_scope_ids_v1(
        null, '{"search":"tech"}'::jsonb))
     is distinct from v_before.company_scope then
    raise exception 'the company pivot scope resolves a different set of companies';
  end if;

  -- The ceiling 20260902000040 put on the search must survive the replace.
  if not (select proconfig from pg_proc
          where oid = 'public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb)'::regprocedure)
         @> array['statement_timeout=10s'] then
    raise exception 'the search lost its 10s statement timeout in the replace';
  end if;
end;
$verify$;

commit;
