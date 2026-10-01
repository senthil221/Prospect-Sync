-- Teach the planner how many companies have no text.
--
-- Every client workspace hides Incomplete Info companies (no keywords AND no
-- short description, 20260929120000), so most People and Company reads carry
--   not exists (select 1 from companies co where co.id = pi.company_id
--               and btrim(coalesce(tag_array_text_v1(co.keywords), '')) = ''
--               and btrim(coalesce(co.short_description, '')) = '')
-- The two blank tests are expressions with no statistics, so the planner
-- guessed 0.5% each - 12 companies for both together. There are 66,298.
--
-- On 2026-10-01 that turned the Manufapp People "Contactable" view (22,725
-- people) into a 20s timeout: under the count's LIMIT the planner chose a
-- nested-loop anti join against a materialized list of "12" companies and made
-- 1.2 billion comparisons (48s when run without the timeout). The same filter
-- without Contactable happened to get a hash join and took 0.3s.
--
-- Extended statistics on the two expressions, together, give the planner the
-- real number (66,055 estimated after ANALYZE); the same view then takes 1.4s.
-- No query changes. Autovacuum's ANALYZE keeps them current from here on.
-- ---------------------------------------------------------------------------

-- CREATE STATISTICS takes SHARE UPDATE EXCLUSIVE on companies: reads and
-- writes carry on; only a concurrent VACUUM/ANALYZE is waited for.
set local lock_timeout = '30s';
set local statement_timeout = '5min';

create statistics if not exists public.companies_icp_text_blank_stats (mcv)
  on (btrim(coalesce(public.tag_array_text_v1(keywords), ''))), (btrim(coalesce(short_description, '')))
  from public.companies;

analyze public.companies;

-- Proof: the planner's estimate for "no text at all" is now within a factor of
-- two of the real count (it was ~5,000x too low).
do $$
declare
  v_plan jsonb;
  v_estimated numeric;
  v_actual bigint;
begin
  select count(*) into v_actual from public.companies co
   where btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
     and btrim(coalesce(co.short_description, '')) = '';
  if v_actual < 1000 then
    raise notice 'Blank-text statistics proof skipped: only % companies without text.', v_actual;
    return;
  end if;
  execute $q$explain (format json) select 1 from public.companies co
    where btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
      and btrim(coalesce(co.short_description, '')) = ''$q$ into v_plan;
  v_estimated := (v_plan->0->'Plan'->>'Plan Rows')::numeric;
  if v_estimated < v_actual / 2.0 or v_estimated > v_actual * 2.0 then
    raise exception 'Blank-text statistics proof: planner estimates % companies without text, there are %', v_estimated, v_actual;
  end if;
  raise notice 'Blank-text statistics proof passed: estimated %, actual %.', v_estimated, v_actual;
end $$;
