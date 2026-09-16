-- Take EXECUTE on client_icp_tag_counts_v1 away from PUBLIC.
--
-- WHAT WENT WRONG. 20260916150000 created the function SECURITY DEFINER and
-- granted it to service_role, but never revoked the default grant PostgreSQL
-- gives every new function to PUBLIC. The CI migration guard caught it on run
-- #185 and refused to build the image, which is the guard doing its job: a
-- SECURITY DEFINER function runs as its owner, so a PUBLIC grant on this one
-- would let any authenticated browser session pass a client id and read that
-- client's ICP link counts - a map of who is being targeted for whom, and by
-- how much - without going anywhere near the application's authorization.
--
-- WHY THIS IS A SECOND FILE RATHER THAN A FIX TO THE FIRST. The same guard
-- holds migration files immutable once they are in a pushed commit, and says
-- so: "add a new timestamped forward migration instead". 20260916150000 is on
-- origin/main, so editing it would trade one guard failure for another. This is
-- the forward migration.
--
-- THE GAP BETWEEN THE TWO FILES IS REAL AND IS ABOUT A SECOND LONG. migrate.sh
-- runs one transaction per file in name order, so between 150000 committing and
-- this file committing the function does carry its default PUBLIC grant. Two
-- things bound that. It is sub-second, in the same migrate.sh invocation, on a
-- server where both files land before the candidate container starts. And
-- PostgREST cannot expose a function it has not seen: the schema cache is
-- reloaded after migrations, so for the whole of that window there is no route
-- through which anon or authenticated could call it. Neither of those would
-- excuse leaving the grant in place; they are why fixing it forward is safe
-- rather than why it did not need fixing.
--
-- The function is re-stated with CREATE OR REPLACE rather than only revoked, so
-- this file describes the whole object it is securing - and so that the guard
-- reads a SECURITY DEFINER definition and its revokes in one place, which is
-- the invariant it exists to enforce. The body is byte-for-byte what
-- 20260916150000 created; replacing it changes nothing but the grants.
-- ---------------------------------------------------------------------------

create or replace function public.client_icp_tag_counts_v1(p_client_id text)
returns table (tag_id text, prospect_count bigint, company_count bigint)
language sql
stable
security definer
set search_path to 'public'
set statement_timeout to '8s'
as $$
  select t.id,
    (select count(*) from public.prospect_tag_links l where l.tag_id = t.id),
    (select count(*) from public.company_tag_links l where l.tag_id = t.id)
  from public.prospect_tags t
  -- Client-scoped only. An agency-wide tag belongs to no ICP, so counting one
  -- here would attribute it to whichever client happened to ask.
  where t.client_id = p_client_id;
$$;

revoke execute on function public.client_icp_tag_counts_v1(text) from public, anon, authenticated;
grant execute on function public.client_icp_tag_counts_v1(text) to service_role;

-- ---------------------------------------------------------------------------
-- Asked of the catalogue, not of this file's own text: the question is who can
-- execute it now, and CREATE OR REPLACE does not reset privileges, so a stale
-- grant from the first file would survive a revoke that named the wrong
-- signature and nothing here would notice.
-- Read through aclexplode rather than has_function_privilege, because PUBLIC is
-- the grantee that matters most here and is not a role: has_function_privilege
-- ('public', ...) raises "role public does not exist". aclexplode reports the
-- PUBLIC grant as grantee 0, which is the only way to see it.
do $$
declare
  v_reachable text;
begin
  select string_agg(coalesce(nullif(g.grantee::regrole::text, '-'), 'PUBLIC'), ', ')
    into v_reachable
    from pg_proc p,
         lateral aclexplode(p.proacl) g
   where p.oid = 'public.client_icp_tag_counts_v1(text)'::regprocedure
     and g.privilege_type = 'EXECUTE'
     and (g.grantee = 0 or g.grantee::regrole::text in ('anon', 'authenticated'));
  if v_reachable is not null then
    raise exception 'client_icp_tag_counts_v1 is still executable by %', v_reachable;
  end if;

  -- And the application can still reach it. A revoke that over-reached would
  -- leave the ICPs screen permanently without counts, which is a silent
  -- degradation rather than a failure - exactly the kind that goes unnoticed.
  if not has_function_privilege('service_role', 'public.client_icp_tag_counts_v1(text)', 'execute') then
    raise exception 'service_role can no longer execute client_icp_tag_counts_v1; the application would lose the ICP counts';
  end if;
end $$;
