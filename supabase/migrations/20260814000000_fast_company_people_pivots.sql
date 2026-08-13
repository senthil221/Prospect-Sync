-- Company <-> People pivots ("See People" / "See Companies") timed out on real
-- data (14.7s / 16.6s) because filter_companies_v3 and search_prospect_workspace_v10
-- evaluated the opaque scalar matcher prospect_index_matches_v1 once per row across
-- the whole prospect_index (and, for companies, once per company). The scalar
-- function is a planner black box, so none of the trigram/btree indexes on
-- prospect_index could be used.
--
-- Fix: derive an index-friendly SQL pre-filter from the same filter payload and
-- apply it BEFORE the scalar matcher. The pre-filter only ever emits conjuncts
-- that are implied by the real predicate (positive contains/equals on whitelisted,
-- indexed columns + the search-text trigram), so the scalar matcher still has the
-- final say and results are byte-for-byte identical -- it just runs on far fewer
-- rows. All emitted values go through format()/%L, so the dynamic SQL is injection
-- safe. Function signatures are unchanged, so the deployed app needs no redeploy.

-- 1. Build an index-usable pre-filter (a boolean SQL expression over alias `pi`)
--    that is guaranteed to be implied by prospect_index_matches_v1(pi, search, filters).
create or replace function public.prospect_prefilter_sql(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  value_parts text[];
  value_text text;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('pi.search_text ilike %L', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    -- Only positive, index-friendly operators narrow safely. Every other operator
    -- (not_contains, empty, boolean, number_ranges, custom fields, list membership)
    -- is left entirely to the scalar matcher.
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';
    column_expr := case field_key
      when '__name' then 'pi.full_name'
      when '__first_name' then 'pi.first_name'
      when '__last_name' then 'pi.last_name'
      when '__company' then 'pi.company_name'
      when '__company_domain' then 'pi.company_domain'
      when '__title' then 'pi.title'
      when '__seniority' then 'pi.seniority'
      when '__department' then 'pi.department'
      when '__work_email' then 'pi.work_email'
      when '__personal_email' then 'pi.personal_email'
      when '__linkedin' then 'pi.linkedin_url'
      when '__city' then 'pi.city'
      when '__state' then 'pi.state'
      when '__country' then 'pi.country'
      when '__company_city' then 'pi.company_city'
      when '__company_state' then 'pi.company_state'
      when '__company_country' then 'pi.company_country'
      when '__esp' then 'pi.esp'
      when '__email_provider_type' then 'pi.email_provider_type'
      when '__tags' then 'pi.tag_text'
      else null
    end;
    if column_expr is null then continue; end if;

    value_parts := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      if operator_key = 'contains' then
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      else
        value_parts := value_parts || format('lower(%s) = lower(%L)', column_expr, value_text);
      end if;
    end loop;
    -- A filter matches if ANY of its values match (OR); filters combine with AND.
    if cardinality(value_parts) > 0 then
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$$;

-- 2. Distinct company ids whose people match a People-DB scope, in ONE indexed
--    pass. Replaces the per-company correlated EXISTS used by "See Companies".
create or replace function public.people_scope_company_ids_v1(p_client_id text, p_scope jsonb)
returns table(company_id text)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_search text := coalesce(p_scope->>'search', '');
  v_filters jsonb := coalesce(p_scope->'filters', '[]'::jsonb);
  v_prefilter text;
  v_sql text := 'select distinct pi.company_id from public.prospect_index pi where pi.company_id is not null';
begin
  if p_scope is null then return; end if;
  v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
  if p_client_id is not null then
    v_sql := v_sql || format(' and pi.client_ids @> array[%L]', p_client_id);
  end if;
  if v_prefilter <> 'true' then
    v_sql := v_sql || ' and (' || v_prefilter || ')';
  end if;
  v_sql := v_sql || format(' and public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text);
  return query execute v_sql;
end;
$$;

-- 3. "See Companies": same signature as before; the only change is the people
--    scope, which now uses the inverted, indexed helper instead of a per-company
--    EXISTS, plus a guard timeout so it never inherits the 8s authenticator cap.
create or replace function public.filter_companies_v3(
  p_search text default '',
  p_names text[] default '{}',
  p_domains text[] default '{}',
  p_seniority text[] default '{}',
  p_locations text[] default '{}',
  p_client_id text default null,
  p_people_scope jsonb default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
language sql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $$
  with base as (
    select c.id, c.name, c.domain, c.created_at
    from public.companies c
    where (coalesce(p_search, '') = '' or c.name ilike '%' || p_search || '%' or c.domain ilike '%' || p_search || '%')
      and (coalesce(cardinality(p_names), 0) = 0 or exists (select 1 from unnest(p_names) selected where c.name ilike '%' || selected || '%'))
      and (coalesce(cardinality(p_domains), 0) = 0 or c.normalized_domain = any(p_domains))
      and ((coalesce(cardinality(p_seniority), 0) = 0 and coalesce(cardinality(p_locations), 0) = 0) or exists (
        select 1 from public.prospect_index qualifier
        where qualifier.company_id = c.id
          and (p_client_id is null or qualifier.client_ids @> array[p_client_id])
          and (coalesce(cardinality(p_seniority), 0) = 0 or qualifier.seniority = any(p_seniority))
          and (coalesce(cardinality(p_locations), 0) = 0 or exists (
            select 1 from unnest(p_locations) loc where concat_ws(', ', nullif(qualifier.city, ''), nullif(qualifier.state, ''), nullif(qualifier.country, '')) ilike '%' || loc || '%'
          ))
      ))
      and (p_client_id is null or exists (select 1 from public.prospect_index scoped where scoped.company_id = c.id and scoped.client_ids @> array[p_client_id]))
      -- People-DB scope now resolves through the indexed helper (one pass) instead
      -- of a per-company correlated EXISTS over the opaque scalar matcher.
      and (p_people_scope is null or c.id in (select company_id from public.people_scope_company_ids_v1(p_client_id, p_people_scope)))
  ), agg as (
    select b.id, b.name, b.domain, b.created_at,
      coalesce(counts.prospect_count, 0) as prospect_count,
      coalesce(counts.client_count, 0) as client_count
    from base b
    left join lateral (
      select count(distinct pi.id)::integer as prospect_count, count(distinct client_id)::integer as client_count
      from public.prospect_index pi
      left join lateral unnest(pi.client_ids) client_id on true
      where pi.company_id = b.id and (p_client_id is null or pi.client_ids @> array[p_client_id])
    ) counts on true
  ), counted as (
    select count(*)::integer as total_count,
      count(*) filter (where prospect_count > 0)::integer as covered_count,
      coalesce(sum(prospect_count), 0)::integer as prospect_total
    from agg
  ), page as (
    select id, name, domain, created_at, prospect_count, client_count
    from agg order by prospect_count desc, lower(name), id
    offset greatest(coalesce(p_offset, 0), 0)
    limit greatest(1, least(coalesce(p_limit, 50), 5000))
  )
  select coalesce((select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id) from page), '[]'::jsonb),
    counted.total_count, counted.covered_count, counted.prospect_total
  from counted;
$$;

-- 4. "See People": same signature/return; adds the indexed pre-filter to the
--    people-matching step so a filter applied inside a scoped view no longer
--    scans the whole index.
create or replace function public.search_prospect_workspace_v10(
  p_search text default '', p_filters jsonb default '[]'::jsonb,
  p_sort text default 'created_at', p_direction text default 'desc',
  p_limit integer default 50, p_offset integer default 0,
  p_client_id text default null, p_company_scope jsonb default '{}'::jsonb
)
returns table(result_rows jsonb, total_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $fn$
declare
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_order text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  else
    v_match_clause := 'true';
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

  v_sql := format($q$
    with eligible_companies as materialized (
      select company_id from public.company_scope_ids_v2(%1$L, %2$L::jsonb)
    ), matched as materialized (
      select pi.id, pi.created_at, pi.full_name, pi.company_name, pi.title, pi.last_contacted_at
      from public.prospect_index pi
      join eligible_companies eligible on eligible.company_id = pi.company_id
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched order by %5$s limit %6$s offset %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by %5$s) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_index pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      (select count(*) from matched)
  $q$, p_client_id, p_company_scope::text, p_client_id, v_match_clause, v_order, v_limit::text, v_offset::text);

  return query execute v_sql;
end;
$fn$;

-- 5. Scoped CSV export uses the same fast pre-filter (keyset paginated).
create or replace function public.search_prospect_export_v4(
  p_search text default '', p_filters jsonb default '[]'::jsonb, p_client_id text default null,
  p_company_scope jsonb default '{}'::jsonb, p_after_created_at timestamptz default null,
  p_after_id text default null, p_limit integer default 5000, p_with_total boolean default false
)
returns table(result_rows jsonb, total_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '60s'
as $fn$
declare
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  else
    v_match_clause := 'true';
  end if;

  v_sql := format($q$
    with eligible_companies as materialized (
      select company_id from public.company_scope_ids_v2(%1$L, %2$L::jsonb)
    ), matched as materialized (
      select pi.id, pi.created_at
      from public.prospect_index pi
      join eligible_companies eligible on eligible.company_id = pi.company_id
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched
      where %5$L::timestamptz is null or (matched.created_at, matched.id) < (%5$L::timestamptz, coalesce(%6$L, ''))
      order by matched.created_at desc, matched.id desc
      limit %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_index pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      case when %8$L then (select count(*) from matched) else null end
  $q$, p_client_id, p_company_scope::text, p_client_id, v_match_clause,
       p_after_created_at, p_after_id, v_limit::text, p_with_total);

  return query execute v_sql;
end;
$fn$;

revoke execute on function public.prospect_prefilter_sql(text, jsonb) from public, anon, authenticated;
revoke execute on function public.people_scope_company_ids_v1(text, jsonb) from public, anon, authenticated;
grant execute on function public.prospect_prefilter_sql(text, jsonb) to service_role;
grant execute on function public.people_scope_company_ids_v1(text, jsonb) to service_role;
