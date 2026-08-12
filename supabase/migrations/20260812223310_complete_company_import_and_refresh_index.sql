-- Complete a company import and immediately synchronize the company-derived
-- fields used by the People DB filters. This avoids stale employee/location
-- values without rebuilding unrelated prospect/list aggregates.
create or replace function public.complete_company_import_v1(p_import_id text)
returns table(
  processed_rows integer,
  added_count integer,
  updated_count integer,
  skipped_count integer,
  indexed_rows integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  result_processed integer;
  result_added integer;
  result_updated integer;
  result_skipped integer;
  result_indexed integer;
begin
  update public.company_imports ci
  set status = 'completed', completed_at = coalesce(ci.completed_at, now())
  where ci.id = p_import_id
  returning ci.processed_rows, ci.added_count, ci.updated_count, ci.skipped_count
  into result_processed, result_added, result_updated, result_skipped;

  if not found then
    raise exception 'Company import not found' using errcode = 'P0002';
  end if;

  with refreshed as (
    update public.prospect_index pi
    set
      company_name = coalesce(c.name, ''),
      company_domain = coalesce(c.domain, ''),
      employee_count_min = c.employee_count_min,
      employee_count_max = c.employee_count_max,
      company_location = coalesce(c.location, ''),
      company_city = coalesce(c.city, ''),
      company_state = coalesce(c.state, ''),
      company_country = coalesce(c.country, ''),
      search_text = concat_ws(' ',
        pi.full_name, pi.work_email, pi.personal_email, pi.title,
        array_to_string(pi.keywords, ' '), coalesce(c.name, ''),
        coalesce(c.domain, ''), pi.linkedin_url, pi.city, pi.state, pi.country,
        coalesce(c.location, ''), coalesce(c.city, ''), coalesce(c.state, ''),
        coalesce(c.country, ''), pi.all_data::text, pi.esp,
        pi.email_provider_type, array_to_string(pi.mx_records, ' '),
        array_to_string(pi.list_names, ' '), array_to_string(pi.client_names, ' '),
        pi.tag_text
      )
    from public.companies c
    where pi.company_id = c.id
      and exists (
        select 1
        from public.company_import_rows cir
        where cir.import_id = p_import_id and cir.company_id = c.id
      )
    returning 1
  )
  select count(*)::integer into result_indexed from refreshed;

  return query select result_processed, result_added, result_updated,
    result_skipped, result_indexed;
end;
$$;

revoke execute on function public.complete_company_import_v1(text)
from public, anon, authenticated;
grant execute on function public.complete_company_import_v1(text) to service_role;
