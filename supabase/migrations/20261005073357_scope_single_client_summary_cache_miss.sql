-- A stale or absent client-summary cache used to make the client detail route
-- rebuild every client's counts and replace the shared cache, even though the
-- caller asked for one client. The current client_summaries view is explicitly
-- inlinable, so its id predicate reaches the membership scans. A read-only
-- production comparison on 2026-10-05 found exact count-object parity. In one
-- bounded same-session comparison, the all-client object took 2,206 ms while
-- the selected client took 734 ms and a smaller client took 301 ms. These are
-- warm observations, not a p95 or cold-cache guarantee. A separate canonical
-- aggregate was rejected because it was slower than the scoped view.
--
-- The directory path is unchanged: a valid global cache is still reused and
-- an all-client miss still rebuilds and replaces that global row. A
-- single-client miss computes only that client and never creates, replaces, or
-- deletes the global cache. Existing invalidation and the five-minute ceiling
-- remain unchanged; this migration does not claim to close their documented
-- commit-visibility window.
set local lock_timeout = '5s';

create or replace function public.client_summaries_v1(p_client_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  v_version bigint := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  v_cache public.client_summary_cache%rowtype;
  v_counts jsonb;
  v_cache_valid boolean := false;
begin
  select * into v_cache from public.client_summary_cache where id;
  v_cache_valid := found
    and v_cache.version = v_version
    and v_cache.computed_at > now() - interval '5 minutes'
    and not exists (select 1 from public.clients c where not (v_cache.counts ? c.id));

  if v_cache_valid then
    v_counts := v_cache.counts;
  elsif p_client_id is not null then
    -- client_summaries' NOT MATERIALIZED CTEs let this predicate reach the
    -- membership scans. Do not publish a partial object as the global cache.
    select coalesce(jsonb_object_agg(s.id, jsonb_build_object(
             'prospect_count', s.prospect_count,
             'icp_verified_count', s.icp_verified_count,
             'blocked_count', s.blocked_count,
             'company_count', s.company_count)), '{}'::jsonb)
      into v_counts
      from public.client_summaries s
     where s.id = p_client_id;
  else
    select coalesce(jsonb_object_agg(s.id, jsonb_build_object(
             'prospect_count', s.prospect_count,
             'icp_verified_count', s.icp_verified_count,
             'blocked_count', s.blocked_count,
             'company_count', s.company_count)), '{}'::jsonb)
      into v_counts
      from public.client_summaries s;
    insert into public.client_summary_cache (id, version, computed_at, counts)
    values (true, v_version, now(), v_counts)
    on conflict (id) do update
      set version = excluded.version,
          computed_at = excluded.computed_at,
          counts = excluded.counts;
  end if;

  -- Metadata is deliberately live even on a cache hit. New clients and unknown
  -- ids therefore retain their existing zero-row/zero-count behavior.
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id,
             'name', c.name,
             'created_at', c.created_at,
             'list_count', (select count(*)::integer from public.lists l where l.client_id = c.id),
             'prospect_count', coalesce((v_counts->c.id->>'prospect_count')::integer, 0),
             'icp_verified_count', coalesce((v_counts->c.id->>'icp_verified_count')::integer, 0),
             'blocked_count', coalesce((v_counts->c.id->>'blocked_count')::integer, 0),
             'company_count', coalesce((v_counts->c.id->>'company_count')::integer, 0),
             'folder_id', c.folder_id,
             'archived_at', c.archived_at)
           order by c.name), '[]'::jsonb)
      from public.clients c
     where p_client_id is null or c.id = p_client_id);
end;
$$;

revoke execute on function public.client_summaries_v1(text) from public, anon, authenticated;
grant execute on function public.client_summaries_v1(text) to service_role;

do $$
declare v_definition text := lower(pg_get_functiondef('public.client_summaries_v1(text)'::regprocedure));
begin
  if position('elsif p_client_id is not null' in v_definition) = 0
     or position('where s.id = p_client_id' in v_definition) = 0
     or position('insert into public.client_summary_cache' in v_definition) = 0 then
    raise exception 'client_summaries_v1 did not retain the scoped-miss/global-fill split: %', v_definition;
  end if;
  if has_function_privilege('anon', 'public.client_summaries_v1(text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.client_summaries_v1(text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.client_summaries_v1(text)', 'EXECUTE') then
    raise exception 'client_summaries_v1 grants widened or service access was lost';
  end if;
end $$;
