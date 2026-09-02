-- Give every cached count a dependency-version vector to be valid at.
--
-- The People grid caches a total client-side and only re-counts when its cache
-- key changes. That key was (filters, search, scope, a dashboard row count, a
-- manual refresh counter), so an edit that changed a row without changing how
-- many rows exist left a stale total on screen until something else moved it.
--
-- Section 5.5 asks for data_versions(entity_type, version) bumped by
-- statement-level triggers, and flags the risk in its own next line: "Updating
-- one version row can serialize concurrent writers. Benchmark this explicitly."
--
-- That risk is designed out rather than measured. A single counter row updated
-- by every import batch is exactly the shape that serializes: the row lock is
-- held until the writing transaction commits, so two concurrent imports queue
-- behind each other for their whole duration, and the benchmark would only tell
-- us how badly. Sequences do not behave that way -- nextval() takes a brief
-- internal lock and never a transaction-length row lock, so two writers never
-- block each other.
--
-- Sequences are also non-transactional, which is the right semantics here: a
-- rolled-back import still bumps the version, so a cache is invalidated for a
-- change that did not happen. Over-invalidation costs one recount.
-- Under-invalidation would show a wrong number, and cannot happen this way.
--
-- companies had no trigger of any kind -- the only one ever created,
-- 20260831210000's search_tsv maintenance, was reverted in 20260831230000 --
-- so company imports, merges and enrichment wrote with nothing watching. It
-- gets statement-level triggers over transition tables here, which is the gap
-- section 5.5 names.
--
-- The vector is per-query, not global. data_versions_v1 is asked only for the
-- entities the compiled query actually reads, so a company import does not
-- invalidate a People count that never looked at a company.
--
-- The staleness decision moves into the function. The alternative -- return the
-- vector and let the client notice on its next request -- is one request late by
-- construction: the request that first sees the new vector has already decided
-- not to count. Passing the caller's known vector in means the answer and the
-- decision to recompute it are made in the same round trip.
--
-- Measured OFFSET depth on the rewritten listing, which is why keyset cursors
-- are NOT part of this migration:
--
--    offset      created_at desc     lower(full_name)
--         0          0.17 ms
--     1,000          1.6  ms
--    10,000          6.7  ms
--   100,000         51    ms              307 ms
--   600,000        224    ms            1,322 ms
--
-- 600,000 is the last page of the table. Every depth is inside the p95 < 2 s
-- budget, and the grid exposes only Next and Previous -- there is no control
-- that jumps to page 12,000, so those depths are reached by clicking Next
-- twelve thousand times. Section 5.3 asks for OFFSET where its measured cost
-- stays within budget and cursors for deep traversal; measured, this is the
-- former. At the 1.5 M target the name sort's last page reaches roughly 2.9 s,
-- so the cursor work becomes real when either the table passes about a million
-- rows or the UI gains a jump-to-page control. Recorded, not built.

begin;

-- Non-transactional change tokens. Deliberately not a table: see the header.
create sequence if not exists public.data_version_prospect as bigint;
create sequence if not exists public.data_version_company as bigint;

create or replace function public.bump_data_version_prospect()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Once per statement, not once per row: an import batch of 5,000 rows bumps
  -- this once. The value carries no meaning beyond "something moved".
  perform nextval('public.data_version_prospect');
  return null;
end;
$function$;

create or replace function public.bump_data_version_company()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform nextval('public.data_version_company');
  return null;
end;
$function$;

drop trigger if exists trg_data_version_prospect_insert on public.prospect_index;
drop trigger if exists trg_data_version_prospect_update on public.prospect_index;
drop trigger if exists trg_data_version_prospect_delete on public.prospect_index;
create trigger trg_data_version_prospect_insert after insert on public.prospect_index
  referencing new table as new_rows for each statement
  execute function public.bump_data_version_prospect();
create trigger trg_data_version_prospect_update after update on public.prospect_index
  referencing old table as old_rows new table as new_rows for each statement
  execute function public.bump_data_version_prospect();
create trigger trg_data_version_prospect_delete after delete on public.prospect_index
  referencing old table as old_rows for each statement
  execute function public.bump_data_version_prospect();

drop trigger if exists trg_data_version_company_insert on public.companies;
drop trigger if exists trg_data_version_company_update on public.companies;
drop trigger if exists trg_data_version_company_delete on public.companies;
create trigger trg_data_version_company_insert after insert on public.companies
  referencing new table as new_rows for each statement
  execute function public.bump_data_version_company();
create trigger trg_data_version_company_update after update on public.companies
  referencing old table as old_rows new table as new_rows for each statement
  execute function public.bump_data_version_company();
create trigger trg_data_version_company_delete after delete on public.companies
  referencing old table as old_rows for each statement
  execute function public.bump_data_version_company();

-- Read the vector for exactly the entities a query depends on. Returning only
-- the requested keys is what keeps a company write from invalidating a People
-- count that never read a company.
--
-- pg_sequence_last_value, not `select last_value from the sequence`. A sequence
-- that has never been called holds last_value = 1 with is_called = false, so the
-- FIRST nextval leaves last_value at 1 and the reading form above cannot see it.
-- That is not a rounding error: it is precisely the first mutation after this
-- migration deploys, silently not invalidating anything. Caught by asserting
-- against a real write in a rolled-back transaction rather than by reading the
-- code. pg_sequence_last_value returns NULL until the first call and the true
-- value after it, so coalescing to 0 gives a counter that moves on every bump.
create or replace function public.data_versions_v1(p_entities text[] DEFAULT ARRAY['prospect', 'company'])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_object_agg(requested.entity, requested.version), '{}'::jsonb)
  from (
    select 'prospect' as entity,
      coalesce(pg_sequence_last_value('public.data_version_prospect'::regclass), 0) as version
    where 'prospect' = any(coalesce(p_entities, array[]::text[]))
    union all
    select 'company',
      coalesce(pg_sequence_last_value('public.data_version_company'::regclass), 0)
    where 'company' = any(coalesce(p_entities, array[]::text[]))
  ) requested;
$function$;

DROP FUNCTION IF EXISTS public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean);

CREATE FUNCTION public.search_prospect_workspace_v12(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true, p_known_versions jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean, data_versions jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '20s'
AS $function$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  -- Mirrors the clamp inside company_scope_ids_v2, so "did the scope hit its
  -- ceiling" is answered against the same number the scope actually used.
  v_scope_limit integer := case
    when coalesce(v_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((v_scope->>'limit')::bigint, 250000))::integer
    else 250000
  end;
  v_has_people boolean := (btrim(v_search) <> '' or v_filters <> '[]'::jsonb);
  v_unscoped boolean := (not v_has_people and p_client_id is null and not v_has_scope);
  v_prefilter text;
  v_match_clause text;
  v_complete text;
  v_scope_cte text;
  v_scope_join text;
  v_capped_expr text;
  v_sort_expr text;
  v_sort_dir text;
  v_sort_nulls text;
  v_order text;
  v_count_cte text;
  v_total_expr text;
  v_total_capped_expr text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  -- One past the number shown, so "is there more" is answered by the same scan
  -- that produces the number. Identical to the company listing.
  v_count_cap constant integer := 50001;
  -- The dependency-version vector this answer is valid at, and whether the
  -- caller's cached total was computed at the same one.
  v_versions jsonb;
  v_want_total boolean;
  v_sql text;
begin
  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
    v_capped_expr := format('((select count(*) from eligible_companies) >= %s)', v_scope_limit::text);
  else
    v_scope_cte := '';
    v_scope_join := '';
    v_capped_expr := 'false';
  end if;

  -- Static, allow-listed sort. p_sort and p_direction never reach the SQL as
  -- text; they choose a branch, and the branch is a constant. An unknown sort
  -- falls to created_at, which is what the previous CASE chain did too.
  v_sort_dir := case when lower(coalesce(p_direction, 'desc')) = 'asc' then 'asc' else 'desc' end;
  case coalesce(p_sort, 'created_at')
    when 'name' then
      v_sort_expr := 'lower(pi.full_name)';
      v_sort_nulls := '';
    when 'company' then
      v_sort_expr := 'lower(pi.company_name)';
      v_sort_nulls := '';
    when 'title' then
      v_sort_expr := 'lower(pi.title)';
      v_sort_nulls := '';
    when 'last_contacted' then
      v_sort_expr := 'pi.last_contacted_at';
      -- Matches idx_prospect_index_last_contacted (DESC NULLS LAST) forwards,
      -- and its exact reverse backwards, so both directions are index-served.
      v_sort_nulls := case when v_sort_dir = 'asc' then ' nulls first' else ' nulls last' end;
    else
      v_sort_expr := 'pi.created_at';
      v_sort_nulls := '';
  end case;
  v_order := format('%s %s%s, pi.id', v_sort_expr, v_sort_dir, v_sort_nulls);

  -- Which entity versions this query actually reads. A People query depends on
  -- the prospect version; one carrying a company scope reads public.companies
  -- through company_scope_ids_v2 and depends on the company version too. A
  -- single-entity query never carries a version it does not read, so a company
  -- import cannot invalidate every People count for no reason.
  v_versions := public.data_versions_v1(
    case when v_has_scope then array['prospect', 'company'] else array['prospect'] end);

  -- The caller caches a total against the vector it was counted at. If any
  -- component has moved since, that total is stale and this call recounts
  -- whether or not it was asked to -- so a completed mutation cannot leave a
  -- stale count on screen waiting for some later page load to notice.
  v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;

  -- The count is its own scan with its own LIMIT. It is not the page's scan
  -- reused, because a set that has been built cannot be short-circuited.
  if not v_want_total then
    v_count_cte := '';
    v_total_expr := 'null::bigint';
    v_total_capped_expr := 'false';
  elsif v_unscoped then
    -- The whole-database total: PostgreSQL's maintained estimate, so no page
    -- load counts 674,804 rows to say so.
    v_count_cte := '';
    v_total_expr := $t$(
      select pg_class.reltuples::bigint
      from pg_class
      join pg_namespace on pg_namespace.oid = pg_class.relnamespace
      where pg_namespace.nspname = 'public' and pg_class.relname = 'prospect_index'
    )$t$;
    v_total_capped_expr := 'false';
  else
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows from (
        select 1 from public.prospect_index pi%s
        where (%L is null or pi.client_ids @> array[%L]) and (%s)
        limit %s
      ) capped
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause, v_count_cap::text);
    v_total_expr := format('(select least(counted.matched_rows, %s) from counted)', (v_count_cap - 1)::text);
    v_total_capped_expr := format('(select counted.matched_rows > %s from counted)', (v_count_cap - 1)::text);
  end if;

  v_sql := format($q$
    with %1$s%2$sordered as (
      select pi.id, %3$s as sort_key
      from public.prospect_index pi%4$s
      where (%5$L is null or pi.client_ids @> array[%5$L]) and (%6$s)
      order by %7$s
      limit %8$s offset %9$s
    ), page as (
      select ordered.id,
        row_number() over (order by ordered.sort_key %10$s%11$s, ordered.id) as page_order
      from ordered
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %5$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      %12$s,
      %13$s,
      %14$s,
      %15$L::jsonb
  $q$, v_scope_cte, v_count_cte, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_order, v_limit::text, v_offset::text, v_sort_dir, v_sort_nulls,
       v_total_expr, v_capped_expr, v_total_capped_expr, v_versions::text);

  return query execute v_sql;
end;
$function$;

revoke execute on function public.bump_data_version_prospect() from public, anon, authenticated;
revoke execute on function public.bump_data_version_company() from public, anon, authenticated;
revoke execute on function public.data_versions_v1(text[]) from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.data_versions_v1(text[]) to service_role;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb) to service_role;

commit;
