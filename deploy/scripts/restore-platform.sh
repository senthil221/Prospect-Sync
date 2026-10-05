#!/usr/bin/env bash
# Supabase platform objects that pg_restore cannot recreate verbatim in a fresh
# (template0) database. Sourced by restore.sh and restore-isolated.sh.
#
# Found by the isolated restore drill on 2026-10-05: the 20261005T032631Z
# archive loaded every table, then stopped near the end on two entries that
# belong to the Supabase image, not to Prospect Sync:
#
#   * ACL graphql_public FUNCTION graphql(...). The function is not in the
#     archive - the image's issue_pg_graphql_access event trigger creates it
#     when pg_graphql is created - so the GRANT fails with "does not exist".
#   * EVENT TRIGGER issue_pg_net_access, owned by postgres. Only a superuser
#     may own an event trigger and this image makes postgres a non-superuser,
#     so "ALTER EVENT TRIGGER ... OWNER TO postgres" is refused.
#
# With --exit-on-error either one fails the whole restore, so a real recovery
# (restore.sh) would have rolled itself back too. The fix keeps the restore
# complete rather than skipping anything:
#
#   1. restore every other entry (restore_platform_split's main list);
#   2. recreate pg_graphql in its schema, so the now-restored platform event
#      trigger builds graphql_public.graphql exactly as the image does;
#   3. restore the held-back entries with --no-owner: the GRANT lands on the
#      rebuilt function, and the event trigger is owned by the restoring
#      superuser (supabase_admin) - the only owner this image allows.

# restore_platform_split <toc> <main.list> <late.list>
# Splits a `pg_restore -l` listing into everything else and the held-back
# platform entries. The late list may be empty (an archive without them).
restore_platform_split() {
  local toc="$1" main="$2" late="$3"
  grep -E '^[0-9]+; [0-9]+ [0-9]+ (ACL graphql_public FUNCTION graphql\(|EVENT TRIGGER - [A-Za-z0-9_]+ postgres$)' "$toc" >"$late" || true
  grep -vxF -f "$late" "$toc" >"$main" || true
  [[ -s "$main" ]]
}

# Step 2. A no-op for an archive without pg_graphql.
RESTORE_PLATFORM_REBUILD_SQL="do \$platform\$
declare v_schema text;
begin
  select n.nspname into v_schema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pg_graphql';
  if v_schema is not null then
    drop extension pg_graphql;
    execute format('create extension pg_graphql with schema %I', v_schema);
  end if;
end \$platform\$;"
