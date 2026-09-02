-- Give the application a door to result sets, and give the worker a way to run
-- a frozen operation.
--
-- 20260902000120 built durable result sets and 20260902000140 built idempotent,
-- frozen operations. Both are deployed and neither is reachable: their storage
-- lives in private schemas, PGRST_DB_SCHEMAS is `public`, and the only public
-- wrappers written so far were for filter sets and for enqueue/freeze/status.
-- So "all matching" still resolves its ids at execution time - the exact
-- widening 9.3 exists to prevent - and a capped count is still the only answer
-- a user can get to "how many actually match?".
--
-- Three things are missing, and this migration is all three:
--
-- 1. THE DOOR. public.request_result_set_v1 / result_set_status_v1 /
--    result_set_page_v1, so a request path can ask for a set, watch it build,
--    and read it back. Same pattern as 20260902000110's filter-set wrappers:
--    SECURITY DEFINER, fixed search_path, service_role only.
--
-- 2. THE VERSION VECTOR IS TAKEN HERE, NOT IN THE BROWSER. The wrapper computes
--    data_versions_v1 itself when the caller passes none, so `stale` on a reused
--    set compares against the world as it is now rather than against whatever
--    the tab happened to be holding. A client-supplied vector could only ever
--    make a stale set look fresh.
--
-- 3. THE RUN STEP. prospect_operations already claims, freezes, batches and
--    marks applied - but nothing performs the mutation. apply_batch_v1 is that
--    missing piece: it takes the next unapplied ids and calls the same four
--    RPCs the interactive route calls, then marks them applied IN THE SAME
--    TRANSACTION, which is what 20260902000140 asked for in so many words:
--    "Called in the same transaction as the mutation it describes, so the two
--    cannot disagree."
--
-- WHY THE WORKER RUNS IT AND THE REQUEST DOES NOT. A frozen selection of
-- 250,000 ids is 500 batches. Doing that inside the HTTP request would hold an
-- interactive admission slot for minutes and die on the first dropped
-- connection - and, as 1C measured, PostgREST would not even cancel it. The
-- worker holds a lease, makes progress in bounded transactions, and resumes
-- where it stopped, because `applied_at` says which ids are already done.
--
-- THE WORKER STILL CANNOT READ A PROSPECT. apply_batch_v1 is SECURITY DEFINER,
-- so prospect_operator executes it without any privilege on prospect_index,
-- clients or client_prospects. The negative assertions at the bottom prove it,
-- the same way 20260902000130 proved the result-set role.

begin;

-- 1. The application's door to result sets ---------------------------------

create or replace function public.request_result_set_v1(
  p_owner_id text,
  p_entity_type text,
  p_client_scope text,
  p_search text,
  p_filters jsonb,
  p_content_hash text,
  p_version_vector jsonb default null
)
returns table(set_id uuid, status text, row_count bigint, reused boolean, stale boolean)
language sql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '15s'
as $function$
  select * from prospect_results.request_set_v1(
    p_owner_id, p_entity_type, coalesce(p_client_scope, ''), coalesce(p_search, ''),
    coalesce(p_filters, '[]'::jsonb), p_content_hash,
    -- Taken here on purpose. See the header: a caller-supplied vector could
    -- only ever make a stale set look fresh.
    coalesce(p_version_vector, public.data_versions_v1(array[p_entity_type])));
$function$;

create or replace function public.result_set_status_v1(
  p_set_id uuid,
  p_owner_id text,
  p_version_vector jsonb default null
)
returns table(status text, row_count bigint, stale boolean, frozen_at timestamptz, version_vector jsonb, error text)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '10s'
as $function$
declare
  v_entity text;
  v_vector jsonb := p_version_vector;
begin
  -- status_v1 reports `stale` by comparing against the vector it is handed, so
  -- a null one makes it permanently false - the caller would poll a set to
  -- 'ready' and never learn the data had moved underneath it. Take the live
  -- vector here instead, for the same reason the request wrapper does.
  if v_vector is null then
    select rs.entity_type into v_entity from prospect_results.result_sets rs
    where rs.id = p_set_id and rs.owner_id = p_owner_id and rs.expires_at > now();
    if v_entity is not null then
      v_vector := public.data_versions_v1(array[v_entity]);
    end if;
    -- A set that was not found stays status_v1's decision to announce, so that
    -- "not yours" and "never existed" keep answering identically.
  end if;
  return query select * from prospect_results.status_v1(p_set_id, p_owner_id, v_vector);
end;
$function$;

create or replace function public.result_set_page_v1(
  p_set_id uuid,
  p_owner_id text,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(entity_id text, ordinal bigint)
language sql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '15s'
as $function$
  select * from prospect_results.page_v1(p_set_id, p_owner_id, p_limit, p_offset);
$function$;

revoke execute on function public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb) from public, anon, authenticated;
revoke execute on function public.result_set_status_v1(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public.result_set_page_v1(uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb) to service_role;
grant execute on function public.result_set_status_v1(uuid, text, jsonb) to service_role;
grant execute on function public.result_set_page_v1(uuid, text, integer, integer) to service_role;


-- 2. Accumulating a result across many batches -----------------------------

-- Every bulk RPC answers a flat object of counters - {added, alreadyPresent,
-- blocked, queued} for a push, {updated} for the rest. A job that runs in 500
-- batches has to end up with one answer, so numbers add and anything else takes
-- the newer value. Nothing here assumes a particular shape, so a fifth action
-- with different counters accumulates correctly without touching this.
create or replace function prospect_operations.merge_result_v1(p_current jsonb, p_batch jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog
as $function$
  select coalesce((
    select jsonb_object_agg(merged.key, merged.value)
    from (
      select
        coalesce(current_entry.key, batch_entry.key) as key,
        case
          when jsonb_typeof(coalesce(current_entry.value, 'null'::jsonb)) = 'number'
           and jsonb_typeof(coalesce(batch_entry.value, 'null'::jsonb)) = 'number'
            then to_jsonb(current_entry.value::numeric + batch_entry.value::numeric)
          else coalesce(batch_entry.value, current_entry.value)
        end as value
      from jsonb_each(coalesce(p_current, '{}'::jsonb)) as current_entry
      full outer join jsonb_each(coalesce(p_batch, '{}'::jsonb)) as batch_entry
        on batch_entry.key = current_entry.key
    ) merged
  ), '{}'::jsonb);
$function$;


-- 3. The run step -----------------------------------------------------------

-- One batch of a frozen operation: mutate, mark applied, accumulate the answer,
-- all in one transaction.
--
-- The ids come from operation_job_items, which were written once at freeze time
-- and are never re-resolved. That is the whole point: the search and filters are
-- not consulted here at all, so an import landing mid-run cannot widen the
-- operation. Compare the interactive path, which passes p_search/p_filters
-- straight through and gets whatever matches at execution time.
create or replace function prospect_operations.apply_batch_v1(
  p_job_id uuid,
  p_batch_size integer default 500,
  p_lease_seconds integer default 300
)
returns table(applied bigint, total_items bigint, applied_items bigint, done boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '120s'
as $function$
declare
  v_job prospect_operations.operation_jobs%rowtype;
  v_ids text[];
  v_batch jsonb;
  v_marked bigint;
  v_date date;
begin
  select * into v_job from prospect_operations.operation_jobs j where j.id = p_job_id;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
  -- Anything already finished, failed or not yet frozen is not ours to run.
  -- Returning rather than raising keeps a worker that claimed a job which
  -- completed underneath it from recording a spurious failure.
  if v_job.status not in ('frozen', 'running') then
    return query select 0::bigint, v_job.total_items, v_job.applied_items, true;
    return;
  end if;

  select array_agg(batch.entity_id) into v_ids
  from prospect_operations.next_batch_v1(p_job_id, p_batch_size) as batch;

  if v_ids is null or cardinality(v_ids) = 0 then
    -- Frozen over an empty selection, or every item already applied. Close it
    -- rather than leaving a job that is claimable forever.
    update prospect_operations.operation_jobs
    set status = 'completed', completed_at = now(), worker_id = null, lease_expires_at = null
    where id = p_job_id and status <> 'completed';
    return query select 0::bigint, v_job.total_items, v_job.applied_items, true;
    return;
  end if;

  if v_job.entity_type <> 'prospect' then
    raise exception 'Only prospect operations can be applied here, not %', v_job.entity_type
      using errcode = '22023';
  end if;

  -- The same four functions the interactive route calls, given explicit ids.
  -- p_search and p_filters are deliberately empty: the selection is frozen.
  if v_job.action = 'push' then
    v_batch := public.push_prospects_to_client_v1(
      p_client_id => v_job.client_scope,
      p_search => '', p_filters => '[]'::jsonb,
      p_source_client_id => nullif(v_job.payload ->> 'sourceClientId', ''),
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action in ('set_icp_verified', 'clear_icp_verified') then
    v_batch := public.set_icp_verified_v1(
      p_client_id => v_job.client_scope,
      p_verified => (v_job.action = 'set_icp_verified'),
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action = 'set_date_contacted' then
    -- Clearing the date is a legitimate request, so a missing key and an
    -- explicit null are different things and only the first is an error.
    if not (v_job.payload ? 'dateContacted') then
      raise exception 'This operation has no Date Contacted to apply' using errcode = '22023';
    end if;
    v_date := case
      when jsonb_typeof(v_job.payload -> 'dateContacted') = 'null' then null
      else (v_job.payload ->> 'dateContacted')::date
    end;
    v_batch := public.set_client_date_contacted_v1(
      p_client_id => v_job.client_scope,
      p_date_contacted => v_date,
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action = 'remove' then
    v_batch := public.remove_prospects_from_client_v2(
      p_client_id => v_job.client_scope,
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  else
    raise exception 'Unsupported operation action %', v_job.action using errcode = '22023';
  end if;

  -- Same transaction as the mutation above, so progress and reality cannot
  -- disagree: either both happened or neither did.
  v_marked := prospect_operations.mark_applied_v1(p_job_id, v_ids);

  -- Progress extends the lease, exactly as build_batch_v1 does for result sets:
  -- a job of 250,000 ids is 500 batches and will outlive any fixed lease taken
  -- at claim time. Without this a second worker could reclaim a job that is
  -- still running and apply the same batch twice. mark_applied_v1 has already
  -- nulled the lease if this batch finished the job, so only a job with work
  -- left gets a new one.
  update prospect_operations.operation_jobs j
  set result = prospect_operations.merge_result_v1(j.result, v_batch),
      lease_expires_at = case
        when j.lease_expires_at is null then null
        else now() + make_interval(secs => greatest(30, p_lease_seconds))
      end
  where j.id = p_job_id;

  select * into v_job from prospect_operations.operation_jobs j where j.id = p_job_id;
  return query select v_marked, v_job.total_items, v_job.applied_items, (v_job.status = 'completed');
end;
$function$;

revoke execute on function prospect_operations.apply_batch_v1(uuid, integer, integer) from public, anon, authenticated;
revoke execute on function prospect_operations.merge_result_v1(jsonb, jsonb) from public, anon, authenticated;
grant execute on function prospect_operations.apply_batch_v1(uuid, integer, integer) to service_role;


-- 3b. Status has to carry the answer, not just the progress ----------------

-- 20260902000140's status_v1 reports how far a job has got but not what it did,
-- which was fine while the request performing the mutation also answered it. A
-- background job has no such request: the browser gets a job id, polls, and the
-- only place the counts can come from is here. Dropped rather than replaced
-- because the return type changes; nothing calls it yet, so this costs nothing.
drop function if exists public.operation_status_v1(uuid, text, jsonb);
create or replace function public.operation_status_v1(
  p_job_id uuid,
  p_actor text,
  p_version_vector jsonb default null
)
returns table(status text, total_items bigint, applied_items bigint, excluded_count bigint,
              stale boolean, frozen_at timestamptz, error text, result jsonb)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_operations
set statement_timeout = '10s'
as $function$
declare
  v_result jsonb;
begin
  -- Read under the same (id, actor) predicate status_v1 uses, so a job that is
  -- not the caller's cannot leak its result through this column.
  select j.result into v_result from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor;
  return query
  select base.status, base.total_items, base.applied_items, base.excluded_count,
         base.stale, base.frozen_at, base.error, v_result
  from prospect_operations.status_v1(p_job_id, p_actor, p_version_vector) as base;
end;
$function$;

revoke execute on function public.operation_status_v1(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.operation_status_v1(uuid, text, jsonb) to service_role;


-- 4. What the operations worker may do -------------------------------------

-- Exactly four verbs: take the next job, run a batch of it, give up on it, and
-- run retention. Not next_batch_v1 or mark_applied_v1 - those are reachable
-- only from inside apply_batch_v1, which keeps the mutation and the progress
-- record in one transaction by construction rather than by convention.
grant usage on schema prospect_operations to prospect_operator;
grant execute on function prospect_operations.claim_next_v1(text, integer) to prospect_operator;
grant execute on function prospect_operations.apply_batch_v1(uuid, integer, integer) to prospect_operator;
grant execute on function prospect_operations.fail_v1(uuid, text) to prospect_operator;
grant execute on function prospect_operations.expire_jobs_v1() to prospect_operator;

-- 20260902000140 granted the worker next_batch_v1 and mark_applied_v1 directly,
-- anticipating a worker that would take ids, mutate, and mark them applied as
-- three calls. It is a narrower privilege to take them away: with apply_batch_v1
-- doing all three in one transaction, a worker holding these separately could
-- only ever do something wrong with them - mark a batch applied without
-- mutating it, and silently drop those rows from the operation. This migration's
-- own assertion below is what noticed the grants were still there.
revoke execute on function prospect_operations.next_batch_v1(uuid, integer) from prospect_operator;
revoke execute on function prospect_operations.mark_applied_v1(uuid, text[]) from prospect_operator;


-- 5. Prove the posture in the transaction that grants it -------------------

do $$
declare
  v_failures text[] := array[]::text[];
  v_allowed text[] := array[
    'prospect_operations.claim_next_v1(text, integer)',
    'prospect_operations.apply_batch_v1(uuid, integer, integer)',
    'prospect_operations.fail_v1(uuid, text)',
    'prospect_operations.expire_jobs_v1()'
  ];
  -- Reachable only from inside apply_batch_v1. If the worker could call these
  -- directly it could mark ids applied without mutating them.
  v_denied text[] := array[
    'prospect_operations.next_batch_v1(uuid, integer)',
    'prospect_operations.mark_applied_v1(uuid, text[])',
    'prospect_operations.enqueue_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[], interval)',
    'prospect_operations.freeze_from_result_set_v1(uuid, text, uuid)'
  ];
  v_signature text;
begin
  if to_regrole('prospect_operator') is null then
    raise exception 'prospect_operator is missing'
      using detail = 'It is created by deploy/postgres/init/00-prospect-bootstrap.sh, not by a migration.';
  end if;

  foreach v_signature in array v_allowed loop
    if not has_function_privilege('prospect_operator', v_signature, 'execute') then
      v_failures := v_failures || format('%s should be executable', v_signature);
    end if;
  end loop;

  foreach v_signature in array v_denied loop
    if has_function_privilege('prospect_operator', v_signature, 'execute') then
      v_failures := v_failures || format('%s must not be executable', v_signature);
    end if;
  end loop;

  -- The point of SECURITY DEFINER: the worker runs mutations it has no
  -- privilege to perform, and cannot read a single prospect on its own.
  if has_table_privilege('prospect_operator', 'public.prospect_index', 'select') then
    v_failures := v_failures || 'prospect_operator must not read prospect_index';
  end if;
  if has_table_privilege('prospect_operator', 'public.client_prospects', 'select') then
    v_failures := v_failures || 'prospect_operator must not read client_prospects';
  end if;
  if has_table_privilege('prospect_operator', 'prospect_operations.operation_job_items', 'select') then
    v_failures := v_failures || 'prospect_operator must not read operation_job_items';
  end if;

  -- The application's new door is service_role's alone.
  foreach v_signature in array array[
    'public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb)',
    'public.result_set_status_v1(uuid, text, jsonb)',
    'public.result_set_page_v1(uuid, text, integer, integer)'
  ] loop
    if not has_function_privilege('service_role', v_signature, 'execute') then
      v_failures := v_failures || format('%s should be executable by service_role', v_signature);
    end if;
    if has_function_privilege('anon', v_signature, 'execute')
       or has_function_privilege('authenticated', v_signature, 'execute') then
      v_failures := v_failures || format('%s must not be reachable by anon or authenticated', v_signature);
    end if;
  end loop;

  if cardinality(v_failures) > 0 then
    raise exception 'operation run privileges are wrong: %', array_to_string(v_failures, '; ');
  end if;
end
$$;

commit;
