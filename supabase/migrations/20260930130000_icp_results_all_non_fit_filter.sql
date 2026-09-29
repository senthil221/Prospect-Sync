-- ICP Validator results: an "All NON_FIT" filter.
--
-- The results filter was All / Disagreements / Any NON_FIT / All FIT. The
-- operator wants the two agreements side by side - every chosen model says
-- FIT, or every chosen model says NON_FIT - plus the disagreements. This adds
-- p_filter = 'all_non_fit' (bool_and over the chosen sources, like 'fit').
-- 'non_fit' (any) is kept so an older page still works. Read-only.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.icp_verdict_rows_v1(
  p_client_id text,
  p_icp_profile_id text,
  p_sources text[],
  p_filter text default 'all',
  p_search text default '',
  p_limit integer default 100,
  p_offset integer default 0,
  p_verdict_source text default '',
  p_verdict text default ''
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '20s'
as $$
declare
  v_hash text;
  v_search text := btrim(coalesce(p_search, ''));
  v_result jsonb;
begin
  select md5(description) into v_hash from public.client_icp_profiles
   where id = p_icp_profile_id and client_id = p_client_id;
  if v_hash is null then
    raise exception using errcode = 'P0002', message = 'That ICP does not belong to this client.';
  end if;

  with grouped as (
    select v.company_id,
           jsonb_object_agg(v.source, jsonb_build_object(
             'verdict', v.verdict, 'reason', v.reason,
             'current', v.source like 'reference:%' or v.icp_hash = v_hash)) as verdicts,
           count(distinct v.verdict) as kinds,
           bool_or(v.verdict = 'NON_FIT') as any_non_fit,
           bool_and(v.verdict = 'FIT') as all_fit,
           bool_and(v.verdict = 'NON_FIT') as all_non_fit,
           bool_or(v.source = p_verdict_source and v.verdict = p_verdict) as verdict_match
      from public.client_company_icp_verdicts v
     where v.client_id = p_client_id and v.icp_profile_id = p_icp_profile_id
       and v.source = any(coalesce(p_sources, array[]::text[]))
     group by v.company_id
  ),
  filtered as (
    select g.*, c.name, c.domain, c.industry, c.short_description, c.keywords
      from grouped g
      join public.companies c on c.id = g.company_id
     where (coalesce(p_filter, 'all') = 'all'
            or (p_filter = 'disagree' and g.kinds > 1)
            or (p_filter = 'non_fit' and g.any_non_fit)
            or (p_filter = 'fit' and g.all_fit)
            or (p_filter = 'all_non_fit' and g.all_non_fit))
       and (coalesce(p_verdict_source, '') = '' or g.verdict_match)
       and (v_search = '' or c.name ilike '%' || v_search || '%' or c.domain ilike '%' || v_search || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'company_id', f.company_id, 'name', f.name, 'domain', f.domain, 'industry', f.industry,
               'short_description', left(f.short_description, 1200),
               'keywords', left(array_to_string(f.keywords, ', '), 600),
               'verdicts', f.verdicts) order by f.kinds > 1 desc, lower(f.name), f.company_id)
        from (select * from filtered
               order by kinds > 1 desc, lower(name), company_id
               limit greatest(1, least(coalesce(p_limit, 100), 1000))
               offset greatest(0, coalesce(p_offset, 0))) f), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;


revoke execute on function public.icp_verdict_rows_v1(text, text, text[], text, text, integer, integer, text, text) from public, anon, authenticated;
grant execute on function public.icp_verdict_rows_v1(text, text, text[], text, text, integer, integer, text, text) to service_role;
