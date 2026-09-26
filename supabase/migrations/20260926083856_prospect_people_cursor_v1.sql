-- Add a keyset page reader for the one People ordering whose complete order is
-- already backed by an index: created_at DESC, id ASC. The existing v13
-- workspace function remains the source of first pages, alternate sorts,
-- company pivots and max-people-per-company queries. This function is additive
-- so the application can feature-gate it and fall back to OFFSET at any time.

create or replace function public.search_prospect_workspace_cursor_v1(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_limit integer default 50,
  p_client_id text default null,
  p_after_created_at timestamptz default null,
  p_after_id text default null,
  p_with_total boolean default false,
  p_known_versions jsonb default null
)
returns table(
  result_rows jsonb,
  total_count bigint,
  scope_capped boolean,
  total_capped boolean,
  data_versions jsonb
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
set statement_timeout = '20s'
as $function$
declare
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  v_has_people boolean := btrim(v_search) <> '' or v_filters <> '[]'::jsonb;
  v_unscoped boolean := not v_has_people and p_client_id is null;
  v_prefilter text;
  v_complete text;
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_versions jsonb;
  v_want_total boolean;
  v_count_cte text;
  v_total_expr text;
  v_ordered_cte text;
  v_client_members bigint;
  v_sql text;
begin
  if (p_after_created_at is null) <> (p_after_id is null) then
    raise exception using errcode = '22023',
      message = 'A People cursor requires both created_at and id.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_filters) item
    where item->>'field' = '__max_people_per_company'
  ) then
    raise exception using errcode = '22023',
      message = 'Max people per company requires the workspace v13 reader.';
  end if;
  if public.prospect_filters_need_company_lookup_v1(v_filters) then
    raise exception using errcode = '22023',
      message = 'Company-profile filters require the workspace v13 count and version contract.';
  end if;

  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  v_versions := public.data_versions_v1(array['prospect']);
  v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;

  -- A cursor never changes the matching set, so the count deliberately has no
  -- cursor predicate. This is the same count contract as workspace v12/v13.
  if not v_want_total then
    v_count_cte := '';
    v_total_expr := 'null::bigint';
  elsif v_unscoped then
    v_count_cte := '';
    v_total_expr := '(select count(*)::bigint from public.prospect_index)';
  else
    v_count_cte := format($count$counted as (
      select count(*)::bigint as matched_rows
      from public.prospect_index pi
      where (%1$L is null or pi.client_ids @> array[%1$L]) and (%2$s)
    ), $count$, p_client_id, v_match_clause);
    v_total_expr := '(select counted.matched_rows from counted)';
  end if;

  -- Keep the measured client-first plan from 20260923090000. Small clients are
  -- read through the membership GIN index and sorted in memory; large/global
  -- scopes walk the (created_at DESC, id ASC) B-tree directly.
  if p_client_id is not null then
    select count(*) into v_client_members from (
      select 1 from public.client_prospects
      where client_id = p_client_id
      limit 50001
    ) members;
  end if;

  if p_client_id is not null and v_client_members <= 50000 then
    v_ordered_cte := format($ordered$client_rows as materialized (
      select pi.id, pi.created_at as sort_key
      from public.prospect_index pi
      where pi.client_ids @> array[%1$L] and (%2$s)
    ), ordered as (
      select client_rows.id, client_rows.sort_key
      from client_rows
      where (%3$L::timestamptz is null
        or client_rows.sort_key < %3$L::timestamptz
        or (client_rows.sort_key = %3$L::timestamptz and client_rows.id > %4$L))
      order by client_rows.sort_key desc, client_rows.id
      limit %5$s
    )$ordered$, p_client_id, v_match_clause, p_after_created_at, p_after_id,
      v_limit::text);
  else
    v_ordered_cte := format($ordered$ordered as (
      select pi.id, pi.created_at as sort_key
      from public.prospect_index pi
      where (%1$L is null or pi.client_ids @> array[%1$L])
        and (%2$s)
        and (%3$L::timestamptz is null
          or pi.created_at < %3$L::timestamptz
          or (pi.created_at = %3$L::timestamptz and pi.id > %4$L))
      order by pi.created_at desc, pi.id
      limit %5$s
    )$ordered$, p_client_id, v_match_clause, p_after_created_at, p_after_id,
      v_limit::text);
  end if;

  v_sql := format($sql$
    with %1$s%2$s, page as (
      select ordered.id,
        row_number() over (order by ordered.sort_key desc, ordered.id) as page_order
      from ordered
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %3$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order)
      from hydrated), '[]'::jsonb),
      %4$s, false, false, %5$L::jsonb
  $sql$, v_count_cte, v_ordered_cte, p_client_id, v_total_expr, v_versions::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.search_prospect_workspace_cursor_v1(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_cursor_v1(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) to service_role;

comment on function public.search_prospect_workspace_cursor_v1(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) is 'Keyset page reader for People created_at DESC, id ASC. Service role only; v13 remains the fallback.';

-- Cursor v1 has a prospect-only version vector and exact-count contract.
-- Prove every filter whose effective v12 contract reads companies is refused,
-- rather than returning correct rows with stale versions or a dishonest total.
do $assert_company_contract$
declare
  v_field text;
begin
  foreach v_field in array array[
    '__company_industry', '__company_keywords', '__company_description',
    '__company_technologies', '__company_founded_year', '__company_total_funding',
    '__incomplete_company_profile'
  ] loop
    if not public.prospect_filters_need_company_lookup_v1(
      jsonb_build_array(jsonb_build_object('field', v_field, 'operator', 'empty', 'values', '[]'::jsonb))) then
      raise exception '% lost the v12 company-lookup classification', v_field;
    end if;
    begin
      perform * from public.search_prospect_workspace_cursor_v1(
        '', jsonb_build_array(jsonb_build_object('field', v_field, 'operator', 'empty', 'values', '[]'::jsonb)),
        1, null, null, null, false, public.data_versions_v1(array['prospect']));
      raise exception 'cursor v1 accepted company-dependent filter %', v_field;
    exception when sqlstate '22023' then
      null;
    end;
  end loop;
end
$assert_company_contract$;

-- The mixed-direction boundary is the easy place to introduce a duplicate or
-- skip: timestamps move backwards while ids move forwards within a tie.
do $assert_ties$
declare
  v_ids text[];
begin
  with sample(id, created_at) as (values
    ('a', '2026-01-02 00:00:00+00'::timestamptz),
    ('b', '2026-01-02 00:00:00+00'::timestamptz),
    ('c', '2026-01-01 00:00:00+00'::timestamptz)
  )
  select array_agg(id order by created_at desc, id) into v_ids
  from sample
  where created_at < '2026-01-02 00:00:00+00'::timestamptz
     or (created_at = '2026-01-02 00:00:00+00'::timestamptz and id > 'a');
  if v_ids is distinct from array['b', 'c']::text[] then
    raise exception 'People cursor mixed-direction boundary is wrong: %', v_ids;
  end if;
end
$assert_ties$;
