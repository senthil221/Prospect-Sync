-- Read-only assertions plus two cleanup rows inside a rolled-back transaction.
begin;
set local statement_timeout='45s';
set local lock_timeout='5s';
create temporary table verify_people_before as
select id,to_jsonb(p)-array['all_data','personal_email','seniority','department','city','state','country','location','keywords'] as retained
from public.prospects p order by id limit 2;
select scanned,candidates,updated from public.sanitize_import_payloads_v1('prospect',null,2,true);
do $assert$
begin
  if exists(select 1 from verify_people_before b join public.prospects p using(id)
    where b.retained is distinct from to_jsonb(p)-array['all_data','personal_email','seniority','department','city','state','country','location','keywords']) then
    raise exception 'Cleanup changed a retained profile or operational value';
  end if;
  if exists(select 1 from verify_people_before b join public.prospects p using(id)
    where concat(p.personal_email,p.seniority,p.department,p.city,p.state,p.country,p.location)<>'' or cardinality(p.keywords)>0) then
    raise exception 'Retired People fields survived cleanup';
  end if;
  if exists(select 1 from verify_people_before b join public.prospects p using(id),lateral jsonb_object_keys(p.all_data) k(key)
    where public.fixed_import_key_v1('prospect',k.key) is null) then raise exception 'Unsupported payload field survived'; end if;
  if exists(select 1 from verify_people_before b join public.prospect_identifiers i on i.prospect_id=b.id where i.type='personal_email') then
    raise exception 'Personal email identifier survived cleanup';
  end if;
end;
$assert$;
do $icp$
declare v_client text; v_field text; v_operator text; v_filter jsonb; v_sql text; v_mismatches bigint;
begin
  select id into v_client from public.clients order by id limit 1;
  foreach v_operator in array array['contains','not_contains'] loop
    v_filter:=jsonb_build_array(jsonb_build_object('field','__icp_verified','operator',v_operator,'values',jsonb_build_array(v_client)));
    v_sql:=public.prospect_filter_sql_v1('',v_filter);
    execute format('select count(*) from (select * from public.prospect_index order by id limit 1000) pi where ((%s) is true) is distinct from public.prospect_index_matches_v1(pi,'''',%L::jsonb)',v_sql,v_filter::text) into v_mismatches;
    if v_mismatches<>0 then raise exception 'People ICP compiler/scalar mismatch'; end if;
    v_filter:=jsonb_build_array(jsonb_build_object('field','__company_icp_verified','operator',v_operator,'values',jsonb_build_array(v_client)));
    v_sql:=public.company_filter_sql_v3('',v_filter,false);
    execute format('select count(*) from (select * from public.companies order by id limit 1000) c where ((%s) is true) is distinct from public.company_matches_filters_v1(c,'''',%L::jsonb)',v_sql,v_filter::text) into v_mismatches;
    if v_mismatches<>0 then raise exception 'Company ICP compiler/scalar mismatch'; end if;
  end loop;
end;
$icp$;
do $export$
declare v_rows jsonb; v_name text; v_id text; v_seen text[]:='{}'; v_count integer:=0; v_start timestamptz:=clock_timestamp();
begin
  for batch in 1..10 loop
    select result_rows into v_rows from public.search_company_export_v2(
      p_limit=>500,p_after_name=>v_name,p_after_id=>v_id,
      p_keys=>array['name','domain','industry','keywords','short_description','founded_year',
        'employee_count_min','employee_count_max','city','state','country','technologies','total_funding']);
    if jsonb_array_length(v_rows)<>500 then raise exception 'Export returned an incomplete test page'; end if;
    if exists(select 1 from jsonb_array_elements(v_rows) r where r->>'id'=any(v_seen)) then raise exception 'Export repeated rows'; end if;
    select v_seen||array_agg(r->>'id') into v_seen from jsonb_array_elements(v_rows) r;
    v_name:=v_rows->499->>'sort_name'; v_id:=v_rows->499->>'id';
    v_count:=v_count+jsonb_array_length(v_rows);
  end loop;
  raise notice 'Export verified: % distinct companies in %',v_count,clock_timestamp()-v_start;
end;
$export$;
rollback;
