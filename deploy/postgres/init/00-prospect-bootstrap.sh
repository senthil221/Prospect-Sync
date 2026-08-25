#!/bin/bash
# Runs once, on first initialisation of an empty data directory.
#
# Idempotent — safe to re-run against a live database, which is what
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
# In supabase/postgres the `postgres` role is deliberately not a superuser —
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

	-- The bulk import worker connects as authenticator, then assumes this
	-- narrowly-scoped NOLOGIN role. Recreate role membership after a logical
	-- disaster recovery where database objects survive but cluster roles do not.
	do \$\$
	begin
	  if not exists (select 1 from pg_roles where rolname = 'prospect_importer') then
	    create role prospect_importer nologin noinherit;
	  end if;
	end
	\$\$;
	grant prospect_importer to authenticator;

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

	-- Application objects belong to postgres ---------------------------------
	-- scripts/migrate.sh connects as postgres, and CREATE OR REPLACE FUNCTION
	-- requires ownership. Anything created through Studio or a psql session
	-- opened as supabase_admin is therefore owned by the wrong role, and the
	-- next migration that touches it fails the release with
	-- "must be owner of function ...". That is not hypothetical: it is what
	-- blocked the 20260826040000 release.
	--
	-- So hand ownership of the application's own public objects back to
	-- postgres on every deploy. Extension members are excluded — pg_trgm and
	-- unaccent are installed by supabase_admin and must stay that way — which
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
  echo "prospect: FAILED — extensions still missing: ${missing}" >&2
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
  echo "prospect: FAILED — still owned by supabase_admin, migrations will not be able to replace: ${misowned}" >&2
  exit 1
fi

echo "prospect: role logins, JWT settings, extensions, timeouts and object ownership applied"
