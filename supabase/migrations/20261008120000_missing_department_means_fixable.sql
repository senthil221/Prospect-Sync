-- "Missing department" on the Job titles tab lists only titles a department
-- keyword could fix; Education and Healthcare join the 18 departments.
--
-- On 2026-10-08, 425,703 people with a job title had no department:
--   173,372 top management (20261008110000) - founder, director, MD, CEO;
--   147,592 whose title is only a rank - manager, assistant manager, VP, AVP,
--           AGM, associate director, branch manager, business head;
--     4,100 whose "title" is not one - pvt ltd, company, contact, info, Mr;
--   104,289 whose title names a function the department list does not know.
-- No keyword can give the first three groups a department, because their
-- titles do not contain one, and they buried the fourth. Asked for the same day:
-- the gap list counts only the fourth group as missing a department. Nobody's
-- department changes - it stays blank, and the Departments filter is untouched.
--
-- title_needs_department_v1(normalized title) is false for a blank title, a
-- known non-title, and a title made only of rank words (the list below - pure
-- rank and scope words, not the seniority keyword list, which also holds
-- function words like "sales" and "procurement"). Top management is excluded
-- by the flag. Both gap readers (the tab and Export all) use it, per title.
--
-- EDUCATION AND HEALTHCARE. Professors, teachers, lecturers, doctors, nurses
-- fit none of the 18 corporate departments (about 9,400 people). The keyword
-- upload accepts the two new departments; the keywords themselves are the
-- user's to upload from the Job titles tab.
-- ---------------------------------------------------------------------------

create or replace function public.title_needs_department_v1(p_normalized_title text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case
    when btrim(coalesce(p_normalized_title, '')) = '' then false
    when p_normalized_title in ('company', 'pvt ltd', 'private limited', 'llp', 'ltd', 'limited', 'pvt', 'contact',
                                'contact person', 'general contact', 'general inquiries', 'info', 'mr', 'mrs', 'ms',
                                'na', 'n a', 'none', 'nil', 'self', 'self employed', 'student', 'hotel', 'school',
                                'office', 'proprietorship', 'test', 'other', 'others', 'team', 'sir', 'madam') then false
    else exists (
      select 1 from unnest(string_to_array(p_normalized_title, ' ')) as word(value)
       where word.value not in (
         'manager', 'mgr', 'mngr', 'manger', 'management', 'assistant', 'asst', 'asstt', 'associate', 'deputy', 'dy',
         'joint', 'jt', 'senior', 'sr', 'junior', 'jr', 'chief', 'head', 'hod', 'lead', 'leader', 'team', 'tl',
         'vice', 'president', 'vp', 'avp', 'svp', 'evp', 'dvp', 'director', 'dir', 'directors', 'general', 'gm',
         'agm', 'dgm', 'cgm', 'sgm', 'jgm', 'executive', 'exec', 'officer', 'principal', 'member', 'board', 'non',
         'independent', 'partner', 'business', 'consultant', 'specialist', 'area', 'regional', 'region', 'zonal',
         'zone', 'national', 'branch', 'cluster', 'territory', 'district', 'state', 'country', 'global', 'group',
         'division', 'divisional', 'vertical', 'circle', 'city', 'unit', 'incharge', 'in', 'charge', 'supervisor',
         'superintendent', 'coordinator', 'co', 'ordinator', 'trainee', 'intern', 'fresher', 'staff', 'additional',
         'addl', 'first', 'of', 'and', 'the', 'to', 'a', 'at', 'for', 'i', 'ii', 'iii', 'iv', '1', '2', '3')
    )
  end;
$$;

revoke execute on function public.title_needs_department_v1(text) from public, anon, authenticated;
grant execute on function public.title_needs_department_v1(text) to service_role;

create or replace function public.title_classification_gaps_v1(p_limit integer default 200, p_missing text default 'any')
returns table(normalized_title text, sample_title text, occurrences bigint, missing_seniority boolean, missing_department boolean)
language sql
stable
security definer
set search_path = public
set statement_timeout = '60s'
as $$
  with candidate as (
    select p.title_normalized, p.title, p.title_seniority = '' as no_seniority,
           p.title_department = '' and not p.title_top_management as no_department
      from public.prospects p
     where btrim(coalesce(p.title, '')) <> ''
       and (p.title_seniority = '' or (p.title_department = '' and not p.title_top_management))
  ),
  needs as (
    select t.title_normalized, public.title_needs_department_v1(t.title_normalized) as needs_department
      from (select distinct coalesce(title_normalized, '') as title_normalized from candidate) t
  ),
  gap as (
    select c.title_normalized, c.title, c.no_seniority, c.no_department and n.needs_department as no_department
      from candidate c join needs n on n.title_normalized = coalesce(c.title_normalized, '')
  )
  select g.title_normalized,
    min(g.title) as sample_title,
    count(*) as occurrences,
    bool_and(g.no_seniority) as missing_seniority,
    bool_and(g.no_department) as missing_department
  from gap g
  where (g.no_seniority or g.no_department)
    and (p_missing = 'any'
      or (p_missing = 'both' and g.no_seniority and g.no_department)
      or (p_missing = 'seniority' and g.no_seniority)
      or (p_missing = 'department' and g.no_department))
  group by g.title_normalized
  order by count(*) desc, g.title_normalized
  limit greatest(1, least(coalesce(p_limit, 200), 2000));
$$;

revoke execute on function public.title_classification_gaps_v1(integer, text) from public, anon, authenticated;
grant execute on function public.title_classification_gaps_v1(integer, text) to service_role;

create or replace function public.title_classification_gaps_export_v1(p_missing text default 'any')
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '120s'
as $$
  with candidate as (
    select p.title_normalized, p.title, p.title_seniority, p.title_department, p.title_seniority = '' as no_seniority,
           p.title_department = '' and not p.title_top_management as no_department
      from public.prospects p
     where btrim(coalesce(p.title, '')) <> ''
       and (p.title_seniority = '' or (p.title_department = '' and not p.title_top_management))
  ),
  needs as (
    select t.title_normalized, public.title_needs_department_v1(t.title_normalized) as needs_department
      from (select distinct coalesce(title_normalized, '') as title_normalized from candidate) t
  ),
  gap as (
    select c.title_normalized, c.title, c.title_seniority, c.title_department, c.no_seniority,
           c.no_department and n.needs_department as no_department
      from candidate c join needs n on n.title_normalized = coalesce(c.title_normalized, '')
  )
  select coalesce(jsonb_agg(jsonb_build_array(g.sample_title, g.normalized_title, g.occurrences,
                                              g.seniority, g.department, g.missing_seniority, g.missing_department)
                            order by g.occurrences desc, g.normalized_title), '[]'::jsonb)
    from (
      select x.title_normalized as normalized_title,
             min(x.title) as sample_title,
             count(*) as occurrences,
             coalesce(max(nullif(x.title_seniority, '')), '') as seniority,
             coalesce(max(nullif(x.title_department, '')), '') as department,
             bool_and(x.no_seniority) as missing_seniority,
             bool_and(x.no_department) as missing_department
        from gap x
       where (x.no_seniority or x.no_department)
         and (p_missing = 'any'
           or (p_missing = 'both' and x.no_seniority and x.no_department)
           or (p_missing = 'seniority' and x.no_seniority)
           or (p_missing = 'department' and x.no_department))
       group by x.title_normalized
    ) g;
$$;

revoke execute on function public.title_classification_gaps_export_v1(text) from public, anon, authenticated;
grant execute on function public.title_classification_gaps_export_v1(text) to service_role;

-- The keyword upload accepts Education and Healthcare. Otherwise as in
-- 20261008110000.
do $patch$
declare
  v_definition text;
  v_anchor text := $old$'Manufacturing', 'Quality', 'Support', 'Admin', 'Strategy', 'R&D')$old$;
begin
  select pg_get_functiondef('public.apply_title_keywords_v1(text,jsonb,boolean)'::regprocedure) into v_definition;
  if position('''Education''' in v_definition) = 0 then
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'apply_title_keywords_v1: department list anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$'Manufacturing', 'Quality', 'Support', 'Admin', 'Strategy', 'R&D', 'Education', 'Healthcare')$new$);
  end if;
end;
$patch$;

revoke execute on function public.apply_title_keywords_v1(text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.apply_title_keywords_v1(text, jsonb, boolean) to service_role;

-- Proof, read-only.
do $proof$
declare
  v_result jsonb;
begin
  if public.title_needs_department_v1('assistant manager') or public.title_needs_department_v1('vice president')
     or public.title_needs_department_v1('pvt ltd') or public.title_needs_department_v1('')
     or not public.title_needs_department_v1('relationship manager')
     or not public.title_needs_department_v1('chief operating officer')
     or not public.title_needs_department_v1('assistant professor') then
    raise exception 'Missing department proof: title_needs_department_v1 is off';
  end if;
  if exists (select 1 from public.title_classification_gaps_v1(2000, 'department') g
              where g.normalized_title in ('director', 'founder', 'co founder', 'assistant manager', 'manager', 'vice president')) then
    raise exception 'Missing department proof: a top management or rank-only title is still listed';
  end if;
  v_result := public.apply_title_keywords_v1('department',
    jsonb_build_array(jsonb_build_object('keyword', 'zzproof professor', 'department', 'Education'),
                      jsonb_build_object('keyword', 'zzproof doctor', 'department', 'Healthcare')), true);
  if jsonb_array_length(v_result->'added') <> 2 or jsonb_array_length(v_result->'problems') <> 0 then
    raise exception 'Missing department proof: Education/Healthcare not accepted: %', v_result;
  end if;
  raise notice 'Missing department proof passed.';
end;
$proof$;
