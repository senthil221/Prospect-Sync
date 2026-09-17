-- A People search filtered by the company profile stops counting at 50,000.
--
-- WHAT WENT WRONG, MEASURED. Three /api/prospects requests died at 10,048,
-- 10,087 and 10,171 ms on 2026-09-17. search_prospect_workspace_v12 carries
-- statement_timeout=10s, so those are the ceiling, not a coincidence. What the
-- user saw was "This filter combination took longer than the database allows."
--
-- The acute trigger was a company import: it queued 131,819 prospects for
-- re-indexing, and the worker draining that backlog both steals I/O and bumps
-- the prospect data_version on every batch - which invalidates the caller's
-- version-stamped total, so every request recounts from scratch instead of
-- reusing one. The same query measured 2.1s warm, 4.8s cold, and past 10s while
-- that worker ran.
--
-- THE STRUCTURAL PART, WHICH IS WHAT THIS FIXES. A company-profile filter has no
-- indexable form on prospect_index, because the data is in public.companies. The
-- plan is a parallel index-only scan of all 683,784 prospect_index rows feeding a
-- Memoize'd primary-key probe of ~152,000 distinct companies, and the predicate
-- itself - array_to_string(co.keywords, ' | ') ilike '%…%' - can use no index at
-- all. About 2s warm on an idle database, with a 10s budget and no headroom.
--
-- And with p_with_total the query pays that TWICE: `counted` scans the whole
-- table, then `ordered` scans it again for 50 rows. Halving that is the cheapest
-- thing available, and it needs no new index and no change to what the page
-- returns.
--
-- SO THE COUNT IS BOUNDED, AND ONLY FOR THESE FILTERS. Above 50,000 matches the
-- grid shows "50,000+" and offers to count the rest on demand - machinery that
-- already exists on both sides. 20260911140000 removed the old blanket cap
-- deliberately, because an exact count is worth its cost for the ordinary
-- filters; its comment says the branches that honour a cap stay "if a cap ever
-- has to come back". This is that case, narrowed to the filters that actually
-- pay for it. Every other search still counts exactly.
--
-- WHAT THIS DOES NOT DO. It does not make a selective company filter fast: with
-- few matches the bounded count still walks the table to find them, and the page
-- scan is unchanged. It buys back one of the two scans on the heavy case, which
-- is the case that was timing out. Making the predicate index-eligible - an OR
-- of per-column terms so name and short_description can reach their trigram GINs
-- instead of being hidden inside concat_ws - is the larger fix and is not this
-- migration.
-- ---------------------------------------------------------------------------

-- Which filters force the per-row company lookup.
--
-- __employee_count and __company_location are deliberately NOT here: both read
-- columns prospect_index already carries, so they cost nothing extra and must
-- keep their exact count.
create or replace function public.prospect_filters_need_company_lookup_v1(p_filters jsonb)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1
    from jsonb_array_elements(case when jsonb_typeof(p_filters) = 'array' then p_filters else '[]'::jsonb end) as item
    where item->>'field' in (
      '__company_industry', '__company_keywords', '__company_description',
      '__company_technologies', '__company_founded_year', '__company_total_funding')
  );
$$;

-- ---------------------------------------------------------------------------
-- The workspace function bounds the count for exactly those filters.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'::regprocedure);
  v_old constant text :=
E'  else
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows
      from public.prospect_index pi%s
      where (%L is null or pi.client_ids @> array[%L]) and (%s)
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause);
    v_total_expr := ''(select counted.matched_rows from counted)'';';
  v_new constant text :=
E'  elsif public.prospect_filters_need_company_lookup_v1(p_filters) then
    -- Bounded: stop at 50,001 and report 50,000+ rather than scanning the whole
    -- table a second time for a number nobody can read past the first page.
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows from (
        select 1
        from public.prospect_index pi%s
        where (%L is null or pi.client_ids @> array[%L]) and (%s)
        limit 50001
      ) bounded
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause);
    v_total_expr := ''least((select counted.matched_rows from counted), 50000)'';
    v_total_capped_expr := ''((select counted.matched_rows from counted) > 50000)'';
  else
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows
      from public.prospect_index pi%s
      where (%L is null or pi.client_ids @> array[%L]) and (%s)
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause);
    v_total_expr := ''(select counted.matched_rows from counted)'';';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'search_prospect_workspace_v12 no longer contains the unbounded count branch this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('prospect_filters_need_company_lookup_v1' in v_def) = 0
     or position('limit 50001' in v_def) = 0 then
    raise exception 'the bounded-count replacement did not take';
  end if;
  execute v_def;
end $BODY$;

-- ---------------------------------------------------------------------------
-- It is still the same function to everyone who calls it.
do $$
declare
  v_cfg text[];
begin
  select p.proconfig into v_cfg from pg_proc p
   where p.oid = 'public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'::regprocedure;
  if not (array_to_string(v_cfg, ',') like '%statement_timeout%') then
    raise exception 'the workspace function lost its statement_timeout: %', v_cfg;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The classifier answers for the fields that cost, and only those.
do $$
begin
  if not public.prospect_filters_need_company_lookup_v1(
       '[{"field":"__company_keywords","operator":"contains","values":["x"]}]'::jsonb) then
    raise exception 'a company keyword filter must be classified as needing the company lookup';
  end if;
  if public.prospect_filters_need_company_lookup_v1(
       '[{"field":"__employee_count","operator":"number_ranges","values":["1:10"]}]'::jsonb) then
    raise exception 'employee count reads prospect_index and must keep its exact count';
  end if;
  if public.prospect_filters_need_company_lookup_v1(
       '[{"field":"__company_location","operator":"contains","values":["India"]}]'::jsonb) then
    raise exception 'company location reads prospect_index and must keep its exact count';
  end if;
  if public.prospect_filters_need_company_lookup_v1('[]'::jsonb)
     or public.prospect_filters_need_company_lookup_v1('null'::jsonb)
     or public.prospect_filters_need_company_lookup_v1(null) then
    raise exception 'an empty filter set needs no company lookup';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- An ordinary filter still counts exactly, and a company filter now caps.
--
-- Run against real data, because the point of the change is a number the grid
-- prints. A company filter matching more than the cap must report exactly 50,000
-- with the capped flag set; one matching fewer must report its true total, or
-- the cap would be lying about small result sets.
do $$
declare
  v_row record;
  v_true_total bigint;
begin
  -- Heavy: 'software' matched 163,048 prospects when this was written.
  select total_count, total_capped into v_row
  from public.search_prospect_workspace_v12(
    '', '[{"field":"__company_keywords","operator":"contains","values":["software"],"scopes":["keywords"]}]'::jsonb,
    'created_at', 'desc', 1, 0, null, null, true, null) limit 1;

  if v_row.total_count is null then
    raise notice 'the workspace function returned no total; the cap is unproven';
  else
    if v_row.total_count > 50000 then
      raise exception 'a capped count returned %, which is above the cap', v_row.total_count;
    end if;
    if v_row.total_count = 50000 and not v_row.total_capped then
      raise exception 'the count stopped at the cap without setting total_capped; the grid would print 50,000 as exact';
    end if;
  end if;

  -- Light: an ordinary filter must still be exact, or this migration has
  -- quietly capped the whole product.
  select count(*) into v_true_total from public.prospect_index pi
   where pi.esp is not null and pi.esp <> '';
  select total_count, total_capped into v_row
  from public.search_prospect_workspace_v12(
    '', '[{"field":"__esp_type","operator":"not_empty","values":[]}]'::jsonb,
    'created_at', 'desc', 1, 0, null, null, true, null) limit 1;
  if v_row.total_capped then
    raise exception 'an ordinary filter must not be capped';
  end if;
end $$;
