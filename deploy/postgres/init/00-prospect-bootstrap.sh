#!/bin/bash
# Runs once, on first initialisation of an empty data directory.
#
# Idempotent — safe to re-run against a live database, which is what
# scripts/restore.sh does after a recovery:
#   docker compose exec -T db bash /docker-entrypoint-initdb.d/zz-00-prospect-bootstrap.sh
set -euo pipefail

DB="${POSTGRES_DB:-postgres}"

# Connect as supabase_admin, NOT postgres.
#
# In supabase/postgres the `postgres` role is deliberately not a superuser —
# supabase_admin is. `ALTER ROLE <other> SET ...` requires superuser, so running
# this as postgres fails partway through, and with ON_ERROR_STOP the rest of the
# file silently never executes: no pg_trgm, no timeouts, and a stack that only
# breaks later during migration.
#
# Local connections use trust auth during init, so no password is needed.
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

echo "prospect: role logins, JWT settings, extensions and timeouts applied"
