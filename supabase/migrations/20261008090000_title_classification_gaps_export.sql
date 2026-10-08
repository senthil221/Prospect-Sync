-- Export every undefined job title, not just the top 2,000.
--
-- The Job titles tab lists the 200 biggest titles the keyword lists could not
-- resolve (title_classification_gaps_v1, capped at 2,000). On 2026-10-08 there
-- were 84,252 distinct ones covering 446,721 people, and the user wants the
-- whole list as a CSV to send back new classifications.
--
-- One jsonb array rather than a set of rows, so PostgREST's row cap cannot cut
-- the file short; one aggregate over prospects (about 1.6s live). Each row also
-- carries the side that did resolve (a "Director" has seniority Director and no
-- department), so the file shows exactly what is missing.
-- ---------------------------------------------------------------------------

create or replace function public.title_classification_gaps_export_v1(p_missing text default 'any')
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '120s'
as $$
  select coalesce(jsonb_agg(jsonb_build_array(g.sample_title, g.normalized_title, g.occurrences,
                                              g.seniority, g.department, g.missing_seniority, g.missing_department)
                            order by g.occurrences desc, g.normalized_title), '[]'::jsonb)
    from (
      select p.title_normalized as normalized_title,
             min(p.title) as sample_title,
             count(*) as occurrences,
             coalesce(max(nullif(p.title_seniority, '')), '') as seniority,
             coalesce(max(nullif(p.title_department, '')), '') as department,
             bool_and(p.title_seniority = '') as missing_seniority,
             bool_and(p.title_department = '') as missing_department
        from public.prospects p
       where btrim(coalesce(p.title, '')) <> ''
         and (p.title_seniority = '' or p.title_department = '')
         and (
           p_missing = 'any'
           or (p_missing = 'both' and p.title_seniority = '' and p.title_department = '')
           or (p_missing = 'seniority' and p.title_seniority = '')
           or (p_missing = 'department' and p.title_department = '')
         )
       group by p.title_normalized
    ) g;
$$;

revoke execute on function public.title_classification_gaps_export_v1(text) from public, anon, authenticated;
grant execute on function public.title_classification_gaps_export_v1(text) to service_role;
