\pset pager off
\set ON_ERROR_STOP on

do $verify$
declare
  missing_core text[];
  rls_disabled text[];
  exposed_grants text[];
begin
  select array_agg(required.object_name order by required.object_name)
    into missing_core
  from (values
    ('auth.users'), ('public.clients'), ('public.companies'),
    ('public.imports'), ('public.list_rows'), ('public.lists'),
    ('public.prospects'), ('supabase_migrations.schema_migrations'),
    ('vault.secrets')
  ) required(object_name)
  where to_regclass(required.object_name) is null;
  if missing_core is not null then
    raise exception 'restore is missing required relations: %', array_to_string(missing_core, ', ');
  end if;

  select array_agg(format('%I.%I', n.nspname, c.relname) order by n.nspname, c.relname)
    into rls_disabled
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity;
  if rls_disabled is not null then
    raise exception 'restored public tables without RLS: %', array_to_string(rls_disabled, ', ');
  end if;

  select array_agg(format('%s:%I.%I:%s', g.grantee, g.table_schema, g.table_name, g.privilege_type)
    order by g.grantee, g.table_schema, g.table_name, g.privilege_type)
    into exposed_grants
  from information_schema.role_table_grants g
  where g.table_schema = 'public' and g.grantee in ('PUBLIC', 'anon', 'authenticated');
  if exposed_grants is not null then
    raise exception 'restored public table grants exceed the server-only boundary: %', array_to_string(exposed_grants, ', ');
  end if;

  if (select count(*) from supabase_migrations.schema_migrations) = 0 then
    raise exception 'restored migration history is empty';
  end if;

  if exists (
    select 1 from public.list_memberships m
    left join public.lists l on l.id = m.list_id
    left join public.prospects p on p.id = m.prospect_id
    where l.id is null or p.id is null
    limit 1
  ) then
    raise exception 'restored list memberships contain an orphan';
  end if;
end
$verify$;

select 'auth.users' as relation, count(*)::bigint as restored_rows from auth.users
union all select 'clients', count(*) from public.clients
union all select 'companies', count(*) from public.companies
union all select 'imports', count(*) from public.imports
union all select 'list_rows', count(*) from public.list_rows
union all select 'lists', count(*) from public.lists
union all select 'prospects', count(*) from public.prospects
union all select 'schema_migrations', count(*) from supabase_migrations.schema_migrations
order by 1;

select current_database() as scratch_database,
  current_user as restore_role,
  (select rolsuper from pg_roles where rolname = current_user) as restore_role_is_superuser,
  (select relrowsecurity from pg_class where oid = 'vault.secrets'::regclass) as vault_rls_enabled,
  pg_get_userbyid((select relowner from pg_class where oid = 'vault.secrets'::regclass)) as vault_table_owner,
  (select count(*) from pg_tables where schemaname = 'public') as public_tables_checked;
