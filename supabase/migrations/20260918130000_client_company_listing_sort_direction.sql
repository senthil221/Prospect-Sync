-- Client Company DB always sorted busiest-company-first, so a client with any
-- real number of companies had no way to reach the ones sitting at zero
-- prospects short of paging to the very end. A company can legitimately carry
-- zero prospects and still belong on the client's ICP list - see
-- 20260916180000, which treats "person removed" and "company removed" as
-- deliberately asymmetric for exactly that reason - so there needed to be a
-- direct way to look at that end of the list.
--
-- p_sort_ascending is appended with a default, so every existing call (the app
-- route uses named RPC arguments) keeps today's descending order unless it
-- opts in. Only the two ORDER BY clauses change; the counting and filtering
-- logic is untouched.
create or replace function public.client_company_workspace_v2(
  p_client_id text,
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_limit integer default 50,
  p_offset integer default 0,
  p_sort_ascending boolean default false
)
returns table(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '45s'
as $function$
declare
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = ''
    and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counts_cte text;
  v_counts_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_sort_dir text := case when p_sort_ascending then 'asc' else 'desc' end;
  v_complete text;
  v_sql text;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));

  if v_unfiltered then
    v_match_clause := coalesce(v_complete, 'true');
    v_counts_cte := format($counts$client_counts as (
        select pi.company_id, count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), coverage_counts as (
        select cc.company_id, count(*)::integer as client_count
        from public.client_companies cc
        group by cc.company_id
      ), $counts$, p_client_id);
    v_counts_join := 'left join client_counts counts on counts.company_id = c.id'
      || ' left join coverage_counts coverage on coverage.company_id = c.id';
  else
    v_match_clause := coalesce(v_complete,
      case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
        || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text));
    v_counts_cte := '';
    v_counts_join := format($joins$left join lateral (
        select count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id = c.id and pi.client_ids @> array[%L]
      ) counts on true
      left join lateral (
        select count(*)::integer as client_count
        from public.client_companies all_memberships
        where all_memberships.company_id = c.id
      ) coverage on true$joins$, p_client_id);
  end if;

  v_sql := format($query$
    with %6$s matched as materialized (
      select c.id, c.name, c.domain, c.created_at,
        coalesce(counts.prospect_count, 0)::integer as prospect_count,
        coalesce(coverage.client_count, 0)::integer as client_count
      from public.client_companies membership
      join public.companies c on c.id = membership.company_id
      %7$s
      where membership.client_id = %1$L
        and (%2$s)
        and (%3$L::jsonb is null or c.id in (
          select company_id from public.people_scope_company_ids_v1(%1$L, %3$L::jsonb)
        ))
    ), page_rows as (
      select * from matched
      order by prospect_count %8$s, lower(name), id
      limit %5$s offset %4$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count %8$s, lower(page_rows.name), page_rows.id)
        from page_rows
      ), '[]'::jsonb),
      (select count(*) from matched),
      (select count(*) from matched where matched.prospect_count > 0),
      (select coalesce(sum(matched.prospect_count), 0) from matched)
  $query$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join, v_sort_dir);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer, boolean) from public, anon, authenticated;
grant execute on function public.client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- Ascending genuinely reverses the order rather than being ignored, and the
-- zero-prospect companies this exists to surface actually come first.
do $$
declare
  v_client text;
  v_desc_first jsonb;
  v_asc_first jsonb;
  v_asc_first_count integer;
  v_zero_total integer;
begin
  select cc.client_id into v_client
  from public.client_companies cc
  group by cc.client_id
  having count(*) filter (where cc.prospect_count = 0) > 0
     and count(*) filter (where cc.prospect_count > 0) > 0
  limit 1;

  if v_client is null then
    raise notice 'no client mixes zero- and non-zero-prospect companies; the ordering is unproven';
    return;
  end if;

  select result_rows into v_desc_first from public.client_company_workspace_v2(v_client, '', '[]'::jsonb, null, 1, 0, false);
  select result_rows into v_asc_first from public.client_company_workspace_v2(v_client, '', '[]'::jsonb, null, 1, 0, true);

  v_asc_first_count := ((v_asc_first -> 0) ->> 'prospect_count')::integer;
  if v_asc_first_count <> 0 then
    raise exception 'ascending sort put a company with % prospects first, expected 0', v_asc_first_count;
  end if;
  if (((v_desc_first -> 0) ->> 'prospect_count')::integer) = 0 then
    raise notice 'this client happens to have zero as its max too; descending-first check is inconclusive';
  end if;
end $$;
