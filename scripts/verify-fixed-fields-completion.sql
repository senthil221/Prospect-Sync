-- Aggregate-only, read-only audit after cleanup and title backfill finish.
begin read only;
set local statement_timeout='120s';
select count(*) as people,
  count(*) filter(where concat(personal_email,seniority,department,city,state,country,location)<>''
    or coalesce(cardinality(keywords),0)>0) as retired_profile_values,
  count(*) filter(where all_data-array['First Name','Last Name','Job Title','Email','Mobile Number',
    'Personal LinkedIn URL','Company Name','Website','_enriched_from','_enriched_at']<>'{}'::jsonb) as extra_people_payloads,
  count(*) filter(where title_classified_at is null or title_classified_at<
    (select keywords_updated_at from public.title_classifier_state where id)) as stale_titles
from public.prospects;
select count(*) as indexed_people,
  count(*) filter(where concat(personal_email,seniority,department,city,state,country,location)<>''
    or coalesce(cardinality(keywords),0)>0) as retired_index_values,
  count(*) filter(where all_data-array['First Name','Last Name','Job Title','Email','Mobile Number',
    'Personal LinkedIn URL','Company Name','Website','_enriched_from','_enriched_at']<>'{}'::jsonb) as extra_index_payloads
from public.prospect_index;
select count(*) as classifier_projection_mismatches from public.prospects p
left join public.prospect_index pi using(id)
where pi.id is null or (p.title_seniority,p.title_department,p.title_sub_department,p.title_is_former,p.title_normalized)
  is distinct from (pi.title_seniority,pi.title_department,pi.title_sub_department,pi.title_is_former,pi.title_normalized);
select count(*) as companies,
  count(*) filter(where all_data-array['Company Name','Website','Industry','Keywords','Short Description',
    'Founded Year','#employees','Company City','Company State','Company Country','Technologies','Total Funding']<>'{}'::jsonb) as extra_company_payloads
from public.companies;
select count(*) as list_rows,
  count(*) filter(where raw_data-array['First Name','Last Name','Job Title','Email','Mobile Number',
    'Personal LinkedIn URL','Company Name','Website','_enriched_from','_enriched_at']<>'{}'::jsonb) as extra_source_payloads
from public.list_rows;
select count(*) as personal_email_identifiers from public.prospect_identifiers where type='personal_email';
select count(*) as client_links,count(*) filter(where date_added is not null) as dated_client_links from public.client_prospects;
select count(*) as contact_events from public.contact_events;
select count(*) as catalogue_fields,count(*) filter(where field_name not in
  ('First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website')) as extra_catalogue_fields
from public.prospect_fields;
do $assert$
begin
  if exists(select 1 from public.prospects where
      concat(personal_email,seniority,department,city,state,country,location)<>'' or coalesce(cardinality(keywords),0)>0
      or all_data-array['First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website','_enriched_from','_enriched_at']<>'{}'::jsonb
      or title_classified_at is null or title_classified_at<(select keywords_updated_at from public.title_classifier_state where id))
    or exists(select 1 from public.prospect_index where
      concat(personal_email,seniority,department,city,state,country,location)<>'' or coalesce(cardinality(keywords),0)>0
      or all_data-array['First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website','_enriched_from','_enriched_at']<>'{}'::jsonb)
    or exists(select 1 from public.companies where all_data-array['Company Name','Website','Industry','Keywords','Short Description','Founded Year','#employees','Company City','Company State','Company Country','Technologies','Total Funding']<>'{}'::jsonb)
    or exists(select 1 from public.list_rows where raw_data-array['First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website','_enriched_from','_enriched_at']<>'{}'::jsonb)
    or exists(select 1 from public.prospect_identifiers where type='personal_email')
    or exists(select 1 from public.prospect_fields where field_name not in ('First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website'))
    or exists(select 1 from public.prospects p left join public.prospect_index pi using(id) where pi.id is null
      or (p.title_seniority,p.title_department,p.title_sub_department,p.title_is_former,p.title_normalized)
        is distinct from (pi.title_seniority,pi.title_department,pi.title_sub_department,pi.title_is_former,pi.title_normalized)) then
    raise exception 'Fixed-field maintenance is incomplete; review the aggregate counts above';
  end if;
end;
$assert$;
commit;
