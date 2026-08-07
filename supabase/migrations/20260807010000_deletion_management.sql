create or replace function public.cleanup_orphaned_master_records(
  p_candidate_prospect_ids text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_prospects integer := 0;
  deleted_companies integer := 0;
begin
  delete from public.prospects p
  where (p_candidate_prospect_ids is null or p.id = any(p_candidate_prospect_ids))
    and not exists (
      select 1 from public.list_memberships lm where lm.prospect_id = p.id
    );
  get diagnostics deleted_prospects = row_count;

  delete from public.companies c
  where not exists (
    select 1 from public.prospects p where p.company_id = c.id
  );
  get diagnostics deleted_companies = row_count;

  return jsonb_build_object(
    'orphanedProspectsDeleted', deleted_prospects,
    'orphanedCompaniesDeleted', deleted_companies
  );
end;
$$;

create or replace function public.delete_list_with_cleanup(
  p_list_id text,
  p_delete_orphans boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  list_name_value text;
  candidate_prospect_ids text[] := array[]::text[];
  membership_count integer := 0;
  import_count integer := 0;
  cleanup_result jsonb := jsonb_build_object(
    'orphanedProspectsDeleted', 0,
    'orphanedCompaniesDeleted', 0
  );
begin
  select l.name into list_name_value
  from public.lists l
  where l.id = p_list_id;

  if not found then
    raise exception 'List not found.' using errcode = 'P0002';
  end if;

  select coalesce(array_agg(distinct lm.prospect_id) filter (where lm.prospect_id is not null), array[]::text[]), count(lm.prospect_id)::integer
  into candidate_prospect_ids, membership_count
  from public.list_memberships lm
  where lm.list_id = p_list_id;

  select count(*)::integer into import_count
  from public.imports i
  where i.list_id = p_list_id;

  delete from public.lists where id = p_list_id;

  if p_delete_orphans then
    cleanup_result := public.cleanup_orphaned_master_records(candidate_prospect_ids);
  end if;

  return jsonb_build_object(
    'kind', 'list',
    'name', list_name_value,
    'listsDeleted', 1,
    'importsDeleted', import_count,
    'membershipsDeleted', membership_count
  ) || cleanup_result;
end;
$$;

create or replace function public.delete_client_with_cleanup(
  p_client_id text,
  p_delete_orphans boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  client_name_value text;
  candidate_prospect_ids text[] := array[]::text[];
  list_count integer := 0;
  import_count integer := 0;
  membership_count integer := 0;
  cleanup_result jsonb := jsonb_build_object(
    'orphanedProspectsDeleted', 0,
    'orphanedCompaniesDeleted', 0
  );
begin
  select c.name into client_name_value
  from public.clients c
  where c.id = p_client_id;

  if not found then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  select coalesce(array_agg(distinct lm.prospect_id) filter (where lm.prospect_id is not null), array[]::text[]), count(lm.prospect_id)::integer
  into candidate_prospect_ids, membership_count
  from public.lists l
  left join public.list_memberships lm on lm.list_id = l.id
  where l.client_id = p_client_id;

  select count(*)::integer into list_count
  from public.lists l
  where l.client_id = p_client_id;

  select count(*)::integer into import_count
  from public.imports i
  where i.client_id = p_client_id;

  delete from public.clients where id = p_client_id;

  if p_delete_orphans then
    cleanup_result := public.cleanup_orphaned_master_records(candidate_prospect_ids);
  end if;

  return jsonb_build_object(
    'kind', 'client',
    'name', client_name_value,
    'clientsDeleted', 1,
    'listsDeleted', list_count,
    'importsDeleted', import_count,
    'membershipsDeleted', membership_count
  ) || cleanup_result;
end;
$$;

create or replace function public.delete_import_with_cleanup(
  p_import_id text,
  p_delete_orphans boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  import_name_value text;
  list_id_value text;
  candidate_prospect_ids text[] := array[]::text[];
  membership_count integer := 0;
  list_deleted integer := 0;
  cleanup_result jsonb := jsonb_build_object(
    'orphanedProspectsDeleted', 0,
    'orphanedCompaniesDeleted', 0
  );
begin
  select i.file_name, i.list_id into import_name_value, list_id_value
  from public.imports i
  where i.id = p_import_id;

  if not found then
    raise exception 'Import not found.' using errcode = 'P0002';
  end if;

  select coalesce(array_agg(distinct lm.prospect_id), array[]::text[]), count(*)::integer
  into candidate_prospect_ids, membership_count
  from public.list_memberships lm
  where lm.import_id = p_import_id;

  delete from public.list_memberships where import_id = p_import_id;
  delete from public.imports where id = p_import_id;

  if not exists (select 1 from public.imports i where i.list_id = list_id_value)
    and not exists (select 1 from public.list_memberships lm where lm.list_id = list_id_value) then
    delete from public.lists where id = list_id_value;
    get diagnostics list_deleted = row_count;
  end if;

  if p_delete_orphans then
    cleanup_result := public.cleanup_orphaned_master_records(candidate_prospect_ids);
  end if;

  return jsonb_build_object(
    'kind', 'import',
    'name', import_name_value,
    'importsDeleted', 1,
    'listsDeleted', list_deleted,
    'membershipsDeleted', membership_count
  ) || cleanup_result;
end;
$$;

revoke execute on function public.cleanup_orphaned_master_records(text[]) from public, anon, authenticated;
revoke execute on function public.delete_list_with_cleanup(text, boolean) from public, anon, authenticated;
revoke execute on function public.delete_client_with_cleanup(text, boolean) from public, anon, authenticated;
revoke execute on function public.delete_import_with_cleanup(text, boolean) from public, anon, authenticated;

grant execute on function public.cleanup_orphaned_master_records(text[]) to service_role;
grant execute on function public.delete_list_with_cleanup(text, boolean) to service_role;
grant execute on function public.delete_client_with_cleanup(text, boolean) to service_role;
grant execute on function public.delete_import_with_cleanup(text, boolean) to service_role;
