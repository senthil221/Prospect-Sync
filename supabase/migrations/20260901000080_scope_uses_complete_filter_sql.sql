-- Let the company scope skip the per-row predicate, like its siblings already do.
--
-- company_effective_filter_sql_v1 returns a complete SQL predicate whenever
-- company_filter_sql_v2 can express the whole filter set in SQL. filter_companies_v4
-- and client_company_workspace_v2 both use it and fall back to
-- company_matches_filters_v1 only when it returns null. company_scope_ids_v2 never
-- adopted it, so it always called the per-row function -- with the entire filter
-- payload passed as jsonb on every row.
--
-- That is invisible on small pastes and quadratic on large ones: the prefilter
-- narrows to N companies, then the row function rescans an N-element jsonb array
-- for each of them. Measured with a scope of pasted domains:
--
--   Companies tab, 10,000 domains (already uses the complete predicate) ....   860 ms
--   See People, same 10,000-domain scope (per-row function) ............... 94,614 ms
--
-- Both return the same 10,000 companies and 45,177 prospects; only the plan
-- differs. With the complete predicate the scope becomes an index scan over
-- normalized_domain, the same shape the Companies tab has been using all along.
--
-- The unfiltered guard from 20260901000010 is kept ahead of this: with no search
-- and no filters the predicate is 'true' for every row and neither path is worth
-- entering.

begin;

CREATE OR REPLACE FUNCTION public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb)
 RETURNS TABLE(company_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '15s'
AS $function$
declare
  v_search text := coalesce(p_company_scope->>'search', '');
  v_filters jsonb := coalesce(p_company_scope->'filters', '[]'::jsonb);
  v_prefilter text := public.company_prefilter_sql(v_search, v_filters);
  v_complete text;
  v_limit integer := case
    when coalesce(p_company_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((p_company_scope->>'limit')::bigint, 250000))::integer
    else 250000
  end;
  v_sql text := 'select c.id from public.companies c where ';
begin
  -- With an empty search and no filters, company_matches_filters_v1 reduces to
  -- `true and not exists (select from jsonb_array_elements('[]'))` and returns
  -- true for every row. Calling it 418,151 times to learn that costs 93 seconds;
  -- not calling it costs 514 ms for the identical result set.
  if btrim(v_search) = '' and v_filters = '[]'::jsonb then
    return query execute format('select c.id from public.companies c order by c.id limit %s', v_limit);
    return;
  end if;

  -- Prefer the complete SQL predicate; only fall back to the per-row function for
  -- filter shapes it cannot express.
  v_complete := public.company_effective_filter_sql_v1(v_search, v_filters);

  v_sql := v_sql
    || coalesce(v_complete,
         case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
           || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', v_search, v_filters::text))
    || format(' order by c.id limit %s', v_limit);
  return query execute v_sql;
end;
$function$;

revoke execute on function public.company_scope_ids_v2(text, jsonb) from public, anon, authenticated;
grant execute on function public.company_scope_ids_v2(text, jsonb) to service_role;

commit;
