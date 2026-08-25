-- Two performance regressions, fixed together.
--
-- 1. search_prospect_workspace_v11 (20260816005748) added conditional totals but
--    was written as a plain SQL function with prospect_index_matches_v1 inlined —
--    dropping the indexed pre-filter that 20260814000000 introduced precisely to
--    stop filtered searches from taking 14-16 seconds. Because the API calls v11
--    first and only falls back to v10 when v11 is missing, EVERY filtered People
--    DB read has been running the slow path since. v12 below restores the v10
--    execution plan (pre-filter -> scalar matcher -> narrow sort -> hydrate) and
--    keeps v11's conditional-total behaviour.
--
--    v12 also fixes a latent bug in v10: v10 unconditionally joins
--    company_scope_ids_v2, which with an empty scope returns every company id —
--    scanning all of public.companies and silently dropping prospects whose
--    company_id is null. v12 only joins when a scope is actually present, so
--    unscoped results match v11 exactly.
--
-- 2. trg_sync_company_counts is a FOR EACH ROW trigger that runs a full aggregate
--    per row touched. A 50k-row import reindexes 50k rows and therefore runs 50k
--    aggregates. Replaced with statement-level triggers over transition tables
--    that recompute all affected companies in a single grouped pass.

-- ---------------------------------------------------------------------------
-- 1. Fast workspace search
-- ---------------------------------------------------------------------------

create or replace function public.search_prospect_workspace_v12(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at',
  p_direction text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb,
  p_with_total boolean default true
)
returns table(result_rows jsonb, total_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  v_has_scope boolean := v_scope <> '{}'::jsonb;
  v_has_people boolean := (btrim(v_search) <> '' or v_filters <> '[]'::jsonb);
  v_unscoped boolean := (not v_has_people and p_client_id is null and not v_has_scope);
  v_prefilter text;
  v_match_clause text;
  v_scope_cte text;
  v_scope_join text;
  v_order text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_total_expr text;
  v_sql text;
begin
  -- The pre-filter only ever emits conjuncts implied by the real predicate, so
  -- the scalar matcher still has the final say — it just runs on far fewer rows.
  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text);
  else
    v_match_clause := 'true';
  end if;

  -- Only narrow by company when a scope is actually supplied; an empty scope
  -- must not restrict the result set (and must not drop company-less prospects).
  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  else
    v_scope_cte := '';
    v_scope_join := '';
  end if;

  v_order := format($o$
    case when %1$L = 'name' and lower(%2$L) = 'asc' then lower(full_name) end asc,
    case when %1$L = 'name' and lower(%2$L) = 'desc' then lower(full_name) end desc,
    case when %1$L = 'company' and lower(%2$L) = 'asc' then lower(company_name) end asc,
    case when %1$L = 'company' and lower(%2$L) = 'desc' then lower(company_name) end desc,
    case when %1$L = 'title' and lower(%2$L) = 'asc' then lower(title) end asc,
    case when %1$L = 'title' and lower(%2$L) = 'desc' then lower(title) end desc,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'asc' then last_contacted_at end asc nulls first,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'desc' then last_contacted_at end desc nulls last,
    case when %1$L = 'created_at' and lower(%2$L) = 'asc' then created_at end asc,
    created_at desc, id
  $o$, p_sort, p_direction);

  -- Totals, unchanged from v11: none when not requested, the planner's maintained
  -- estimate for the completely unscoped People DB, an exact count otherwise —
  -- which now counts the pre-filtered set rather than the whole index.
  if not p_with_total then
    v_total_expr := 'null::bigint';
  elsif v_unscoped then
    v_total_expr := $t$(
      select pg_class.reltuples::bigint
      from pg_class
      join pg_namespace on pg_namespace.oid = pg_class.relnamespace
      where pg_namespace.nspname = 'public' and pg_class.relname = 'prospect_index'
    )$t$;
  else
    v_total_expr := '(select count(*) from matched)';
  end if;

  v_sql := format($q$
    with %1$s matched as materialized (
      select pi.id, pi.created_at, pi.full_name, pi.company_name, pi.title, pi.last_contacted_at
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched order by %5$s limit %6$s offset %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by %5$s) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_index pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      %8$s
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause, v_order,
       v_limit::text, v_offset::text, v_total_expr);

  return query execute v_sql;
end;
$fn$;

revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Statement-level company counts
-- ---------------------------------------------------------------------------

-- One grouped pass over the affected companies instead of one aggregate per row.
-- Semantics are identical to recompute_company_counts: prospect_count counts the
-- linked prospects, client_count counts the distinct clients touching them.
create or replace function public.recompute_company_counts_bulk(p_company_ids text[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.companies c set
    prospect_count = coalesce(agg.prospect_count, 0),
    client_count = coalesce(agg.client_count, 0)
  from unnest(coalesce(p_company_ids, array[]::text[])) as target(company_id)
  left join (
    select pi.company_id,
      count(distinct pi.id)::integer as prospect_count,
      count(distinct cid)::integer as client_count
    from public.prospect_index pi
    left join lateral unnest(pi.client_ids) as cid on true
    where pi.company_id = any(coalesce(p_company_ids, array[]::text[]))
    group by pi.company_id
  ) agg on agg.company_id = target.company_id
  where c.id = target.company_id;
$$;

-- Transition tables only exist for the operations that produce them, so each
-- operation gets its own trigger and the shared function branches on TG_OP.
create or replace function public.sync_company_counts_statement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids text[];
begin
  if tg_op = 'INSERT' then
    select array_agg(distinct company_id) into v_ids
    from new_rows where company_id is not null;
  elsif tg_op = 'DELETE' then
    select array_agg(distinct company_id) into v_ids
    from old_rows where company_id is not null;
  else
    select array_agg(distinct company_id) into v_ids from (
      select company_id from new_rows where company_id is not null
      union
      select company_id from old_rows where company_id is not null
    ) touched;
  end if;

  if v_ids is not null and cardinality(v_ids) > 0 then
    perform public.recompute_company_counts_bulk(v_ids);
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_company_counts on public.prospect_index;
drop trigger if exists trg_sync_company_counts_insert on public.prospect_index;
drop trigger if exists trg_sync_company_counts_update on public.prospect_index;
drop trigger if exists trg_sync_company_counts_delete on public.prospect_index;

create trigger trg_sync_company_counts_insert
after insert on public.prospect_index
referencing new table as new_rows
for each statement execute function public.sync_company_counts_statement();

create trigger trg_sync_company_counts_update
after update on public.prospect_index
referencing new table as new_rows old table as old_rows
for each statement execute function public.sync_company_counts_statement();

create trigger trg_sync_company_counts_delete
after delete on public.prospect_index
referencing old table as old_rows
for each statement execute function public.sync_company_counts_statement();

revoke execute on function public.recompute_company_counts_bulk(text[]) from public, anon, authenticated;
revoke execute on function public.sync_company_counts_statement() from public, anon, authenticated;
grant execute on function public.recompute_company_counts_bulk(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Trigram indexes for the columns the pre-filter targets
-- ---------------------------------------------------------------------------
-- prospect_prefilter_sql emits `ilike '%...%'` against these columns, but only
-- search_text, company_name and title had trigram support, so the other
-- conjuncts reduced scalar-matcher calls without making the scan itself indexed.

create index if not exists idx_prospect_index_city_trgm on public.prospect_index using gin (city gin_trgm_ops);
create index if not exists idx_prospect_index_state_trgm on public.prospect_index using gin (state gin_trgm_ops);
create index if not exists idx_prospect_index_country_trgm on public.prospect_index using gin (country gin_trgm_ops);
create index if not exists idx_prospect_index_seniority_trgm on public.prospect_index using gin (seniority gin_trgm_ops);
create index if not exists idx_prospect_index_department_trgm on public.prospect_index using gin (department gin_trgm_ops);
create index if not exists idx_prospect_index_work_email_trgm on public.prospect_index using gin (work_email gin_trgm_ops);

analyze public.prospect_index;

-- ---------------------------------------------------------------------------
-- 4. Smoke test
-- ---------------------------------------------------------------------------
-- v12 builds its query as dynamic SQL, so a malformed branch would create
-- successfully and only fail at request time — taking the People DB down after
-- a green deploy. migrate.sh runs each file inside BEGIN/COMMIT, so exercising
-- every branch here means a broken build rolls back instead of shipping.
do $smoke$
declare
  v_row record;
  v_sample_client text;
begin
  select id into v_sample_client from public.clients limit 1;

  -- unscoped, estimated total
  select * into v_row from public.search_prospect_workspace_v12();
  -- free-text search (pre-filter emits the trigram conjunct)
  select * into v_row from public.search_prospect_workspace_v12(p_search => 'a', p_with_total => false);
  -- positive filter (pre-filter narrows), negative filter (matcher only)
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"__title","operator":"contains","values":["director"]}]'::jsonb, p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"__title","operator":"not_contains","values":["intern"]}]'::jsonb, p_with_total => false);
  -- operators the pre-filter deliberately skips
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"__work_email","operator":"empty","values":[]}]'::jsonb, p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"__employee_count","operator":"number_ranges","values":["11:50"]}]'::jsonb, p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"custom:industry","operator":"contains","values":["software"]}]'::jsonb, p_with_total => false);
  -- every sort key, both directions
  select * into v_row from public.search_prospect_workspace_v12(p_sort => 'name', p_direction => 'asc', p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(p_sort => 'company', p_direction => 'desc', p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(p_sort => 'title', p_direction => 'asc', p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(p_sort => 'last_contacted', p_direction => 'desc', p_with_total => false);
  -- client scope, company scope, no-total, paging
  select * into v_row from public.search_prospect_workspace_v12(p_client_id => v_sample_client, p_with_total => false);
  -- The exact-count branch, driven by a filter selective enough that the count is
  -- an index lookup: this must verify the SQL compiles, not stress the database.
  select * into v_row from public.search_prospect_workspace_v12(
    p_filters => '[{"field":"__work_email","operator":"equals","values":["__prospect_sync_smoke_test__@example.invalid"]}]'::jsonb,
    p_with_total => true);
  select * into v_row from public.search_prospect_workspace_v12(
    p_company_scope => '{"search":"","filters":[{"field":"__industry","operator":"contains","values":["software"]}]}'::jsonb, p_with_total => false);
  select * into v_row from public.search_prospect_workspace_v12(p_with_total => false, p_offset => 50);

  -- bulk count recompute, with and without rows
  perform public.recompute_company_counts_bulk(array[]::text[]);
  perform public.recompute_company_counts_bulk(array(select id from public.companies limit 5));
end;
$smoke$;
