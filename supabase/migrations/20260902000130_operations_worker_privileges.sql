-- Grant the operations worker exactly what it needs to build a result set, and
-- assert it cannot do anything else.
--
-- Section 9.1 asks for a dedicated worker with its own process, pool and login
-- role, reusing the import worker's queue primitives. 20260902000120 built the
-- primitives; this is the privilege half.
--
-- WHAT LEAST PRIVILEGE MEANS HERE. The functions in prospect_results are
-- SECURITY DEFINER, so they run as their owner and the caller needs no
-- privilege on the tables underneath. That is what makes this worth doing
-- properly: prospect_operator gets EXECUTE on five functions and nothing else,
-- so the worker can claim work, fill a batch, fail a set, expire old ones and
-- report storage - and it cannot read a single prospect, company or stored id
-- directly. Compare the import worker before 20260902000090, which reached the
-- database as `authenticator` and could therefore SET ROLE service_role.
--
-- The application's own entry points are deliberately NOT granted:
-- request_set_v1, page_v1 and status_v1 belong to a signed-in request, and a
-- background worker has no business answering for a user.
--
-- Retention is the worker's job too, so it gets the two expiry functions. A TTL
-- that nothing ever runs is not a TTL.
--
-- The roles themselves are created by postgres/init/00-prospect-bootstrap.sh,
-- for the same reasons as 20260902000090: a migration cannot read
-- POSTGRES_PASSWORD, and ALTER ROLE ... SET and CONNECTION LIMIT need superuser
-- while migrate.sh connects as postgres, which deliberately is not one. This
-- file fails the release if the bootstrap has not been re-run, rather than
-- letting a worker start that cannot log in.

-- EDITED IN PLACE 2026-09-03, after this migration had already been applied.
-- The assertion blocks below accumulated their messages with
-- `v_problems := v_problems || 'text'`, which is not array_append: an untyped
-- literal on the right makes PostgreSQL resolve || as array_cat, and the block
-- dies with "malformed array literal" instead of reporting what it found. Those
-- lines only run when an assertion fails, so every passing deploy hid it. See
-- 20260902000170 for the same note at the point it was first diagnosed.
-- migrate.sh keys supabase_migrations.schema_migrations on the filename version
-- alone and does not checksum contents, so this edit does not re-run here; it
-- exists for environments bootstrapped from scratch, which replay this file.

begin;

do $$
declare
  v_problems text[] := array[]::text[];
  v_conn_limit integer;
begin
  if not exists (select 1 from pg_roles where rolname = 'prospect_operator') then
    raise exception using
      message = 'prospect_operator role is missing',
      detail = 'The operations worker assumes this capability role; without it the grants below have no subject.',
      hint = 'Run: docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'prospect_ops_worker') then
    raise exception using
      message = 'prospect_ops_worker role is missing',
      detail = 'docker-compose.yml points the operations worker at PGUSER=prospect_ops_worker.',
      hint = 'Run: docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh';
  end if;

  if not exists (select 1 from pg_roles where rolname = 'prospect_ops_worker' and rolcanlogin) then
    v_problems := array_append(v_problems, 'prospect_ops_worker cannot log in');
  end if;

  if not exists (
    select 1 from pg_auth_members am
    join pg_roles granted on granted.oid = am.roleid
    join pg_roles member on member.oid = am.member
    where member.rolname = 'prospect_ops_worker' and granted.rolname = 'prospect_operator'
  ) then
    v_problems := array_append(v_problems, 'prospect_ops_worker is not a member of prospect_operator, so it can do nothing');
  end if;

  -- The separation this release exists for.
  if exists (
    select 1 from pg_auth_members am
    join pg_roles granted on granted.oid = am.roleid
    join pg_roles member on member.oid = am.member
    where member.rolname = 'prospect_ops_worker' and granted.rolname = 'service_role'
  ) then
    v_problems := array_append(v_problems, 'prospect_ops_worker is a member of service_role, which defeats the separation');
  end if;

  select rolconnlimit into v_conn_limit from pg_roles where rolname = 'prospect_ops_worker';
  if v_conn_limit is null or v_conn_limit <= 0 then
    v_problems := array_append(v_problems, 'prospect_ops_worker has no CONNECTION LIMIT');
  end if;

  if cardinality(v_problems) > 0 then
    raise exception using
      message = 'prospect_ops_worker is not correctly configured',
      detail = array_to_string(v_problems, '; '),
      hint = 'Re-run: docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh';
  end if;
end
$$;

-- Exactly five functions, and the schema usage needed to reach them.
grant usage on schema prospect_results to prospect_operator;
grant execute on function prospect_results.claim_next_v1(text, integer) to prospect_operator;
grant execute on function prospect_results.build_batch_v1(uuid, integer) to prospect_operator;
grant execute on function prospect_results.fail_set_v1(uuid, text) to prospect_operator;
grant execute on function prospect_results.expire_sets_v1() to prospect_operator;
grant execute on function prospect_results.usage_v1() to prospect_operator;

-- Retention for durable filter sets belongs to the same worker.
grant usage on schema prospect_filters to prospect_operator;
grant execute on function prospect_filters.expire_sets_v1() to prospect_operator;
grant execute on function prospect_filters.usage_v1() to prospect_operator;

-- Prove the posture in the same transaction that grants it: what it can do, and
-- more importantly what it still cannot.
do $$
declare
  v_failures text[] := array[]::text[];
begin
  if not has_function_privilege('prospect_operator', 'prospect_results.claim_next_v1(text, integer)', 'execute') then
    v_failures := array_append(v_failures, 'cannot claim work');
  end if;
  if not has_function_privilege('prospect_operator', 'prospect_results.build_batch_v1(uuid, integer)', 'execute') then
    v_failures := array_append(v_failures, 'cannot build a batch');
  end if;
  if not has_function_privilege('prospect_operator', 'prospect_filters.expire_sets_v1()', 'execute') then
    v_failures := array_append(v_failures, 'cannot run retention');
  end if;

  -- The application's entry points stay the application's.
  if has_function_privilege('prospect_operator', 'prospect_results.page_v1(uuid, text, integer, integer)', 'execute') then
    v_failures := array_append(v_failures, 'can page a result set, which belongs to a signed-in request');
  end if;
  if has_function_privilege('prospect_operator', 'prospect_results.request_set_v1(text, text, text, text, jsonb, text, jsonb, interval)', 'execute') then
    v_failures := array_append(v_failures, 'can request a result set on a user''s behalf');
  end if;

  -- And it reads nothing directly. SECURITY DEFINER is what makes this possible.
  if has_table_privilege('prospect_operator', 'public.prospect_index', 'select') then
    v_failures := array_append(v_failures, 'can read prospect_index directly');
  end if;
  if has_table_privilege('prospect_operator', 'prospect_results.result_set_items', 'select') then
    v_failures := array_append(v_failures, 'can read stored result ids directly');
  end if;

  if cardinality(v_failures) > 0 then
    raise exception 'prospect_operator privileges are wrong: %', array_to_string(v_failures, '; ');
  end if;
end
$$;

commit;
