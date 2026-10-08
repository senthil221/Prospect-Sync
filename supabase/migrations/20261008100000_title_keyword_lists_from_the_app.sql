-- The job title keyword lists can be downloaded, extended and uploaded from the
-- Job titles tab.
--
-- Until now the lists lived in data/seniority_map.csv and data/department_map.csv
-- and only scripts/sync-title-keywords.mjs (service-role key, a developer's
-- machine) could load them. Asked for on 2026-10-08: the user wants to download
-- them, add keywords for the undefined titles, upload, and re-run the classifier
-- themselves. From here the tables are the source of truth; the files are a
-- snapshot.
--
-- title_keywords_export_v1(kind)  every keyword of one list, longest first.
-- apply_title_keywords_v1(kind, rows, dry_run)
--   Validates an uploaded list the way the sync script does - the keyword is
--   normalized with normalize_job_title_v1 (the classifier's own normalizer, so
--   a keyword can always match), the tier or department must be one the
--   classifier knows, at most 8 words, no duplicates - and reports what would be
--   added and changed. With dry_run false it writes the valid rows. It only adds
--   and updates: a keyword missing from the upload is kept, so uploading a short
--   list of new words is safe. Each write bumps keywords_updated_at (the
--   existing statement trigger), which is what lets Re-run classifier find the
--   prospects to redo.
-- ---------------------------------------------------------------------------

create or replace function public.title_keywords_export_v1(p_kind text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case p_kind
    when 'seniority' then (
      select coalesce(jsonb_agg(jsonb_build_object('keyword', k.keyword, 'tier', k.tier, 'notes', k.notes)
                                order by k.token_count desc, k.keyword), '[]'::jsonb)
        from public.title_seniority_keywords k)
    when 'department' then (
      select coalesce(jsonb_agg(jsonb_build_object('keyword', k.keyword, 'department', k.department,
                                                   'sub_department', k.sub_department, 'notes', k.notes)
                                order by k.token_count desc, k.keyword), '[]'::jsonb)
        from public.title_department_keywords k)
  end;
$$;

revoke execute on function public.title_keywords_export_v1(text) from public, anon, authenticated;
grant execute on function public.title_keywords_export_v1(text) to service_role;

create or replace function public.apply_title_keywords_v1(p_kind text, p_rows jsonb, p_dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
set client_min_messages = 'warning'
as $$
declare
  v_problems jsonb;
  v_added jsonb;
  v_changed jsonb;
  v_unchanged integer;
begin
  if p_kind not in ('seniority', 'department') then
    raise exception 'Choose the seniority or the department list.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'The upload has no rows.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 20000 then
    raise exception 'A keyword list holds at most 20,000 rows.' using errcode = '22023';
  end if;

  create temp table if not exists pg_temp.title_keyword_upload (
    line integer, raw_keyword text, keyword text, value text, sub_department text, notes text, problem text
  ) on commit drop;
  truncate pg_temp.title_keyword_upload;

  insert into pg_temp.title_keyword_upload (line, raw_keyword, keyword, value, sub_department, notes)
  select coalesce(nullif(r.value->>'line', '')::integer, r.ordinality::integer),
         btrim(coalesce(r.value->>'keyword', '')),
         public.normalize_job_title_v1(coalesce(r.value->>'keyword', '')),
         btrim(coalesce(r.value->>case when p_kind = 'seniority' then 'tier' else 'department' end, '')),
         btrim(coalesce(r.value->>'sub_department', '')),
         btrim(coalesce(r.value->>'notes', ''))
    from jsonb_array_elements(p_rows) with ordinality r;

  update pg_temp.title_keyword_upload u
     set problem = case
       when u.keyword = '' then format('keyword "%s" is empty once normalized', u.raw_keyword)
       when array_length(string_to_array(u.keyword, ' '), 1) > 8 then format('"%s" is longer than 8 words and can never match', u.keyword)
       when p_kind = 'seniority' and u.value not in ('owner', 'c_suite', 'vp', 'director', 'manager', 'senior_ic', 'entry', 'none')
         then format('unknown tier "%s"', u.value)
       when p_kind = 'department' and u.value not in ('Sales', 'Marketing', 'Engineering', 'IT', 'Product', 'Design',
                                                      'Data & Analytics', 'HR', 'Finance', 'Legal', 'Operations', 'Supply Chain',
                                                      'Manufacturing', 'Quality', 'Support', 'Admin', 'Strategy', 'R&D')
         then format('unknown department "%s"', u.value)
     end;
  -- A keyword listed twice: the first row wins, the later ones are reported.
  update pg_temp.title_keyword_upload u
     set problem = format('duplicate keyword "%s" (first on row %s)', u.keyword, d.first_line)
    from (select keyword, min(line) as first_line from pg_temp.title_keyword_upload where problem is null group by keyword) d
   where u.problem is null and u.keyword = d.keyword and u.line <> d.first_line;

  select coalesce(jsonb_agg(jsonb_build_object('line', line, 'problem', problem) order by line), '[]'::jsonb)
    into v_problems from pg_temp.title_keyword_upload where problem is not null;

  if p_kind = 'seniority' then
    select coalesce(jsonb_agg(jsonb_build_object('keyword', u.keyword, 'value', u.value) order by u.line), '[]'::jsonb) into v_added
      from pg_temp.title_keyword_upload u
     where u.problem is null and not exists (select 1 from public.title_seniority_keywords k where k.keyword = u.keyword);
    select coalesce(jsonb_agg(jsonb_build_object('keyword', u.keyword, 'value', u.value, 'was', k.tier) order by u.line), '[]'::jsonb) into v_changed
      from pg_temp.title_keyword_upload u join public.title_seniority_keywords k on k.keyword = u.keyword
     where u.problem is null and (k.tier, k.notes) is distinct from (u.value, u.notes);
    select count(*) into v_unchanged
      from pg_temp.title_keyword_upload u join public.title_seniority_keywords k on k.keyword = u.keyword
     where u.problem is null and (k.tier, k.notes) = (u.value, u.notes);
    if not p_dry_run and (jsonb_array_length(v_added) > 0 or jsonb_array_length(v_changed) > 0) then
      insert into public.title_seniority_keywords (keyword, tier, notes)
      select u.keyword, u.value, u.notes from pg_temp.title_keyword_upload u where u.problem is null
      on conflict (keyword) do update set tier = excluded.tier, notes = excluded.notes
       where (title_seniority_keywords.tier, title_seniority_keywords.notes) is distinct from (excluded.tier, excluded.notes);
    end if;
  else
    select coalesce(jsonb_agg(jsonb_build_object('keyword', u.keyword, 'value', u.value) order by u.line), '[]'::jsonb) into v_added
      from pg_temp.title_keyword_upload u
     where u.problem is null and not exists (select 1 from public.title_department_keywords k where k.keyword = u.keyword);
    select coalesce(jsonb_agg(jsonb_build_object('keyword', u.keyword, 'value', u.value, 'was', k.department) order by u.line), '[]'::jsonb) into v_changed
      from pg_temp.title_keyword_upload u join public.title_department_keywords k on k.keyword = u.keyword
     where u.problem is null and (k.department, k.sub_department, k.notes) is distinct from (u.value, u.sub_department, u.notes);
    select count(*) into v_unchanged
      from pg_temp.title_keyword_upload u join public.title_department_keywords k on k.keyword = u.keyword
     where u.problem is null and (k.department, k.sub_department, k.notes) = (u.value, u.sub_department, u.notes);
    if not p_dry_run and (jsonb_array_length(v_added) > 0 or jsonb_array_length(v_changed) > 0) then
      insert into public.title_department_keywords (keyword, department, sub_department, notes)
      select u.keyword, u.value, u.sub_department, u.notes from pg_temp.title_keyword_upload u where u.problem is null
      on conflict (keyword) do update set department = excluded.department, sub_department = excluded.sub_department, notes = excluded.notes
       where (title_department_keywords.department, title_department_keywords.sub_department, title_department_keywords.notes)
             is distinct from (excluded.department, excluded.sub_department, excluded.notes);
    end if;
  end if;

  return jsonb_build_object('kind', p_kind, 'applied', not p_dry_run,
    'added', v_added, 'changed', v_changed, 'unchanged', v_unchanged, 'problems', v_problems);
end;
$$;

revoke execute on function public.apply_title_keywords_v1(text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.apply_title_keywords_v1(text, jsonb, boolean) to service_role;

-- Proof, rolled back with the rest of a dry run and harmless live: a dry run of
-- the current seniority list changes nothing, and bad rows are reported.
do $proof$
declare
  v_result jsonb;
begin
  v_result := public.apply_title_keywords_v1('seniority', public.title_keywords_export_v1('seniority'), true);
  if jsonb_array_length(v_result->'added') <> 0 or jsonb_array_length(v_result->'changed') <> 0 or jsonb_array_length(v_result->'problems') <> 0 then
    raise exception 'Title keyword proof: re-uploading the seniority list is not a no-op: %', v_result;
  end if;
  v_result := public.apply_title_keywords_v1('department', public.title_keywords_export_v1('department'), true);
  if jsonb_array_length(v_result->'added') <> 0 or jsonb_array_length(v_result->'changed') <> 0 or jsonb_array_length(v_result->'problems') <> 0 then
    raise exception 'Title keyword proof: re-uploading the department list is not a no-op: %', v_result;
  end if;
  v_result := public.apply_title_keywords_v1('seniority', jsonb_build_array(
    jsonb_build_object('keyword', 'Zzproof Keyword', 'tier', 'manager'),
    jsonb_build_object('keyword', 'zzproof keyword', 'tier', 'director'),
    jsonb_build_object('keyword', '!!!', 'tier', 'manager'),
    jsonb_build_object('keyword', 'zzproof other', 'tier', 'boss')), true);
  if jsonb_array_length(v_result->'added') <> 1 or v_result->'added'->0->>'keyword' <> 'zzproof keyword'
     or jsonb_array_length(v_result->'problems') <> 3 then
    raise exception 'Title keyword proof: validation is off: %', v_result;
  end if;
  raise notice 'Title keyword proof passed.';
end;
$proof$;
