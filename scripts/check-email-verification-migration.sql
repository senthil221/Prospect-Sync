set statement_timeout='4min';

insert into public.companies(id,name,normalized_name,domain,normalized_domain)
values ('verify-company-a','Verification Scope A','verification scope a','scope-a.test','scope-a.test'),
       ('verify-company-b','Verification Scope B','verification scope b','scope-b.test','scope-b.test')
on conflict(id) do nothing;
insert into public.prospects(id,full_name,work_email,personal_email,company_id)
values ('verify-p1','Verify One','shared-check@corp.test','personal1@example.test','verify-company-a'),
       ('verify-p2','Verify Two','shared-check@corp.test','personal2@example.test','verify-company-a'),
       ('verify-p3','Verify Three','mutation@corp.test','','verify-company-b'),
       ('verify-p4','Personal Only','','personal4@example.test','verify-company-b')
on conflict(id) do nothing;
select public.reindex_prospects(array['verify-p1','verify-p2','verify-p3','verify-p4']);

create or replace function pg_temp.prepare_verification_run(p_run uuid,p_limit integer default 100)
returns jsonb language plpgsql as $$
declare v_token uuid:=gen_random_uuid(); v_result jsonb; v_alloc jsonb;
begin
  update prospect_verification.runs set status='preparing',preparation_token=v_token,
    preparation_lease_expires_at=now()+interval '15 minutes',started_at=coalesce(started_at,now())
  where id=p_run and status='queued';
  v_result:=public.prepare_email_verification_run_v1(p_run,v_token,p_limit);
  if v_result->>'status' not in ('running','completed','paused','cancelled') then return v_result; end if;
  loop
    v_alloc:=public.allocate_email_verification_targets_v1(p_run,500);
    exit when not coalesce((v_alloc->>'remaining')::boolean,false);
  end loop;
  return (select to_jsonb(r) from prospect_verification.runs r where r.id=p_run);
end $$;

do $contract$
declare
  v_request uuid := '10000000-0000-4000-8000-000000000001';
  v_run uuid; v_run2 uuid; v_run3 uuid; v_check uuid; v_token uuid; v_old_token uuid;
  v_json jsonb; v_count bigint; v_compiled bigint; v_matched bigint; v_generation integer;
begin
  -- Stable request UUID replay and changed-payload conflict.
  v_json:=public.request_email_verification_v1(v_request,
    '{"scope":"filtered","filters":[{"field":"__work_email","operator":"equals","values":["shared-check@corp.test"]}],"forceReverify":false}'::jsonb,null);
  v_run:=(v_json->>'id')::uuid;
  if (public.request_email_verification_v1(v_request,
    '{"scope":"filtered","filters":[{"field":"__work_email","operator":"equals","values":["shared-check@corp.test"]}],"forceReverify":false}'::jsonb,null)->>'id')::uuid<>v_run then
    raise exception 'identical request replay returned a different run';
  end if;
  begin
    perform public.request_email_verification_v1(v_request,'{"scope":"all","forceReverify":false}'::jsonb,null);
    raise exception 'changed idempotency payload did not conflict';
  exception when unique_violation then null; end;
  -- Prepared-set handles are execution details and may rotate while the same
  -- browser request is retried. They must not turn one user intent into a 409.
  v_request:='10000000-0000-4000-8000-000000000009';
  v_run:=(public.request_email_verification_v1(v_request,
    '{"scope":"filtered","filters":[],"companyScope":{"search":"Verification Scope A","filters":[],"_prepared_set_id":"20000000-0000-4000-8000-000000000001"},"intentCompanyScope":{"search":"Verification Scope A","filters":[],"limit":250000},"forceReverify":false}'::jsonb,null)->>'id')::uuid;
  if (public.request_email_verification_v1(v_request,
    '{"scope":"filtered","filters":[],"companyScope":{"search":"Verification Scope A","filters":[],"_prepared_set_id":"20000000-0000-4000-8000-000000000002"},"intentCompanyScope":{"search":"Verification Scope A","filters":[],"limit":250000},"forceReverify":false}'::jsonb,null)->>'id')::uuid<>v_run then
    raise exception 'prepared scope handle changed stable request identity';
  end if;
  perform public.control_email_verification_run_v1(v_run,'cancel');
  -- Continue the duplicate-email contract with its original request.
  v_request:='10000000-0000-4000-8000-000000000001';
  v_run:=(select id from prospect_verification.runs where request_id=v_request);

  perform pg_temp.prepare_verification_run(v_run,100);
  if (select count(*) from prospect_verification.run_targets where run_id=v_run)<>2
     or (select count(distinct check_id) from prospect_verification.run_targets where run_id=v_run)<>1 then
    raise exception 'duplicate normalized emails did not share one check';
  end if;

  -- A second overlapping run shares the same active check. Cancelling the
  -- first removes only its demand; completion still satisfies the second.
  v_run2:=(public.request_email_verification_v1('10000000-0000-4000-8000-000000000002',
    '{"scope":"filtered","filters":[{"field":"__work_email","operator":"equals","values":["shared-check@corp.test"]}],"forceReverify":false}'::jsonb,null)->>'id')::uuid;
  perform pg_temp.prepare_verification_run(v_run2,100);
  if (select count(distinct check_id) from prospect_verification.run_targets where run_id in(v_run,v_run2))<>1 then
    raise exception 'overlapping runs did not share the active check';
  end if;
  perform public.control_email_verification_run_v1(v_run,'cancel');
  perform public.control_email_verification_provider_v1('start',null);
  v_json:=public.claim_email_verification_check_v1('sql-contract',120);
  v_check:=(v_json->>'id')::uuid; v_token:=(v_json->>'leaseToken')::uuid;
  if v_check is null then raise exception 'shared check was not claimable'; end if;
  if not public.complete_email_verification_check_v1(v_check,v_token,'valid','Accepted','mailtester_ninja','2026-09-28T05:00:00Z') then
    raise exception 'fenced completion was rejected';
  end if;
  perform public.reconcile_email_verification_run_v1(v_run,500);
  perform public.reconcile_email_verification_run_v1(v_run2,500);
  if (select status from prospect_verification.runs where id=v_run)<>'cancelled'
     or (select status from prospect_verification.runs where id=v_run2)<>'completed' then
    raise exception 'shared completion changed cancelled demand or failed live demand';
  end if;
  if exists(select 1 from public.prospects where id in('verify-p1','verify-p2') and verification_status<>'valid') then
    raise exception 'valid result projection was not applied to duplicates';
  end if;

  -- Completed reuse retains provider timestamp; forced reverify creates one
  -- later generation, then Pause/Continue resumes that same run.
  v_run3:=(public.request_email_verification_v1('10000000-0000-4000-8000-000000000003',
    '{"scope":"filtered","filters":[{"field":"__work_email","operator":"equals","values":["shared-check@corp.test"]}],"forceReverify":false}'::jsonb,null)->>'id')::uuid;
  perform pg_temp.prepare_verification_run(v_run3,100);
  perform public.reconcile_email_verification_run_v1(v_run3,500);
  if (select reused_count from prospect_verification.runs where id=v_run3)<>2
     or exists(select 1 from public.prospects where id in('verify-p1','verify-p2') and verification_checked_at<>'2026-09-28T05:00:00Z') then
    raise exception 'completed result was not reused with its original timestamp';
  end if;
  v_run3:=(public.request_email_verification_v1('10000000-0000-4000-8000-000000000004',
    '{"scope":"filtered","filters":[{"field":"__work_email","operator":"equals","values":["shared-check@corp.test"]}],"forceReverify":true}'::jsonb,null)->>'id')::uuid;
  perform pg_temp.prepare_verification_run(v_run3,100);
  select max(generation) into v_generation from prospect_verification.email_checks where normalized_email='shared-check@corp.test';
  if v_generation<>2 then raise exception 'forced reverify did not create generation 2'; end if;
  perform public.control_email_verification_run_v1(v_run3,'pause');
  update prospect_verification.provider_control set next_dispatch_at=now()-interval '1 second' where singleton;
  if public.claim_email_verification_check_v1('sql-contract',120) is not null then raise exception 'paused-only demand was dispatched'; end if;
  if (public.control_email_verification_run_v1(v_run3,'continue')->>'id')::uuid<>v_run3 then raise exception 'Continue changed run identity'; end if;

  -- Expired leases are reclaimed and the old token is fenced.
  update prospect_verification.provider_control set next_dispatch_at=now()-interval '1 second' where singleton;
  v_json:=public.claim_email_verification_check_v1('sql-contract',30);
  v_check:=(v_json->>'id')::uuid; v_old_token:=(v_json->>'leaseToken')::uuid;
  update prospect_verification.email_checks set lease_expires_at=now()-interval '1 second' where id=v_check;
  update prospect_verification.provider_control set next_dispatch_at=now()-interval '1 second' where singleton;
  v_json:=public.claim_email_verification_check_v1('sql-contract-restart',30);
  v_token:=(v_json->>'leaseToken')::uuid;
  if v_token is null or v_token=v_old_token then raise exception 'expired lease was not reclaimed with a new fence'; end if;
  if public.complete_email_verification_check_v1(v_check,v_old_token,'invalid','Rejected','mailtester_ninja',now()) then raise exception 'stale lease token completed a check'; end if;
  -- Repeated protocol/transport failures open one global circuit, then a
  -- successful provider result closes it without inventing an invalid label.
  update prospect_verification.provider_control set consecutive_failures=2 where singleton;
  perform public.retry_email_verification_check_v1(v_check,v_token,'network',1,false,null,null);
  if (select consecutive_failures<>3 or cooldown_until<=now() from prospect_verification.provider_control where singleton) then
    raise exception 'repeated provider failures did not open the circuit';
  end if;
  update prospect_verification.provider_control set cooldown_until=null,next_dispatch_at=now()-interval '1 second' where singleton;
  update prospect_verification.email_checks set next_attempt_at=now()-interval '1 second' where id=v_check;
  v_json:=public.claim_email_verification_check_v1('sql-contract-recovered',30);
  v_token:=(v_json->>'leaseToken')::uuid;
  if (v_json->>'id')::uuid<>v_check then raise exception 'circuit recovery did not resume the same check'; end if;
  perform public.complete_email_verification_check_v1(v_check,v_token,'valid','Accepted','mailtester_ninja','2026-09-28T06:00:00Z');
  perform public.reconcile_email_verification_run_v1(v_run3,500);
  if (select consecutive_failures<>0 from prospect_verification.provider_control where singleton) then
    raise exception 'successful provider result did not reset the circuit';
  end if;

  -- Email mutation invalidates projection and makes the in-flight target
  -- skipped; the older generation can never overwrite a newer observation.
  v_run3:=(public.request_email_verification_v1('10000000-0000-4000-8000-000000000005',
    '{"scope":"filtered","filters":[{"field":"__work_email","operator":"equals","values":["mutation@corp.test"]}],"forceReverify":true}'::jsonb,null)->>'id')::uuid;
  perform pg_temp.prepare_verification_run(v_run3,100);
  update prospect_verification.provider_control set next_dispatch_at=now()-interval '1 second' where singleton;
  v_json:=public.claim_email_verification_check_v1('sql-contract',120);
  v_check:=(v_json->>'id')::uuid; v_token:=(v_json->>'leaseToken')::uuid;
  update public.prospects set work_email='new-mutation@corp.test' where id='verify-p3';
  perform public.complete_email_verification_check_v1(v_check,v_token,'invalid','Rejected','mailtester_ninja',now());
  perform public.reconcile_email_verification_run_v1(v_run3,500);
  if (select verification_status is not null from public.prospects where id='verify-p3')
     or (select skipped_count from prospect_verification.runs where id=v_run3)<>1 then
    raise exception 'changed email accepted a stale result or was not accounted skipped';
  end if;

  -- Compiler and row matcher agree for status and indexable UTC bounds. The
  -- values represent the Asia/Kolkata calendar day 2026-09-28.
  execute 'select count(*) from public.prospect_index pi where ' || public.prospect_filter_sql_v1('',
    '[{"field":"__work_email_status","operator":"equals","values":["valid"]}]'::jsonb) into v_compiled;
  select count(*) into v_matched from public.prospect_index pi where public.prospect_index_matches_v1(pi,'',
    '[{"field":"__work_email_status","operator":"equals","values":["valid"]}]'::jsonb);
  if v_compiled<>v_matched then raise exception 'verification status compiler/matcher drift'; end if;
  execute 'select count(*) from public.prospect_index pi where ' || public.prospect_filter_sql_v1('',
    '[{"field":"__work_email_verified_at","operator":"on","values":["2026-09-27T18:30:00Z","2026-09-28T18:30:00Z"]}]'::jsonb) into v_compiled;
  select count(*) into v_matched from public.prospect_index pi where public.prospect_index_matches_v1(pi,'',
    '[{"field":"__work_email_verified_at","operator":"on","values":["2026-09-27T18:30:00Z","2026-09-28T18:30:00Z"]}]'::jsonb);
  if v_compiled<>v_matched or v_compiled<2 then raise exception 'verified-on compiler/matcher UTC boundary drift: %, %',v_compiled,v_matched; end if;

  -- Company pivot scope and per-company cap freeze the same set as the grid.
  v_run3:=(public.request_email_verification_v1('10000000-0000-4000-8000-000000000006',
    '{"scope":"filtered","filters":[],"companyScope":{"search":"Verification Scope A","filters":[],"limit":250000},"forceReverify":false}'::jsonb,null)->>'id')::uuid;
  v_json:=pg_temp.prepare_verification_run(v_run3,100);
  if v_json->>'status'='failed' then raise exception 'company-scope preparation failed: %',v_json->>'last_error'; end if;
  if (select total_count from prospect_verification.runs where id=v_run3)<>2 then raise exception 'company scope did not freeze exactly its two people'; end if;
  v_run3:=(public.request_email_verification_v1('10000000-0000-4000-8000-000000000007',
    '{"scope":"filtered","filters":[{"field":"__max_people_per_company","operator":"equals","values":["1"]}],"companyScope":{},"forceReverify":false}'::jsonb,null)->>'id')::uuid;
  -- The migration replay fixture includes disposable rows for historical
  -- migration proofs. Admit them here so this assertion tests the company cap,
  -- rather than the unrelated preparation-overflow guard below.
  v_json:=pg_temp.prepare_verification_run(v_run3,2000);
  if v_json->>'status'='failed' then raise exception 'max-people preparation failed: %',v_json->>'last_error'; end if;
  if (select count(*) from prospect_verification.run_targets where run_id=v_run3 and prospect_id in('verify-p1','verify-p2'))<>1 then
    raise exception 'max-people-per-company path did not cap the shared company';
  end if;

  -- Explicit overflow fails atomically instead of silently truncating.
  v_run3:=(public.request_email_verification_v1('10000000-0000-4000-8000-000000000008',
    '{"scope":"filtered","filters":[{"field":"__work_email","operator":"equals","values":["shared-check@corp.test"]}],"forceReverify":true}'::jsonb,null)->>'id')::uuid;
  v_json:=pg_temp.prepare_verification_run(v_run3,1);
  if v_json->>'status'<>'failed' or exists(select 1 from prospect_verification.run_targets where run_id=v_run3) then
    raise exception 'overflow did not roll back targets and persist failure';
  end if;

  -- Rolling budget is durable and exposes a separate quota wait.
  update prospect_verification.provider_control set daily_limit=1,next_dispatch_at=now()-interval '1 second',quota_wait_until=null where singleton;
  -- Evaluate the volatile claim before reading the control row. Keeping both
  -- inside one boolean lets PostgreSQL hoist the uncorrelated SELECT into an
  -- InitPlan and observe quota_wait_until before the function updates it.
  v_json:=public.claim_email_verification_check_v1('sql-contract',120);
  if v_json is not null
     or (select quota_wait_until is null from prospect_verification.provider_control where singleton) then
    raise exception 'rolling provider budget was not enforced/persisted';
  end if;
  update prospect_verification.provider_control set daily_limit=150000 where singleton;
end
$contract$;

-- Transactional import completion and exactly-once opt-in enqueue. Historical
-- members of the same list are not pulled into this import's verification run.
insert into public.clients(id,name,normalized_name) values('verify-client','Verification Client','verification client') on conflict(id) do nothing;
insert into public.lists(id,client_id,name) values('verify-list','verify-client','Verification import') on conflict(id) do nothing;
insert into public.imports(id,client_id,list_id,file_name,status,total_rows,processed_rows,verify_work_emails)
values('verify-import-old','verify-client','verify-list','old.csv','completed',1,1,false),
      ('verify-import-new','verify-client','verify-list','new.csv','processing',1,1,true)
on conflict(id) do nothing;
insert into public.list_memberships(list_id,prospect_id,import_id)
values('verify-list','verify-p1','verify-import-old'),('verify-list','verify-p3','verify-import-new')
on conflict(list_id,prospect_id) do update set import_id=excluded.import_id;

do $import$
declare v_first jsonb; v_second jsonb; v_run uuid;
begin
  v_first:=public.complete_prospect_import_v2('verify-import-new','verify-list');
  v_second:=public.complete_prospect_import_v2('verify-import-new','verify-list');
  v_run:=(v_first->>'verificationRunId')::uuid;
  if v_run is null or (v_second->>'verificationRunId')::uuid<>v_run
     or (select count(*) from prospect_verification.runs where source_import_id='verify-import-new')<>1
     or (select count(*) from prospect_verification.run_targets where run_id=v_run)<>1
     or not (select snapshot_complete from prospect_verification.runs where id=v_run)
     or not exists(select 1 from prospect_verification.run_targets where run_id=v_run and prospect_id='verify-p3') then
    raise exception 'import completion did not enqueue exactly one current-import verification run';
  end if;
end
$import$;

do $grants$
begin
  if has_schema_privilege('anon','prospect_verification','USAGE')
     or has_table_privilege('authenticated','prospect_verification.runs','SELECT')
     or has_function_privilege('prospect_verification_worker','public.request_email_verification_v1(uuid,jsonb,uuid)','EXECUTE')
     or not has_function_privilege('prospect_verification_worker','public.claim_email_verification_check_v1(text,integer,integer)','EXECUTE')
     or not has_function_privilege('prospect_verification_worker','public.reconcile_email_verification_run_v1(uuid,integer)','EXECUTE')
     or not has_function_privilege('service_role','public.request_email_verification_v1(uuid,jsonb,uuid)','EXECUTE') then
    raise exception 'verification grants exceed or miss the intended capability boundary';
  end if;
end
$grants$;
