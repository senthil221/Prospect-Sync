-- Page-first client People reader. Unlike cursor v2 this RPC never counts the
-- match set: it reads one extra row to say whether an adjacent page exists.
-- The independent application flag keeps every established v13/v2 path as the
-- rollback path until the page-first contract has passed release validation.

create or replace function public.search_prospect_workspace_page_v1(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_limit integer default 50,
  p_client_id text default null,
  p_after_created_at timestamptz default null,
  p_after_id text default null
)
returns table(
  result_rows jsonb,
  has_more boolean,
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
  v_company_lookup boolean;
  v_ordered_cte text;
  v_client_members bigint;
  v_sql text;
begin
  if nullif(btrim(p_client_id), '') is null then
    raise exception using errcode = '22023',
      message = 'Client People page v1 requires a client id.';
  end if;
  if (p_after_created_at is null) <> (p_after_id is null) then
    raise exception using errcode = '22023',
      message = 'A People page boundary requires both created_at and id.';
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

  select count(*) into v_client_members from (
    select 1 from public.client_prospects
    where client_id = p_client_id
    limit 50001
  ) members;

  -- Keep the boundary inside the materialized client candidate, matching the
  -- measured v2 plan. The extra row is only an existence proof for Next.
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
      (v_limit + 1)::text);
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
      (v_limit + 1)::text);
  end if;

  v_sql := format($sql$
    with %1$s, page as (
      select ordered.id,
        row_number() over (order by ordered.sort_key desc, ordered.id) as page_order
      from ordered
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %2$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order)
      from hydrated where page_order <= %3$s), '[]'::jsonb),
      exists(select 1 from page where page_order > %3$s), %4$L::jsonb
  $sql$, v_ordered_cte, p_client_id, v_limit::text, v_versions::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.search_prospect_workspace_page_v1(
  text, jsonb, integer, text, timestamptz, text
) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_page_v1(
  text, jsonb, integer, text, timestamptz, text
) to service_role;

comment on function public.search_prospect_workspace_page_v1(
  text, jsonb, integer, text, timestamptz, text
) is 'Count-free client People page reader for created_at DESC, id ASC; returns 50 rows plus has_more and dependency versions.';

-- Catalog-only deployment proof. Customer tables are exercised by the
-- disposable parity fixture, never scanned while this migration is applied.
do $assert_contract$
declare
  v_proc regprocedure := 'public.search_prospect_workspace_page_v1(text,jsonb,integer,text,timestamptz,text)'::regprocedure;
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
    select 1 from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    where c.conrelid = 'public.prospect_index'::regclass and c.contype = 'p'
      and cardinality(c.conkey) = 1 and a.attname = 'id'
  ) into v_id_is_primary;
  if position('security definer' in lower(v_def)) = 0
     or position('client_rows as materialized' in lower(v_def)) = 0
     or position('pi.created_at <= %3$l::timestamptz' in lower(v_def)) = 0
     or position('(v_limit + 1)::text' in lower(v_def)) = 0
     or position('counted as (' in lower(v_def)) <> 0
     or not ('search_path=pg_catalog, public' = any(v_config))
     or not ('statement_timeout=10s' = any(v_config))
     or v_created_not_null is distinct from true
     or v_id_is_primary is distinct from true
     or not has_function_privilege('service_role', v_proc, 'execute')
     or has_function_privilege('anon', v_proc, 'execute')
     or has_function_privilege('authenticated', v_proc, 'execute') then
    raise exception 'client People page v1 lost a security, plan, boundary, no-count or timeout invariant';
  end if;
end
$assert_contract$;
