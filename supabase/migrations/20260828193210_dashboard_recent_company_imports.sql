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
        select *
        from (
          select i.id, 'prospects'::text as kind, i.file_name, i.data_source, i.status,
            i.processed_rows, i.unique_added, i.duplicates_linked, i.created_at,
            c.name as client_name, l.name as list_name,
            0::integer as added_count, 0::integer as updated_count, 0::integer as skipped_count
          from public.imports i
          left join public.clients c on c.id = i.client_id
          left join public.lists l on l.id = i.list_id
          where i.status = 'completed'

          union all

          select ci.id, 'companies'::text as kind, ci.file_name, ci.data_source, ci.status,
            ci.processed_rows, 0::integer as unique_added, 0::integer as duplicates_linked,
            ci.created_at, null::text as client_name, null::text as list_name,
            ci.added_count, ci.updated_count, ci.skipped_count
          from public.company_imports ci
          where ci.status = 'completed'
        ) all_imports
        order by created_at desc
        limit 6
      ) recent
    ), '[]'::jsonb)
  );
$$;

revoke execute on function public.dashboard_workspace() from public, anon, authenticated;
grant execute on function public.dashboard_workspace() to service_role;
