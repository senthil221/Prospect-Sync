-- Assert the import worker has its own login role before the release lands.
--
-- The role itself is created by postgres/init/00-prospect-bootstrap.sh, not
-- here, for two reasons. It needs POSTGRES_PASSWORD, which a migration file
-- cannot read; and `alter role <other> set ...` and `alter role ... connection
-- limit` require superuser, while migrate.sh connects as postgres, which is
-- deliberately not a superuser in the supabase/postgres image. The bootstrap
-- runs as supabase_admin and is idempotent, so `docker compose exec -T db bash
-- -s < postgres/init/00-prospect-bootstrap.sh` is the step that creates it.
--
-- This migration is the guard: docker-compose.yml now points the worker at
-- PGUSER=prospect_import_worker, so a deploy that applies migrations without
-- re-running the bootstrap would leave the worker unable to log in at all.
-- Failing here, before the new compose file starts the worker, is the loud
-- version of that. 20260826031412 does exactly this for prospect_importer.
--
-- WHY THE WORKER MOVED OFF authenticator
--
-- It shared the login role with PostgREST. Two consequences:
--
--   * Per-role connection limits could not separate the import pool from the
--     interactive pool, because there was only one role to limit. Section 8.3
--     of the plan names this as the thing blocking pool isolation.
--   * authenticator is a member of service_role, so the worker could SET ROLE
--     service_role and act with the whole database's authority. It never needed
--     more than prospect_importer: usage on the prospect_import schema,
--     select/insert/delete on staged_rows, and execute on
--     process_staged_batch_v1.
--
-- WHAT THIS DOES NOT FIX
--
-- The worker also calls claim_next_prospect_import_v1, heartbeat_prospect_
-- import_v1 and retry_prospect_import_v1 over PostgREST with the service-role
-- key, and those still draw on the interactive pool. They are three small,
-- infrequent RPCs rather than the bulk path, so they are left alone here; the
-- dedicated operations worker in Release 2 is where that queue moves off the
-- shared pool entirely.

begin;

do $$
declare
  v_missing text[] := array[]::text[];
  v_has_service_role boolean;
  v_conn_limit integer;
begin
  if not exists (select 1 from pg_roles where rolname = 'prospect_import_worker') then
    raise exception using
      message = 'prospect_import_worker role is missing',
      detail = 'docker-compose.yml points the import worker at PGUSER=prospect_import_worker, so it cannot connect until this role exists.',
      hint = 'Run: docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh';
  end if;

  if not exists (select 1 from pg_roles where rolname = 'prospect_import_worker' and rolcanlogin) then
    v_missing := v_missing || 'it cannot log in';
  end if;

  if not exists (
    select 1 from pg_auth_members am
    join pg_roles granted on granted.oid = am.roleid
    join pg_roles member on member.oid = am.member
    where member.rolname = 'prospect_import_worker' and granted.rolname = 'prospect_importer'
  ) then
    v_missing := v_missing || 'it is not a member of prospect_importer, so the COPY into staged_rows will be denied';
  end if;

  -- The point of the separation: this must never come back.
  select exists (
    select 1 from pg_auth_members am
    join pg_roles granted on granted.oid = am.roleid
    join pg_roles member on member.oid = am.member
    where member.rolname = 'prospect_import_worker' and granted.rolname = 'service_role'
  ) into v_has_service_role;
  if v_has_service_role then
    v_missing := v_missing || 'it is a member of service_role, which defeats the separation';
  end if;

  -- An unlimited worker role can still exhaust the cluster, which is the thing
  -- the interactive pool is being protected from.
  select rolconnlimit into v_conn_limit from pg_roles where rolname = 'prospect_import_worker';
  if v_conn_limit is null or v_conn_limit <= 0 then
    v_missing := v_missing || 'it has no CONNECTION LIMIT';
  end if;

  select rolconnlimit into v_conn_limit from pg_roles where rolname = 'authenticator';
  if v_conn_limit is null or v_conn_limit <= 0 then
    v_missing := v_missing || 'authenticator has no CONNECTION LIMIT, so the interactive pool is unbounded';
  end if;

  if cardinality(v_missing) > 0 then
    raise exception using
      message = 'prospect_import_worker is not correctly configured',
      detail = array_to_string(v_missing, '; '),
      hint = 'Re-run: docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh';
  end if;
end
$$;

-- The interactive listing's ceiling comes down from 20s to 10s.
--
-- Section 8.2 budgets 10s for listings and interactive counts, and says to lower
-- a function's timeout only once its shape has passed its gate. It has:
-- 20260902000060 replaced the materialised match set with two early-stopping
-- scans, and the unfiltered page went from 952 ms to 4.6 ms with the worst
-- filtered shape measured at about 1.4 s.
--
-- This matters more than it looks, because cancellation does not work. Measured
-- on this deployment, PostgREST does not cancel the statement when the browser
-- disconnects: an export abandoned after 2.1 s ran the full 7.9 s. So the
-- statement timeout is not a backstop for a stuck query -- it is the ONLY thing
-- that decides how long an abandoned request keeps its pool connection. Halving
-- it halves the worst case, and every measured shape has an order of magnitude
-- of headroom under it.
alter function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb)
  set statement_timeout = '10s';

commit;
