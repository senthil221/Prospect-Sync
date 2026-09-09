-- The classifier taxonomy, with counts, for the Job Title & Seniority filters.
--
-- The three classifier fields have no value picker. prospect_filter_values_v3
-- returns zero rows for __title_seniority_tier, __title_department and
-- __title_sub_department, so the only way to filter on them today is to know a
-- value and type it exactly - "senior_ic", "Demand Gen & Performance" - which
-- nobody does. The fields have been filterable and unusable at the same time.
--
-- This returns the whole taxonomy rather than the values present in the data, so
-- a department with no people is still offered and reads 0 rather than vanishing.
-- The structure comes from title_department_keywords, which is what the CSVs sync
-- into, so adding a sub-department to a CSV adds it to the picker with no code
-- change - the same property that makes the keyword lists the place to edit
-- behaviour.
--
-- ONE SCAN, THREE GROUPINGS. Counting the three fields separately is three
-- passes over 681,785 rows, about 1.7s. GROUPING SETS does it in one pass in
-- 1.0s, which is what makes this cheap enough to hold behind a short cache
-- rather than a background job.
--
-- Order and display names are deliberately NOT here. The tiers have a rank
-- (owner beats c_suite beats vp) and want labels a person can read - "C-Suite",
-- not "c_suite" - and both belong with the other presentation decisions in
-- lib/title-taxonomy.ts rather than being half in SQL. This returns data.

begin;

create or replace function public.prospect_title_taxonomy_v1(p_client_id text default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
  -- MATERIALIZED is load-bearing. Three CTEs below read `counted`, and since
  -- PostgreSQL 12 a CTE referenced more than once is inlined by default - so the
  -- grouping scan ran three times and the function took 3.0s against the 1.0s
  -- the scan itself costs. Materialising it puts that back to one pass.
  with counted as materialized (
    select
      grouping(pi.title_seniority) as g_seniority,
      grouping(pi.title_department) as g_department,
      grouping(pi.title_sub_department) as g_sub,
      pi.title_seniority, pi.title_department, pi.title_sub_department,
      count(*) as n
    from public.prospect_index pi
    where nullif(btrim(coalesce(p_client_id, '')), '') is null
       or pi.client_ids @> array[p_client_id]
    group by grouping sets ((pi.title_seniority), (pi.title_department), (pi.title_sub_department))
  ),
  tier_counts as (
    select btrim(coalesce(title_seniority, '')) as key, sum(n) as n
    from counted where g_seniority = 0 group by 1
  ),
  department_counts as (
    select btrim(coalesce(title_department, '')) as key, sum(n) as n
    from counted where g_department = 0 group by 1
  ),
  sub_counts as (
    select btrim(coalesce(title_sub_department, '')) as key, sum(n) as n
    from counted where g_sub = 0 group by 1
  ),
  -- 'none' is the suppression tier: it consumes tokens and contributes no rank,
  -- so it is never a value anything carries and must not be offered.
  tiers as (
    select coalesce(jsonb_agg(jsonb_build_object('value', t.tier, 'count', coalesce(c.n, 0)) order by t.tier), '[]'::jsonb) as value
    from (select distinct tier from public.title_seniority_keywords where tier <> 'none') t
    left join tier_counts c on c.key = t.tier
  ),
  subs_by_department as (
    select k.department,
      jsonb_agg(jsonb_build_object('name', k.sub_department, 'count', coalesce(s.n, 0)) order by k.sub_department) as subs
    from (select distinct department, sub_department from public.title_department_keywords where btrim(coalesce(sub_department, '')) <> '') k
    left join sub_counts s on s.key = k.sub_department
    group by k.department
  ),
  departments as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'name', d.department,
      'count', coalesce(c.n, 0),
      'subs', coalesce(sd.subs, '[]'::jsonb)
    ) order by d.department), '[]'::jsonb) as value
    from (select distinct department from public.title_department_keywords) d
    left join department_counts c on c.key = d.department
    left join subs_by_department sd on sd.department = d.department
  )
  select jsonb_build_object(
    'tiers', (select value from tiers),
    'departments', (select value from departments),
    -- What the classifier could not place. Shown as its own row so the picker
    -- can offer it rather than leaving those people unreachable.
    'undefinedSeniority', (select coalesce(n, 0) from tier_counts where key = ''),
    'undefinedDepartment', (select coalesce(n, 0) from department_counts where key = '')
  );
$function$;

comment on function public.prospect_title_taxonomy_v1(text) is
  'Classifier tiers, departments and sub-departments with prospect counts, for the Job Title & Seniority filter pickers.';

revoke execute on function public.prospect_title_taxonomy_v1(text) from public, anon, authenticated;
grant execute on function public.prospect_title_taxonomy_v1(text) to service_role;

-- The picker is only worth having if it offers the whole taxonomy.
do $$
declare
  v jsonb := public.prospect_title_taxonomy_v1(null);
  v_departments integer := jsonb_array_length(v->'departments');
  v_tiers integer := jsonb_array_length(v->'tiers');
  v_subs integer;
begin
  select sum(jsonb_array_length(d->'subs')) into v_subs
  from jsonb_array_elements(v->'departments') d;

  if v_departments <> (select count(distinct department) from public.title_department_keywords) then
    raise exception 'taxonomy returned % departments, keywords define %',
      v_departments, (select count(distinct department) from public.title_department_keywords);
  end if;
  if v_subs <> (select count(*) from (select distinct department, sub_department from public.title_department_keywords where btrim(coalesce(sub_department,'')) <> '') s) then
    raise exception 'taxonomy returned % sub-departments, keywords define %',
      v_subs, (select count(*) from (select distinct department, sub_department from public.title_department_keywords where btrim(coalesce(sub_department,'')) <> '') s);
  end if;
  if v_tiers <> (select count(distinct tier) from public.title_seniority_keywords where tier <> 'none') then
    raise exception 'taxonomy returned % tiers', v_tiers;
  end if;
end;
$$;

commit;
