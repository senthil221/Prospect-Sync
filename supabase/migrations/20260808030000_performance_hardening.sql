create index if not exists idx_imports_client_id on public.imports(client_id);
create index if not exists idx_imports_list_id on public.imports(list_id);
create index if not exists idx_memberships_import_id on public.list_memberships(import_id);

create or replace function public.dashboard_workspace()
returns table(result jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'stats', jsonb_build_object(
      'prospects', (select count(*) from public.prospects),
      'companies', (select count(*) from public.companies),
      'clients', (select count(*) from public.clients),
      'lists', (select count(*) from public.lists),
      'rowsImported', (select coalesce(sum(processed_rows), 0) from public.imports),
      'duplicatesDetected', (select coalesce(sum(duplicates_linked), 0) from public.imports)
    ),
    'recentImports', coalesce((
      select jsonb_agg(to_jsonb(recent) order by recent.created_at desc)
      from (
        select i.id, i.file_name, i.status, i.processed_rows, i.unique_added,
          i.duplicates_linked, i.created_at, c.name as client_name, l.name as list_name
        from public.imports i
        left join public.clients c on c.id = i.client_id
        left join public.lists l on l.id = i.list_id
        order by i.created_at desc
        limit 6
      ) recent
    ), '[]'::jsonb)
  );
$$;

revoke execute on function public.dashboard_workspace() from public, anon, authenticated;
grant execute on function public.dashboard_workspace() to service_role;

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end
$$;
