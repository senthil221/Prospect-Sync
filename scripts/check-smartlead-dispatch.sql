-- Only in a caller-owned transaction followed by ROLLBACK. No HTTP operations.
do $$
declare c text:=gen_random_uuid()::text;p text:=gen_random_uuid()::text;j uuid;u jsonb;payload jsonb;r uuid;again uuid;rid uuid:=gen_random_uuid();
begin
  insert into public.clients(id,name,normalized_name) values(c,'Dispatch fixture',c);
  insert into public.prospects(id,work_email) values(p,'worker@example.test');
  update public.integration_connections set connected=true,credential_ciphertext='fixture',checked_at=now(),next_request_at='-infinity',
    campaigns='[{"id":9007199254740980,"name":"Fixture","status":"PAUSED"}]' where provider='smartlead';
  perform public.set_integration_destination_v1('fixture',c,9007199254740980,true);
  j:=public.stage_mapped_integration_job_v1('fixture',gen_random_uuid(),repeat('a',64),c,9007199254740980,'[[{"email":"worker@example.test"}]]',
    jsonb_build_object('sourceIds',jsonb_build_object('worker@example.test',jsonb_build_array(p))));
  if public.enqueue_integration_job_v1('wrong-actor',j,false) then raise exception 'Cross-actor enqueue'; end if;
  if not public.enqueue_integration_job_v1('fixture',j,false) then raise exception 'Enqueue failed'; end if;
  if not public.enqueue_integration_job_v1('fixture',j,false) then raise exception 'Enqueue retry not idempotent'; end if;
  u:=prospect_integrations.claim_v1('upload');
  if u is null or u->>'kind'<>'upload' then raise exception 'No batch claim'; end if;
  if prospect_integrations.claim_v1('upload') is not null then raise exception 'Concurrent batch claim'; end if;
  payload:=prospect_integrations.prepare_upload_v1((u->>'id')::uuid,(u->>'token')::uuid);
  if jsonb_array_length(payload)<>1 then raise exception 'Preflight unexpectedly excluded lead'; end if;
  insert into public.client_blocklist(client_id,kind,value) values(c,'email','worker@example.test');
  payload:=prospect_integrations.prepare_upload_v1((u->>'id')::uuid,(u->>'token')::uuid);
  if jsonb_array_length(payload)<>0 then raise exception 'Late suppression bypass'; end if;
  if prospect_integrations.finish_v1('upload',(u->>'id')::uuid,gen_random_uuid(),'completed','{}',5) then raise exception 'Stale worker token accepted'; end if;
  if not prospect_integrations.finish_v1('upload',(u->>'id')::uuid,(u->>'token')::uuid,'completed','{"addedCount":0,"skippedCount":0}',5) then raise exception 'Checkpoint failed'; end if;
  if (select status from prospect_integrations.jobs where id=j)<>'completed' then raise exception 'Job not completed'; end if;
  if public.smartlead_report_v1('wrong-actor',j) is not null then raise exception 'Report ownership failed'; end if;
  if public.smartlead_report_v1('fixture',j)->0->'dispatchEmails'<>'[]'::jsonb then raise exception 'Suppressed report mismatch'; end if;
  if exists(select 1 from jsonb_array_elements(public.smartlead_progress_v1('wrong-actor')->'deliveries') d where d->>'id'=j::text) then raise exception 'Cross-actor progress'; end if;

  r:=public.request_smartlead_campaign_v1('fixture',rid,c,'New fixture');
  again:=public.request_smartlead_campaign_v1('fixture',rid,c,'New fixture');
  if again<>r then raise exception 'Duplicate creation intent'; end if;
  update public.integration_connections set next_request_at='-infinity' where provider='smartlead';
  u:=prospect_integrations.claim_v1('create');
  if u->>'id'<>r::text then raise exception 'Creation claim failed'; end if;
  update prospect_integrations.campaign_requests set lease_until=now()-interval '1 second' where id=r;
  update public.integration_connections set next_request_at='-infinity' where provider='smartlead';
  if prospect_integrations.claim_v1('create') is not null then raise exception 'Uncertain creation replayed'; end if;
  if (select status from prospect_integrations.campaign_requests where id=r)<>'needs_review' then raise exception 'Expired lease not fenced'; end if;
  if prospect_integrations.finish_v1('create',r,(u->>'token')::uuid,'completed','{"campaignId":9007199254740979}',5) then raise exception 'Expired receipt accepted'; end if;
  r:=public.request_smartlead_campaign_v1('fixture',gen_random_uuid(),c,'Successful creation fixture');
  u:=prospect_integrations.claim_v1('create');
  if not prospect_integrations.finish_v1('create',r,(u->>'token')::uuid,'completed','{"campaignId":9007199254740979}',5) then raise exception 'Creation receipt failed'; end if;
  if not exists(select 1 from prospect_integrations.client_campaigns where campaign_id=9007199254740979 and client_id=c and enabled) then raise exception 'Created campaign not mapped'; end if;
  if has_table_privilege('prospect_integrator','public.integration_connections','SELECT')
    or has_function_privilege('authenticated','public.enqueue_integration_job_v1(text,uuid,boolean)','EXECUTE')
    or has_function_privilege('anon','prospect_integrations.claim_v1(text)','EXECUTE') then raise exception 'Worker capability leaked'; end if;
  raise notice 'PASS: enqueue ownership/idempotency, single claim, suppression recheck, checkpoint, expired lease, private worker';
end;
$$;
