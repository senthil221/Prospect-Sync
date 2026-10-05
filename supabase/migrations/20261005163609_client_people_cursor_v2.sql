-- Add the client-only keyset reader after the global cursor v1.  Page one still
-- comes from workspace v13; this function reads only an adjacent client page
-- whose opaque boundary was issued by the application.  Keeping it additive
-- makes CLIENT_PROSPECT_CURSOR_PAGINATION=0 an immediate OFFSET fallback.

create or replace function public.search_prospect_workspace_cursor_v2(
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
set statement_timeout = '10s'
as $function$
declare
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  v_has_people boolean := btrim(v_search) <> '' or v_filters <> '[]'::jsonb;
  v_prefilter text;
  v_complete text;
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_versions jsonb;
  v_want_total boolean;
  v_company_lookup boolean;
  v_count_cte text;
  v_total_expr text;
  v_total_capped_expr text := 'false';
  v_ordered_cte text;
  v_client_members bigint;
  v_sql text;
begin
  if nullif(btrim(p_client_id), '') is null then
    raise exception using errcode = '22023',
      message = 'Client People cursor v2 requires a client id.';
  end if;
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

  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' and v_prefilter is distinct from v_complete
      then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  v_company_lookup := public.prospect_filters_need_company_lookup_v1(v_filters);
  v_versions := public.data_versions_v1(
    case when v_company_lookup then array['prospect', 'company'] else array['prospect'] end
  );
  v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;

  -- The cursor narrows only the page, never the counted matching set. Company
  -- profile filters retain v12's 50,000+ contract; ordinary filters stay exact.
  if not v_want_total then
    v_count_cte := '';
    v_total_expr := 'null::bigint';
  elsif v_company_lookup then
    v_count_cte := format($count$counted as (
      select count(*)::bigint as matched_rows from (
        select 1
        from public.prospect_index pi
        where pi.client_ids @> array[%1$L] and (%2$s)
        limit 50001
      ) bounded
    ), $count$, p_client_id, v_match_clause);
    v_total_expr := 'least((select counted.matched_rows from counted), 50000)';
    v_total_capped_expr := '((select counted.matched_rows from counted) > 50000)';
  else
    v_count_cte := format($count$counted as (
      select count(*)::bigint as matched_rows
      from public.prospect_index pi
      where pi.client_ids @> array[%1$L] and (%2$s)
    ), $count$, p_client_id, v_match_clause);
    v_total_expr := '(select counted.matched_rows from counted)';
  end if;

  select count(*) into v_client_members from (
    select 1 from public.client_prospects
    where client_id = p_client_id
    limit 50001
  ) members;

  -- The boundary belongs inside the materialized candidate set. This preserves
  -- the measured client_ids GIN-first plan while halving the rows sorted on a
  -- deep adjacent page. Large clients retain the ordered-index fallback.
  if v_client_members <= 50000 then
    v_ordered_cte := format($ordered$client_rows as materialized (
      select pi.id, pi.created_at as sort_key
      from public.prospect_index pi
      where pi.client_ids @> array[%1$L]
        and (%2$s)
        and (%3$L::timestamptz is null or pi.created_at <= %3$L::timestamptz)
        and (%3$L::timestamptz is null
          or pi.created_at < %3$L::timestamptz
          or (pi.created_at = %3$L::timestamptz and pi.id > %4$L))
    ), ordered as (
      select client_rows.id, client_rows.sort_key
      from client_rows
      order by client_rows.sort_key desc, client_rows.id
      limit %5$s
    )$ordered$, p_client_id, v_match_clause, p_after_created_at, p_after_id,
      v_limit::text);
  else
    v_ordered_cte := format($ordered$ordered as (
      select pi.id, pi.created_at as sort_key
      from public.prospect_index pi
      where pi.client_ids @> array[%1$L]
        and (%2$s)
        and (%3$L::timestamptz is null or pi.created_at <= %3$L::timestamptz)
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
      %4$s, false, %5$s, %6$L::jsonb
  $sql$, v_count_cte, v_ordered_cte, p_client_id, v_total_expr,
    v_total_capped_expr, v_versions::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.search_prospect_workspace_cursor_v2(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_cursor_v2(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) to service_role;

comment on function public.search_prospect_workspace_cursor_v2(
  text, jsonb, integer, text, timestamptz, text, boolean, jsonb
) is 'Client-only keyset page reader for People created_at DESC, id ASC. Page one and unsupported shapes remain on workspace v13.';

-- Catalog-only deploy proof: no customer table is scanned while the migration
-- lock is held. Disposable fixtures below the migration exercise row parity.
do $assert_contract$
declare
  v_proc regprocedure := 'public.search_prospect_workspace_cursor_v2(text,jsonb,integer,text,timestamptz,text,boolean,jsonb)'::regprocedure;
  v_def text := pg_get_functiondef(v_proc);
  v_config text[];
  v_created_not_null boolean;
  v_id_is_primary boolean;
begin
  select proconfig into v_config from pg_proc where oid = v_proc;
  select attnotnull into v_created_not_null
  from pg_attribute
  where attrelid = 'public.prospect_index'::regclass and attname = 'created_at' and not attisdropped;
  select exists (
    select 1
    from pg_constraint constraint_row
    join pg_attribute attribute_row
      on attribute_row.attrelid = constraint_row.conrelid
     and attribute_row.attnum = any(constraint_row.conkey)
    where constraint_row.conrelid = 'public.prospect_index'::regclass
      and constraint_row.contype = 'p'
      and attribute_row.attname = 'id'
  ) into v_id_is_primary;
  if position('security definer' in lower(v_def)) = 0
     or position('client_rows as materialized' in lower(v_def)) = 0
     or position('pi.created_at <= %3$l::timestamptz' in lower(v_def)) = 0
     or position('pi.created_at < %3$l::timestamptz' in lower(v_def)) = 0
     or position('limit 50001' in lower(v_def)) = 0
     or not ('search_path=pg_catalog, public' = any(v_config))
     or not ('statement_timeout=10s' = any(v_config))
     or v_created_not_null is distinct from true
     or v_id_is_primary is distinct from true
     or not has_function_privilege('service_role', v_proc, 'execute')
     or has_function_privilege('anon', v_proc, 'execute')
     or has_function_privilege('authenticated', v_proc, 'execute') then
    raise exception 'client People cursor v2 lost a security, plan, boundary, cap or timeout invariant';
  end if;
end
$assert_contract$;

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
    raise exception 'client People cursor v2 mixed-direction boundary is wrong: %', v_ids;
  end if;
end
$assert_ties$;
