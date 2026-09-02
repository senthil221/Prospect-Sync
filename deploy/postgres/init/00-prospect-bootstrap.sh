#!/bin/bash
# Runs once, on first initialisation of an empty data directory.
#
# Idempotent - safe to re-run against a live database, which is what
# scripts/restore.sh does after a recovery:
#   docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh
set -euo pipefail

DB="${POSTGRES_DB:-postgres}"
# During first initialization local connections use trust auth. During an
# update or restore the same idempotent script runs against the live cluster,
# whose pg_hba requires the password already supplied to the db container.
export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"

# Connect as supabase_admin, NOT postgres.
#
# In supabase/postgres the `postgres` role is deliberately not a superuser -
# supabase_admin is. `ALTER ROLE <other> SET ...` requires superuser, so running
# this as postgres fails partway through, and with ON_ERROR_STOP the rest of the
# file silently never executes: no pg_trgm, no timeouts, and a stack that only
# breaks later during migration.
#
# PGPASSWORD is harmless during trust-based initialization and required when
# this script is intentionally rerun against an existing data directory.
psql -v ON_ERROR_STOP=1 --username supabase_admin --dbname "$DB" <<-EOSQL
	-- Role logins ----------------------------------------------------------
	-- The supabase/postgres image already sets these from POSTGRES_PASSWORD.
	-- Re-asserting is harmless and covers an image that stops doing it, but a
	-- superuser must be skipped: altering one errors, and that error would
	-- abort every statement below.
	do \$\$
	declare
	  r text;
	begin
	  foreach r in array array[
	    'authenticator',
	    'supabase_auth_admin',
	    'supabase_storage_admin',
	    'supabase_functions_admin',
	    'pgbouncer'
	  ] loop
	    if exists (select 1 from pg_roles where rolname = r and not rolsuper) then
	      begin
	        execute format('alter role %I with login password %L', r, '${POSTGRES_PASSWORD}');
	      exception when others then
	        raise notice 'skipped role %: %', r, sqlerrm;
	      end;
	    end if;
	  end loop;
	end
	\$\$;

	-- The bulk import worker assumes this narrowly-scoped NOLOGIN role.
	-- Recreate role membership after a logical disaster recovery where database
	-- objects survive but cluster roles do not.
	do \$\$
	begin
	  if not exists (select 1 from pg_roles where rolname = 'prospect_importer') then
	    create role prospect_importer nologin noinherit;
	  end if;
	end
	\$\$;
	grant prospect_importer to authenticator;

	-- ...and it now has its own login role to assume it from.
	--
	-- It used to connect as authenticator, the same login PostgREST uses, which
	-- meant two things. Per-role connection limits could not separate the import
	-- pool from the interactive pool, because both were the same role. And the
	-- worker inherited authenticator's membership of service_role, so a bug in it
	-- carried the whole database's authority rather than the narrow set it needs.
	--
	-- prospect_import_worker is a member of prospect_importer and nothing else.
	-- Everything the worker runs directly is covered by that membership: usage on
	-- the prospect_import schema, select/insert/delete on staged_rows, and
	-- execute on process_staged_batch_v1. Its existing `set role
	-- prospect_importer` still works, because a member may assume its role.
	--
	-- Same password as every other role here, so no new secret has to be
	-- generated, distributed or rotated separately.
	do \$\$
	begin
	  if not exists (select 1 from pg_roles where rolname = 'prospect_import_worker') then
	    create role prospect_import_worker login;
	  end if;
	end
	\$\$;
	alter role prospect_import_worker with login password '${POSTGRES_PASSWORD}';
	grant prospect_importer to prospect_import_worker;
	-- Deliberately not service_role, and asserted rather than assumed: if a
	-- future change needs the worker to do something privileged, that belongs in
	-- an audited SECURITY DEFINER function with its own scope check.
	do \$\$
	begin
	  if exists (
	    select 1 from pg_auth_members am
	    join pg_roles granted on granted.oid = am.roleid
	    join pg_roles member on member.oid = am.member
	    where member.rolname = 'prospect_import_worker' and granted.rolname = 'service_role'
	  ) then
	    revoke service_role from prospect_import_worker;
	  end if;
	end
	\$\$;

	-- The operations worker: a second narrow capability role, and a login for it.
	--
	-- Section 8.3 asks for prospect_ops_worker as its own login with its own
	-- statement_timeout, idle timeout and CONNECTION LIMIT, inheriting only a
	-- narrow NOLOGIN capability role - never service_role.
	--
	-- prospect_operator holds nothing but EXECUTE on the handful of
	-- prospect_results functions that drive a build. Those are SECURITY DEFINER,
	-- so the worker needs no privilege on prospect_index, companies or even on
	-- result_set_items: it can claim work, fill a batch, fail a set and expire
	-- old ones, and it cannot read a single prospect directly. The functions the
	-- application owns - request_set_v1, page_v1, status_v1 - are deliberately
	-- not granted to it.
	do \$\$
	begin
	  if not exists (select 1 from pg_roles where rolname = 'prospect_operator') then
	    create role prospect_operator nologin noinherit;
	  end if;
	  if not exists (select 1 from pg_roles where rolname = 'prospect_ops_worker') then
	    create role prospect_ops_worker login;
	  end if;
	end
	\$\$;
	alter role prospect_ops_worker with login password '${POSTGRES_PASSWORD}';
	grant prospect_operator to prospect_ops_worker;
	do \$\$
	begin
	  if exists (
	    select 1 from pg_auth_members am
	    join pg_roles granted on granted.oid = am.roleid
	    join pg_roles member on member.oid = am.member
	    where member.rolname = 'prospect_ops_worker' and granted.rolname = 'service_role'
	  ) then
	    revoke service_role from prospect_ops_worker;
	  end if;
	end
	\$\$;

	-- JWT settings PostgREST and legacy helpers read from the database ------
	alter database "${DB}" set "app.settings.jwt_secret" to '${JWT_SECRET}';
	alter database "${DB}" set "app.settings.jwt_exp" to '${JWT_EXP:-3600}';

	-- Extensions this application needs ------------------------------------
	create extension if not exists pg_trgm;
	create extension if not exists pg_stat_statements;

	-- Guard rails ----------------------------------------------------------
	-- The Prospect Sync RPCs set their own statement_timeout. This is the
	-- backstop for everything else arriving through PostgREST, so one bad
	-- ad-hoc query cannot pin a vCPU for an hour.
	alter role authenticator set statement_timeout = '120s';
	alter role authenticator set idle_in_transaction_session_timeout = '60s';
	alter role authenticator set lock_timeout = '10s';

	-- Studio and psql sessions get more rope, but not unlimited.
	alter role postgres set idle_in_transaction_session_timeout = '300s';

	-- An import batch is legitimately long, so the worker's ceiling is generous
	-- but bounded. It was inheriting authenticator's 120s and then overriding it
	-- per session to 10 minutes anyway, which put the guard rail in the
	-- application rather than on the role.
	alter role prospect_import_worker set statement_timeout = '15min';
	alter role prospect_import_worker set idle_in_transaction_session_timeout = '5min';
	alter role prospect_import_worker set lock_timeout = '30s';

	-- Pool separation, database side.
	--
	-- Measured on this deployment: PostgREST does not cancel a statement when
	-- the browser gives up on the request. An export abandoned after 2.1s kept
	-- its backend busy for the full 7.9s, holding a pool connection nobody was
	-- waiting for. The application's admission guard fails fast, but it lives in
	-- one process and blue/green runs two slots at once, so these limits are the
	-- authority rather than the guard.
	--
	-- PGRST_DB_POOL is 24; 30 leaves PostgREST headroom while making it
	-- impossible for the interactive pool alone to exhaust the cluster. The
	-- worker holds a single direct connection, so 4 covers a restart overlap
	-- without letting it take the box. max_connections is 100 with 3 reserved,
	-- and auth, storage, meta, studio and psql draw on the rest.
	alter role authenticator connection limit 30;
	alter role prospect_import_worker connection limit 4;

	-- Building a result set is one bounded batch at a time, so it never needs a
	-- long statement; 5 minutes is generous for the largest batch and still
	-- bounded. Two connections: one worker, plus a restart overlap.
	alter role prospect_ops_worker set statement_timeout = '5min';
	alter role prospect_ops_worker set idle_in_transaction_session_timeout = '2min';
	alter role prospect_ops_worker set lock_timeout = '15s';
	alter role prospect_ops_worker connection limit 2;

	-- Application objects belong to postgres ---------------------------------
	-- scripts/migrate.sh connects as postgres, and CREATE OR REPLACE FUNCTION
	-- requires ownership. Anything created through Studio or a psql session
	-- opened as supabase_admin is therefore owned by the wrong role, and the
	-- next migration that touches it fails the release with
	-- "must be owner of function ...". That is not hypothetical: it is what
	-- blocked the 20260826040000 release.
	--
	-- So hand ownership of the application's own public objects back to
	-- postgres on every deploy. Extension members are excluded - pg_trgm and
	-- unaccent are installed by supabase_admin and must stay that way - which
	-- is what the pg_depend deptype 'e' test filters out.
	do \$\$
	declare
	  obj record;
	begin
	  for obj in
	    select 'function ' || p.oid::regprocedure::text as spec
	    from pg_proc p
	    join pg_namespace n on n.oid = p.pronamespace
	    where n.nspname = 'public'
	      and pg_get_userbyid(p.proowner) = 'supabase_admin'
	      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
	    union all
	    select case c.relkind when 'v' then 'view ' when 'S' then 'sequence ' else 'table ' end
	      || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
	    from pg_class c
	    join pg_namespace n on n.oid = c.relnamespace
	    where n.nspname = 'public'
	      and c.relkind in ('r', 'p', 'v', 'S')
	      and pg_get_userbyid(c.relowner) = 'supabase_admin'
	      and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
	  loop
	    execute format('alter %s owner to postgres', obj.spec);
	    raise notice 'prospect: reassigned % to postgres', obj.spec;
	  end loop;
	end
	\$\$;
EOSQL

# Assert the work actually landed. The failure mode this replaces was a script
# that reported success while having applied almost none of itself.
missing="$(psql -tAq --username supabase_admin --dbname "$DB" -c \
  "select string_agg(e, ', ') from unnest(array['pg_trgm','pg_stat_statements']) e
   where e not in (select extname from pg_extension)")"

if [[ -n "$missing" ]]; then
  echo "prospect: FAILED - extensions still missing: ${missing}" >&2
  exit 1
fi

# Same check for ownership. A release that reaches migrate.sh with application
# objects still owned by supabase_admin fails halfway through, which is worse
# than failing here with the list of what is wrong.
misowned="$(psql -tAq --username supabase_admin --dbname "$DB" -c \
  "select string_agg(name, ', ') from (
     select p.oid::regprocedure::text as name
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and pg_get_userbyid(p.proowner) = 'supabase_admin'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     union all
     select n.nspname || '.' || c.relname
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r','p','v','S')
       and pg_get_userbyid(c.relowner) = 'supabase_admin'
       and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
   ) t")"

if [[ -n "$misowned" ]]; then
  echo "prospect: FAILED - still owned by supabase_admin, migrations will not be able to replace: ${misowned}" >&2
  exit 1
fi

echo "prospect: role logins, JWT settings, extensions, timeouts and object ownership applied"
