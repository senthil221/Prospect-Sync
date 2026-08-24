#!/bin/bash
# Runs once, on first initialisation of an empty data directory.
#
# The supabase/postgres image already creates the Supabase roles, but it does
# not give them the password from your .env. Auth, PostgREST, Storage and
# postgres-meta all connect as those roles, so without this they cannot log in.
#
# Everything here is idempotent and safe to re-run by hand:
#   docker compose exec -T db bash < deploy/postgres/init/00-prospect-bootstrap.sh
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username postgres --dbname "${POSTGRES_DB:-postgres}" <<-EOSQL
	-- Service role logins -------------------------------------------------
	do \$\$
	declare
	  r text;
	begin
	  foreach r in array array[
	    'authenticator',
	    'supabase_auth_admin',
	    'supabase_storage_admin',
	    'supabase_functions_admin',
	    'supabase_admin',
	    'pgbouncer'
	  ] loop
	    if exists (select 1 from pg_roles where rolname = r) then
	      execute format('alter role %I with login password %L', r, '${POSTGRES_PASSWORD}');
	    end if;
	  end loop;
	end
	\$\$;

	-- JWT settings PostgREST and legacy helpers read from the database ------
	alter database "${POSTGRES_DB:-postgres}" set "app.settings.jwt_secret" to '${JWT_SECRET}';
	alter database "${POSTGRES_DB:-postgres}" set "app.settings.jwt_exp" to '${JWT_EXP:-3600}';

	-- Extensions this application needs ------------------------------------
	create extension if not exists pg_trgm;
	create extension if not exists pg_stat_statements;

	-- Guard rails ----------------------------------------------------------
	-- The Prospect Sync RPCs set their own statement_timeout. This is the
	-- backstop for everything else that arrives through PostgREST, so one bad
	-- ad-hoc query cannot pin a vCPU for an hour.
	alter role authenticator set statement_timeout = '120s';
	alter role authenticator set idle_in_transaction_session_timeout = '60s';
	alter role authenticator set lock_timeout = '10s';

	-- Studio and psql sessions get more rope, but not unlimited.
	alter role postgres set idle_in_transaction_session_timeout = '300s';
EOSQL

echo "prospect: role passwords, JWT settings, extensions and timeouts applied"
