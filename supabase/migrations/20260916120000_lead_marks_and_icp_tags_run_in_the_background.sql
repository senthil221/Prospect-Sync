-- Lead marks and ICP tags, applied to "all matching" rather than to a page.
--
-- WHAT WAS DISABLED, AND WHY IT HAD TO BE. Four of the client workspace's bulk
-- actions were greyed out whenever the selection was "all matching": Mark as
-- lead, Clear lead, Tag and Untag. The reason is recorded in ProspectTable.tsx
-- where the buttons are - an all-matching action is frozen into a result set and
-- handed to the operations worker, and prospect_operations.apply_batch_v1 knew
-- four verbs (push, set_icp_verified/clear_icp_verified, set_date_contacted,
-- remove) and raised 22023 on anything else.
--
-- So the request would have been ACCEPTED - the route creates a job for any
-- action - and then failed inside the worker minutes later, after the user had
-- watched a result set build. Disabling the buttons was the honest stopgap.
-- This removes the reason for it.
--
-- WHY THE TWO PAIRS GO IN TOGETHER. They are the same shape: a client-scoped
-- mark on a shared prospect, applied over a frozen id list. Leads were the
-- deferred half of the Leads tab and tags the deferred half of client ICPs, and
-- shipping one without the other would leave the bulk bar half greyed out with
-- no way to tell from the screen which half worked.
--
-- THE SIGNATURES ALREADY LINE UP. set_client_lead_v1 takes exactly the argument
-- list set_icp_verified_v1 takes, so the lead arm is the ICP arm with one name
-- changed. set_client_prospect_tag_v1 takes one more - the tag - which is the
-- only real work here.
--
-- WHERE THE TAG COMES FROM, AND WHY IT IS CHECKED HERE AT ALL. A background job
-- carries its own parameters; the worker has nobody to ask. set_date_contacted
-- already says this about its date, in this same function. A tag id absent from
-- the payload is a job that can never run, so it raises with a reason rather
-- than calling the tag function with an empty string and reporting 0 updated.
-- The API validates it before the job is created for the same reason - both
-- ends, because only one of them can see the user.
--
-- OWNERSHIP IS NOT AN ISSUE, AND IS CHECKED ANYWAY. apply_batch_v1 is SECURITY
-- DEFINER owned by postgres, as are all four functions it now calls, so the
-- calls resolve exactly as the existing arms do. The assertion at the foot
-- states that rather than leaving it to be rediscovered.
--
-- TAGGING RE-INDEXES AND LEAD MARKING DOES NOT. prospect_index carries tags and
-- tag_text, and tag_text feeds search_text; is_lead is not in the index at all
-- (20260915110000, 20260915150000). Both facts are already true of the
-- interactive path - this changes nothing about them, and the queued count each
-- function reports flows through merge_result_v1 unchanged.
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regprocedure('prospect_operations.apply_batch_v1(uuid,integer,integer)') is null then
    raise exception 'apply_batch_v1 is missing; apply the background operations migrations first';
  end if;
  if to_regprocedure('public.set_client_lead_v1(text,boolean,text,jsonb,text[],text[],text)') is null then
    raise exception 'set_client_lead_v1 is missing; apply 20260915110000 first';
  end if;
  if to_regprocedure('public.set_client_prospect_tag_v1(text,text,boolean,text,jsonb,text[],text[],text)') is null then
    raise exception 'set_client_prospect_tag_v1 is missing; apply 20260915150000 first';
  end if;
end $$;

do $patch$
declare
  v_def text;
  v_marker constant text := $m$  elsif v_job.action = 'set_date_contacted' then$m$;
  v_replacement constant text := $r$  elsif v_job.action in ('set_lead', 'clear_lead') then
    -- Exactly the ICP arm above with one name changed; the two functions take
    -- the same arguments. Nothing in prospect_index carries is_lead, so this
    -- always reports queued: 0, which is correct rather than a gap.
    v_batch := public.set_client_lead_v1(
      p_client_id => v_job.client_scope,
      p_is_lead => (v_job.action = 'set_lead'),
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action in ('add_tag', 'remove_tag') then
    -- The tag travels in the payload, and a job without one can never run - so
    -- say so, the same way a missing Date Contacted does below. The tag is
    -- checked against the client INSIDE set_client_prospect_tag_v1, so a job
    -- cannot reach another client's tag by carrying its id.
    if coalesce(v_job.payload ->> 'tagId', '') = '' then
      raise exception 'This operation has no ICP tag to apply' using errcode = '22023';
    end if;
    v_batch := public.set_client_prospect_tag_v1(
      p_client_id => v_job.client_scope,
      p_tag_id => v_job.payload ->> 'tagId',
      p_apply => (v_job.action = 'add_tag'),
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action = 'set_date_contacted' then$r$;
begin
  select pg_get_functiondef('prospect_operations.apply_batch_v1(uuid,integer,integer)'::regprocedure) into v_def;

  -- Already patched by an earlier run of this migration.
  if position($m$v_job.action in ('set_lead', 'clear_lead')$m$ in v_def) > 0 then
    return;
  end if;
  if position(v_marker in v_def) = 0 then
    raise exception 'apply_batch_v1 no longer dispatches set_date_contacted in the expected shape; refusing to patch blindly';
  end if;

  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- ---------------------------------------------------------------------------
-- Assertions.
do $$
declare
  v_def text;
  v_cfg text[];
  v_action text;
begin
  v_def := pg_get_functiondef('prospect_operations.apply_batch_v1(uuid,integer,integer)'::regprocedure);

  -- Every action the client workspace can create a job for is now dispatchable.
  -- This list is the one in app/api/clients/[id]/prospects/route.ts; an action
  -- the route accepts and this function does not is a job that fails minutes
  -- after the user pressed the button.
  foreach v_action in array array['push', 'set_icp_verified', 'clear_icp_verified',
    'set_date_contacted', 'remove', 'set_lead', 'clear_lead', 'add_tag', 'remove_tag'] loop
    if position('''' || v_action || '''' in v_def) = 0 then
      raise exception 'apply_batch_v1 cannot dispatch %, which the API will happily accept', v_action;
    end if;
  end loop;

  -- And it still refuses what it does not know, rather than silently doing
  -- nothing. The raise is what turns a typo into a failed job instead of a job
  -- that reports success having applied nothing.
  if position('Unsupported operation action' in v_def) = 0 then
    raise exception 'apply_batch_v1 no longer refuses an unknown action';
  end if;

  -- CREATE OR REPLACE rewrites proconfig wholesale. This function is SECURITY
  -- DEFINER over an operations schema; a dropped search_path here is a security
  -- change, not a style one.
  select p.proconfig into v_cfg from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'prospect_operations' and p.proname = 'apply_batch_v1';
  if not (array_to_string(v_cfg, ',') like '%search_path=%') then
    raise exception 'apply_batch_v1 lost its pinned search_path: %', v_cfg;
  end if;
  if not (array_to_string(v_cfg, ',') like '%statement_timeout=%') then
    raise exception 'apply_batch_v1 lost its statement_timeout: %', v_cfg;
  end if;

  -- The two new calls resolve as the existing ones do: same owner, both
  -- SECURITY DEFINER, so the definer's rights carry through.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (('public', 'set_client_lead_v1'), ('public', 'set_client_prospect_tag_v1'))
      and (not p.prosecdef
        or pg_get_userbyid(p.proowner) <> (select pg_get_userbyid(p2.proowner) from pg_proc p2
             join pg_namespace n2 on n2.oid = p2.pronamespace
            where n2.nspname = 'prospect_operations' and p2.proname = 'apply_batch_v1'))
  ) then
    raise exception 'a bulk mark function does not share apply_batch_v1''s owner or definer rights';
  end if;
end $$;

-- A job carrying no tag fails with a reason, rather than tagging nothing and
-- reporting success. Checked against a real job so the branch actually runs -
-- it is frozen over an empty selection, so it applies to no prospect and
-- changes no data.
do $$
declare
  v_job uuid;
  v_message text;
begin
  insert into prospect_operations.operation_jobs
    (actor, action, request_id, entity_type, client_scope, content_hash, version_vector,
     status, payload, total_items, applied_items, expires_at)
  values ('migration-smoke-test', 'add_tag', gen_random_uuid(), 'prospect', 'no-such-client',
    'migration-smoke-test', '{}'::jsonb, 'frozen', '{}'::jsonb, 1, 0, now() + interval '1 hour')
  returning id into v_job;

  -- It needs one item: apply_batch_v1 closes a job with an empty batch before it
  -- ever reaches the dispatch, so a job frozen over nothing would prove nothing.
  -- The id is deliberately not a real prospect - the raise happens before any
  -- mutation, which is the point of checking the tag first.
  insert into prospect_operations.operation_job_items (job_id, ordinal, entity_id)
  values (v_job, 1, 'migration-smoke-test-no-such-prospect');

  begin
    perform * from prospect_operations.apply_batch_v1(v_job, 10, 60);
    raise exception 'a tag job with no tagId was applied instead of refused';
  exception
    when sqlstate '22023' then
      get stacked diagnostics v_message = message_text;
      if v_message not like '%no ICP tag%' then
        raise exception 'the tag job failed for the wrong reason: %', v_message;
      end if;
  end;

  delete from prospect_operations.operation_job_items where job_id = v_job;
  delete from prospect_operations.operation_jobs where id = v_job;
end $$;
