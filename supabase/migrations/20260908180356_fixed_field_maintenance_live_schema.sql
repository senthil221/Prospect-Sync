-- Historical cleanup also clears obsolete typed People profile values, as
-- requested. Each batch updates its search-index projection in the same txn.
create or replace function public.sanitize_import_payloads_v1(
  p_entity text, p_after_id text default null, p_limit integer default 1000,
  p_apply boolean default false
)
returns table(scanned integer, candidates integer, updated integer, next_after_id text, remaining boolean)
language plpgsql security definer set search_path = '' set statement_timeout = '120s'
as $fn$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit,1000),5000));
  v_ids text[];
  v_table text;
  v_column text;
  v_type text;
begin
  if p_entity = 'membership' then
    -- raw_data was removed from this table in 20260825030000. list_rows is
    -- the surviving source payload; do not scan or rewrite membership links.
    scanned := 0; candidates := 0; updated := 0; next_after_id := null; remaining := false;
    return next; return;
  elsif p_entity = 'prospect' then
    with batch as materialized (
      select p.id, p.all_data, p.personal_email, p.seniority, p.department,
        p.city, p.state, p.country, p.location, p.keywords,
        public.fixed_import_json_v1('prospect',p.all_data) || jsonb_strip_nulls(jsonb_build_object(
          'First Name',nullif(p.first_name,''),'Last Name',nullif(p.last_name,''),
          'Job Title',nullif(p.title,''),'Email',nullif(p.work_email,''),
          'Mobile Number',nullif(p.mobile_number,''),'Personal LinkedIn URL',nullif(p.linkedin_url,''),
          'Company Name',nullif(c.name,''),'Website',nullif(c.domain,''))) as sanitized
      from public.prospects p left join public.companies c on c.id=p.company_id
      where p.id > coalesce(p_after_id,'') order by p.id limit v_limit
    ), changed as materialized (
      select * from batch where all_data is distinct from sanitized
        or concat(personal_email,seniority,department,city,state,country,location) <> ''
        or coalesce(cardinality(keywords),0)>0
        or exists(select 1 from public.prospect_identifiers i where i.prospect_id=batch.id and i.type='personal_email')
    ), applied as (
      update public.prospects p set all_data=c.sanitized, personal_email='',
        seniority='',department='',city='',state='',country='',location='',keywords='{}'::text[]
      from changed c where p_apply and p.id=c.id returning p.id
    ) select (select count(*)::integer from batch),(select count(*)::integer from changed),
      count(*)::integer,(select max(id) from batch),array_agg(id)
      into scanned,candidates,updated,next_after_id,v_ids from applied;
    if p_apply and cardinality(v_ids)>0 then
      delete from public.prospect_identifiers where type='personal_email' and prospect_id=any(v_ids);
      perform public.reindex_prospects(v_ids);
    end if;
    remaining := next_after_id is not null and exists(select 1 from public.prospects p where p.id>next_after_id);
    return next; return;
  elsif p_entity = 'catalog' then
    with batch as materialized (
      select field_name from public.prospect_fields where field_name>coalesce(p_after_id,'') order by field_name limit v_limit
    ), changed as (
      select field_name from batch where field_name not in
        ('First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website')
    ), applied as (
      delete from public.prospect_fields f using changed c where p_apply and f.field_name=c.field_name returning f.field_name
    ) select (select count(*)::integer from batch),(select count(*)::integer from changed),
      (select count(*)::integer from applied),(select max(field_name) from batch)
      into scanned,candidates,updated,next_after_id;
    remaining := next_after_id is not null and exists(select 1 from public.prospect_fields f where f.field_name>next_after_id);
    return next; return;
  elsif p_entity in ('company','list_row') then
    v_table := case p_entity when 'company' then 'companies' else 'list_rows' end;
    v_column := case p_entity when 'company' then 'all_data' else 'raw_data' end;
    v_type := case p_entity when 'company' then 'text' else 'bigint' end;
    return query execute format($sql$
      with batch as materialized (
        select id,%1$I as payload,public.fixed_import_json_v1(%2$L,%1$I) as sanitized
        from public.%3$I where id>coalesce(nullif($1,'')::%4$s,%5$L::%4$s) order by id limit $2
      ), changed as (select * from batch where payload is distinct from sanitized), applied as (
        update public.%3$I t set %1$I=c.sanitized from changed c where $3 and t.id=c.id returning t.id
      ) select (select count(*)::integer from batch),(select count(*)::integer from changed),
        (select count(*)::integer from applied),(select max(id)::text from batch),
        exists(select 1 from public.%3$I where id>(select max(id) from batch))
    $sql$,v_column,case p_entity when 'company' then 'company' else 'prospect' end,v_table,v_type,
      case p_entity when 'company' then '' else '0' end) using p_after_id,v_limit,p_apply;
    return;
  end if;
  raise exception 'Unsupported cleanup entity' using errcode='22023';
end;
$fn$;
revoke execute on function public.sanitize_import_payloads_v1(text,text,integer,boolean) from public,anon,authenticated;
grant execute on function public.sanitize_import_payloads_v1(text,text,integer,boolean) to service_role;

-- The legacy list workspace still referenced the dropped raw_data column.
-- Join one source row per membership, preserving pagination and avoiding
-- duplicate list members when the same person appeared twice in an import.
do $fix_list$
declare v_definition text; v_rewritten text;
begin
  select pg_get_functiondef('public.list_workspace(text,text,integer,integer)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,'lm.raw_data','source_row.raw_data');
  v_rewritten := replace(v_rewritten,'from public.list_memberships lm',
    'from public.list_memberships lm
    left join lateral (
      select lr.raw_data from public.list_rows lr
      where lr.list_id=lm.list_id and lr.prospect_id=lm.prospect_id and lr.import_id=lm.import_id
      order by lr.id desc limit 1
    ) source_row on true');
  if v_rewritten=v_definition then raise exception 'Missing list workspace patch anchor'; end if;
  execute v_rewritten;
end;
$fix_list$;
