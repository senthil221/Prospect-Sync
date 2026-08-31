-- Make the filter-value dropdown stop scanning the whole table eight times.
--
-- pg_stat_statements over an 8.5 hour window put this at the top of real user
-- traffic: 17 calls, 39,406 ms mean, 43,307 ms max. That is the type-ahead in
-- every filter picker, so opening a filter and typing meant a ~40 second wait for
-- 50 dropdown rows.
--
-- The v3 body was one SQL statement shaped like this:
--
--   with scoped as (select ps.* from public.prospect_index ps where ...),
--        raw_values as (
--          select ... from scoped ps where p_field not in (...)   -- scalar fields
--          union all select ... from scoped ps where p_field = '__keywords'
--          union all select ... from scoped ps where p_field = '__lists'
--          ... eight branches in total
--        )
--
-- Three costs compounded there:
--
--   1. `scoped` selects ps.*, so all 52 columns including the all_data jsonb are
--      carried for 674,804 rows when a single column is wanted.
--   2. p_field is a parameter, so `where p_field = '__keywords'` is a run-time
--      filter rather than something the planner can prune. Every branch runs on
--      every call, re-reading the CTE.
--   3. p_search is applied after raw_values is built, so a search still computes
--      values for all 674,804 rows before discarding almost all of them.
--
-- The near-identical mean and max (39.4s vs 43.3s) show the scan dominating,
-- regardless of which field was asked for.
--
-- So build one branch with dynamic SQL, project one column, and push the search
-- predicate onto the raw column where the existing trigram indexes
-- (idx_prospect_index_title_trgm, _company_trgm, _work_email_trgm, and the rest)
-- can serve it.
--
-- Semantics are unchanged and deliberately so:
--   * values are btrimmed, blanks dropped, grouped by lower(value)
--   * min(value) is the display form, count(distinct prospect_id) the count
--     (distinct still matters: a prospect with a repeated keyword must count once)
--   * ordering stays match_count desc, lower(value); the limit stays 1..100
--   * fields with no mapping -- __employee_count, anything unknown -- still return
--     no rows, matching v3 where they produced '' and were filtered out
--
-- Pushing the search down is exact rather than approximate: p_search is btrimmed
-- before use, and for a term with no leading or trailing whitespace
-- `btrim(col) ilike '%term%'` and `col ilike '%term%'` select the same rows.

begin;

CREATE OR REPLACE FUNCTION public.prospect_filter_values_v3(p_field text, p_search text DEFAULT ''::text, p_client_id text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(value text, match_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_search text := btrim(coalesce(p_search, ''));
  v_from text := 'public.prospect_index ps';
  v_value_expr text;
  v_conditions text[] := array[]::text[];
  v_sql text;
begin
  -- One source expression, chosen here instead of unioned in the query.
  if p_field = '__keywords' then
    v_from := 'public.prospect_index ps cross join lateral unnest(ps.keywords) as item(raw)';
    v_value_expr := 'item.raw';
  elsif p_field = '__lists' then
    v_from := 'public.prospect_index ps cross join lateral unnest(ps.list_names) as item(raw)';
    v_value_expr := 'item.raw';
  elsif p_field = '__clients' then
    v_from := 'public.prospect_index ps cross join lateral unnest(ps.client_names) as item(raw)';
    v_value_expr := 'item.raw';
  elsif p_field = '__tags' then
    v_from := 'public.prospect_index ps'
      || ' join public.prospect_tag_links ptl on ptl.prospect_id = ps.id'
      || ' join public.prospect_tags pt on pt.id = ptl.tag_id';
    v_value_expr := 'pt.name';
  elsif p_field = '__last_contacted' then
    v_value_expr := 'to_char(ps.last_contacted_at at time zone ''UTC'', ''YYYY-MM-DD'')';
    v_conditions := v_conditions || 'ps.last_contacted_at is not null';
  elsif p_field like 'custom:%' then
    v_value_expr := format($e$coalesce((
      select string_agg(entry.value, ' | ' order by entry.key)
      from jsonb_each_text(ps.all_data) entry(key, value)
      where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = %L
    ), '')$e$, substring(p_field from 8));
  else
    v_value_expr := case p_field
      when '__name' then 'ps.full_name'
      when '__first_name' then 'ps.first_name'
      when '__last_name' then 'ps.last_name'
      when '__company' then 'ps.company_name'
      when '__email' then 'concat_ws('' '', ps.work_email, ps.personal_email)'
      when '__work_email' then 'ps.work_email'
      when '__personal_email' then 'ps.personal_email'
      when '__title' then 'ps.title'
      when '__linkedin' then 'ps.linkedin_url'
      when '__city' then 'ps.city'
      when '__state' then 'ps.state'
      when '__country' then 'ps.country'
      when '__person_location' then 'coalesce(nullif(ps.location, ''''), concat_ws('', '', nullif(ps.city, ''''), nullif(ps.state, ''''), nullif(ps.country, '''')))'
      when '__company_location' then 'concat_ws('', '', nullif(ps.company_location, ''''), nullif(ps.company_city, ''''), nullif(ps.company_state, ''''), nullif(ps.company_country, ''''))'
      when '__company_city' then 'ps.company_city'
      when '__company_state' then 'ps.company_state'
      when '__company_country' then 'ps.company_country'
      when '__seniority' then 'ps.seniority'
      when '__department' then 'ps.department'
      when '__esp' then 'ps.esp'
      when '__email_provider_type' then 'ps.email_provider_type'
      else null
    end;
  end if;

  -- v3 produced '' for an unmapped field and then filtered it out, and had no
  -- branch at all for __employee_count. Both cases returned nothing; so does this.
  if v_value_expr is null then return; end if;

  if p_client_id is not null then
    v_conditions := v_conditions || format('ps.client_ids @> array[%L]::text[]', p_client_id);
  end if;

  -- Pushed into the scan so a trigram index can answer it, rather than being
  -- applied after every row's value has been computed.
  if v_search <> '' then
    v_conditions := v_conditions || format('(%s) ilike %L', v_value_expr, '%' || v_search || '%');
  end if;

  v_sql := format($q$
    select grouped.value, grouped.match_count
    from (
      select min(source.candidate) as value, count(distinct source.prospect_id) as match_count
      from (
        select btrim(%1$s) as candidate, ps.id as prospect_id
        from %2$s
        %3$s
      ) source
      where source.candidate <> ''
      group by lower(source.candidate)
    ) grouped
    order by grouped.match_count desc, lower(grouped.value)
    limit %4$s
  $q$,
    v_value_expr,
    v_from,
    case when cardinality(v_conditions) > 0
      then 'where ' || array_to_string(v_conditions, ' and ') else '' end,
    v_limit::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.prospect_filter_values_v3(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.prospect_filter_values_v3(text, text, text, integer) to service_role;

commit;
