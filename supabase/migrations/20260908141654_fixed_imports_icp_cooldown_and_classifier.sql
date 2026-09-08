-- Fixed import contracts, client ICP predicates, and resumable maintenance.
-- No existing payload is changed by this migration. Sanitization is an
-- explicit, keyset-checkpointed service-role operation whose default is dry-run.

begin;

create or replace function public.fixed_import_key_v1(p_entity text, p_key text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $function$
  select case
    -- Enrichment bookkeeping shares prospects.all_data with source payloads;
    -- it is system metadata, not an import column, and must survive cleanup.
    when lower(coalesce(p_entity, '')) = 'prospect'
      and p_key in ('_enriched_from', '_enriched_at') then p_key
    else case lower(coalesce(p_entity, ''))
    when 'prospect' then case regexp_replace(lower(coalesce(p_key, '')), '[^a-z0-9]+', '', 'g')
      when 'firstname' then 'First Name' when 'lastname' then 'Last Name'
      when 'jobtitle' then 'Job Title' when 'title' then 'Job Title'
      when 'email' then 'Email' when 'emailaddress' then 'Email' when 'workemail' then 'Email' when 'businessemail' then 'Email'
      when 'mobile' then 'Mobile Number' when 'mobilenumber' then 'Mobile Number' when 'phone' then 'Mobile Number' when 'phonenumber' then 'Mobile Number'
      when 'linkedin' then 'Personal LinkedIn URL' when 'linkedinurl' then 'Personal LinkedIn URL' when 'linkedinprofile' then 'Personal LinkedIn URL'
      when 'personlinkedinurl' then 'Personal LinkedIn URL' when 'personallinkedinurl' then 'Personal LinkedIn URL'
      when 'company' then 'Company Name' when 'companyname' then 'Company Name' when 'organization' then 'Company Name' when 'casualcompanyname' then 'Company Name'
      when 'website' then 'Website' when 'companywebsite' then 'Website' when 'domain' then 'Website' when 'companydomain' then 'Website'
      else null end
    when 'company' then case regexp_replace(lower(coalesce(p_key, '')), '[^a-z0-9]+', '', 'g')
      when 'company' then 'Company Name' when 'companyname' then 'Company Name' when 'name' then 'Company Name' when 'organization' then 'Company Name' when 'accountname' then 'Company Name'
      when 'website' then 'Website' when 'domain' then 'Website' when 'companywebsite' then 'Website' when 'companydomain' then 'Website' when 'url' then 'Website'
      when 'industry' then 'Industry' when 'companyindustry' then 'Industry'
      when 'keyword' then 'Keywords' when 'keywords' then 'Keywords' when 'companykeywords' then 'Keywords'
      when 'shortdescription' then 'Short Description' when 'description' then 'Short Description' when 'companydescription' then 'Short Description'
      when 'foundedyear' then 'Founded Year' when 'founded' then 'Founded Year' when 'yearfounded' then 'Founded Year'
      when 'employees' then '#employees' when 'employeecount' then '#employees' when 'employeescount' then '#employees' when 'numberofemployees' then '#employees' when 'headcount' then '#employees' when 'companyemployeecount' then '#employees' when 'companyemployees' then '#employees'
      when 'companycity' then 'Company City' when 'city' then 'Company City' when 'accountcity' then 'Company City' when 'hqcity' then 'Company City'
      when 'companystate' then 'Company State' when 'state' then 'Company State' when 'accountstate' then 'Company State' when 'hqstate' then 'Company State' when 'companyregion' then 'Company State'
      when 'companycountry' then 'Company Country' when 'country' then 'Company Country' when 'accountcountry' then 'Company Country' when 'hqcountry' then 'Company Country'
      when 'technology' then 'Technologies' when 'technologies' then 'Technologies' when 'techstack' then 'Technologies'
      when 'totalfunding' then 'Total Funding' when 'funding' then 'Total Funding' when 'totalfundingamount' then 'Total Funding'
      else null end
    else null end
  end;
$function$;

create or replace function public.fixed_import_json_v1(p_entity text, p_value jsonb)
returns jsonb
language sql
immutable
security invoker
set search_path = ''
as $function$
  select coalesce(jsonb_object_agg(mapped_key, value order by mapped_key), '{}'::jsonb)
  from (
    select distinct on (mapped_key) mapped_key, value
    from (
      select public.fixed_import_key_v1(p_entity, entry.key) as mapped_key,
        entry.key as source_key, entry.value
      from jsonb_each(case when jsonb_typeof(p_value) = 'object' then p_value else '{}'::jsonb end) entry
    ) candidates
    where mapped_key is not null
    -- Prefer an already-canonical key over an alias when both were retained in
    -- an old payload; otherwise choose deterministically.
    order by mapped_key, (value is not null and value <> 'null'::jsonb and value <> '""'::jsonb) desc,
      (source_key = mapped_key) desc, source_key
  ) mapped;
$function$;

create or replace function public.sanitize_import_payloads_v1(
  p_entity text,
  p_after_id text default null,
  p_limit integer default 1000,
  p_apply boolean default false
)
returns table(scanned integer, candidates integer, updated integer, next_after_id text, remaining boolean)
language plpgsql
security definer
set search_path = ''
set statement_timeout = '30s'
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 1000), 5000));
begin
  if p_entity not in ('prospect', 'company', 'list_row', 'membership', 'catalog') then
    raise exception 'entity must be prospect, company, list_row, membership, or catalog' using errcode = '22023';
  end if;

  if p_entity = 'catalog' then
    with batch as materialized (
      select pf.field_name
      from public.prospect_fields pf
      where pf.field_name > coalesce(p_after_id, '')
      order by pf.field_name limit v_limit
    ), changed as (
      select field_name from batch
      where public.fixed_import_key_v1('prospect', field_name) is null
    ), applied as (
      delete from public.prospect_fields pf using changed
      where p_apply and pf.field_name = changed.field_name returning pf.field_name
    ) select count(*)::integer,
        count(*) filter (where public.fixed_import_key_v1('prospect', field_name) is null)::integer,
        (select count(*)::integer from applied), max(field_name)
      into scanned, candidates, updated, next_after_id from batch;
    remaining := next_after_id is not null and exists (
      select 1 from public.prospect_fields pf where pf.field_name > next_after_id
    );
    return next; return;
  end if;

  if p_entity = 'prospect' then
    with batch as materialized (
      select p.id, p.all_data, public.fixed_import_json_v1('prospect', p.all_data) as sanitized
      from public.prospects p where p.id > coalesce(p_after_id, '') order by p.id limit v_limit
    ), changed as (select * from batch where all_data is distinct from sanitized), applied as (
      update public.prospects p set all_data = changed.sanitized
      from changed where p_apply and p.id = changed.id returning p.id
    ) select count(*)::integer, count(*) filter (where all_data is distinct from sanitized)::integer,
        (select count(*)::integer from applied), max(id)
      into scanned, candidates, updated, next_after_id from batch;
    remaining := next_after_id is not null and exists (select 1 from public.prospects p where p.id > next_after_id);
  elsif p_entity = 'company' then
    with batch as materialized (
      select c.id, c.all_data, public.fixed_import_json_v1('company', c.all_data) as sanitized
      from public.companies c where c.id > coalesce(p_after_id, '') order by c.id limit v_limit
    ), changed as (select * from batch where all_data is distinct from sanitized), applied as (
      update public.companies c set all_data = changed.sanitized
      from changed where p_apply and c.id = changed.id returning c.id
    ) select count(*)::integer, count(*) filter (where all_data is distinct from sanitized)::integer,
        (select count(*)::integer from applied), max(id)
      into scanned, candidates, updated, next_after_id from batch;
    remaining := next_after_id is not null and exists (select 1 from public.companies c where c.id > next_after_id);
  elsif p_entity = 'list_row' then
    with batch as materialized (
      select r.id, r.raw_data, public.fixed_import_json_v1('prospect', r.raw_data) as sanitized
      from public.list_rows r where r.id > coalesce(nullif(p_after_id, '')::bigint, 0) order by r.id limit v_limit
    ), changed as (select * from batch where raw_data is distinct from sanitized), applied as (
      update public.list_rows r set raw_data = changed.sanitized
      from changed where p_apply and r.id = changed.id returning r.id
    ) select count(*)::integer, count(*) filter (where raw_data is distinct from sanitized)::integer,
        (select count(*)::integer from applied), max(id)::text
      into scanned, candidates, updated, next_after_id from batch;
    remaining := next_after_id is not null and exists (select 1 from public.list_rows r where r.id > next_after_id::bigint);
  else
    with batch as materialized (
      select m.list_id, m.prospect_id, m.raw_data,
        public.fixed_import_json_v1('prospect', m.raw_data) as sanitized,
        m.list_id || ':' || m.prospect_id as cursor_id
      from public.list_memberships m
      where m.list_id || ':' || m.prospect_id > coalesce(p_after_id, '')
      order by m.list_id || ':' || m.prospect_id limit v_limit
    ), changed as (select * from batch where raw_data is distinct from sanitized), applied as (
      update public.list_memberships m set raw_data = changed.sanitized
      from changed where p_apply and m.list_id = changed.list_id and m.prospect_id = changed.prospect_id returning m.list_id
    ) select count(*)::integer, count(*) filter (where raw_data is distinct from sanitized)::integer,
        (select count(*)::integer from applied), max(cursor_id)
      into scanned, candidates, updated, next_after_id from batch;
    remaining := next_after_id is not null and exists (
      select 1 from public.list_memberships m where m.list_id || ':' || m.prospect_id > next_after_id
    );
  end if;
  return next;
end;
$function$;

comment on function public.sanitize_import_payloads_v1(text, text, integer, boolean) is
  'Keyset-checkpointed fixed-field cleanup. p_apply defaults false; pass returned next_after_id to the next batch.';

revoke execute on function public.fixed_import_key_v1(text, text) from public, anon, authenticated;
revoke execute on function public.fixed_import_json_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.sanitize_import_payloads_v1(text, text, integer, boolean) from public, anon, authenticated;
grant execute on function public.fixed_import_key_v1(text, text) to service_role;
grant execute on function public.fixed_import_json_v1(text, jsonb) to service_role;
grant execute on function public.sanitize_import_payloads_v1(text, text, integer, boolean) to service_role;

-- Add ICP as a virtual filter to both complete-SQL compilers and their scalar
-- reference implementations. The value is the authorized client id; contains
-- and not_contains are exact for UUID/text client ids and compose with every
-- existing search, scope, export, and frozen bulk operation.
do $patch_filters$
declare
  v_definition text;
  v_rewritten text;
begin
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$when '__tags' then 'pi.tag_text'$old$,
    $new$when '__icp_verified' then 'array_to_string(pi.icp_verified_client_ids, '' | '')'
      when '__tags' then 'pi.tag_text'$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_filter_sql_v1 ICP mapping'; end if;
  execute v_rewritten;

  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$when '__tags' then (p_row).tag_text$old$,
    $new$when '__icp_verified' then array_to_string((p_row).icp_verified_client_ids, ' | ')
        when '__tags' then (p_row).tag_text$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_index_matches_v1 ICP mapping'; end if;
  execute v_rewritten;

  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$when '__company' then 'c.name'$old$,
    $new$when '__company_icp_verified' then '(select array_to_string(array_agg(v.client_id order by v.client_id), '' | '') from public.client_company_icp_validations v where v.company_id = c.id)'
        when '__company' then 'c.name'$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_filter_sql_v3 ICP mapping'; end if;
  execute v_rewritten;

  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$when '__company' then (p_row).name$old$,
    $new$when '__company_icp_verified' then (select array_to_string(array_agg(v.client_id order by v.client_id), ' | ') from public.client_company_icp_validations v where v.company_id = (p_row).id)
        when '__company' then (p_row).name$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_matches_filters_v1 ICP mapping'; end if;
  execute v_rewritten;
end;
$patch_filters$;

create index if not exists idx_client_company_icp_validations_company_client
  on public.client_company_icp_validations(company_id, client_id);

-- Client Date Contacted is stored in client_prospects.date_added. The legacy
-- list workspace only read contact_events, so imported contact dates appeared
-- as never contacted. Use the same client date as the People workspace.
do $patch_cooldown$
declare
  v_definition text;
  v_rewritten text;
begin
  select pg_get_functiondef('public.list_workspace(text,text,integer,integer)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    'select max(ce.contacted_at) as last_contacted_at from public.contact_events ce' || chr(10) ||
    '      where ce.prospect_id = ps.id and ce.client_id = l.client_id',
    'select cp.date_added::timestamp at time zone ''UTC'' as last_contacted_at
      from public.client_prospects cp
      where cp.prospect_id = ps.id and cp.client_id = l.client_id');
  if v_rewritten = v_definition then raise exception 'Could not patch list_workspace contact date'; end if;
  execute v_rewritten;
end;
$patch_cooldown$;

-- Serialized, resumable classifier unit. A caller repeats this until remaining
-- is zero. pg_try_advisory_xact_lock prevents two maintenance loops from doing
-- the same dataset pass concurrently.
create or replace function public.run_title_classification_batch_v2(p_limit integer default 500)
returns table(processed integer, remaining bigint, acquired boolean)
language plpgsql
security definer
set search_path = ''
set statement_timeout = '60s'
as $function$
declare
  v_updated_at timestamptz;
begin
  acquired := pg_try_advisory_xact_lock(hashtext('prospect-title-classifier-v2'));
  if not acquired then processed := 0; remaining := null; return next; return; end if;
  processed := public.reclassify_prospect_titles_v1(greatest(1, least(coalesce(p_limit, 500), 5000)));
  select s.keywords_updated_at into v_updated_at from public.title_classifier_state s where s.id;
  select count(*) into remaining from public.prospects p
  where p.title_classified_at is null or p.title_classified_at < v_updated_at;
  return next;
end;
$function$;

revoke execute on function public.run_title_classification_batch_v2(integer) from public, anon, authenticated;
grant execute on function public.run_title_classification_batch_v2(integer) to service_role;

commit;
