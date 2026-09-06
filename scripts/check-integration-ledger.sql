-- Synthetic fixtures, only inside caller's ROLLBACK transaction.
do $$
declare v_client text:=gen_random_uuid()::text; v_request uuid:=gen_random_uuid(); v_job uuid; v_again uuid; v_state jsonb;
begin
  insert into public.clients(id,name,normalized_name) values(v_client,'Integration fixture',v_client);
  v_job:=public.stage_integration_job_v1('fixture-actor',v_request,repeat('a',64),v_client,3909297,'direct','[[{"email":"fixture@example.test"}]]');
  v_again:=public.stage_integration_job_v1('fixture-actor',v_request,repeat('a',64),v_client,3909297,'direct','[[{"email":"fixture@example.test"}]]');
  if v_again<>v_job then raise exception 'Idempotency failed'; end if;
  begin
    perform public.stage_integration_job_v1('fixture-actor',v_request,repeat('b',64),v_client,3909297,'direct','[[{"email":"different@example.test"}]]');
    raise exception 'Conflicting request accepted';
  exception when invalid_parameter_value then null; end;
  if public.integration_job_status_v1('wrong-actor',v_job)<>'[]'::jsonb then raise exception 'Cross-actor status leaked'; end if;
  if public.cancel_integration_job_v1('wrong-actor',v_job) then raise exception 'Cross-actor cancellation accepted'; end if;
  v_state:=public.integration_job_status_v1('fixture-actor',v_job);
  if v_state->0->>'status'<>'draft' or v_state->0->>'total'<>'1' then raise exception 'Snapshot count/status mismatch'; end if;
  if not public.cancel_integration_job_v1('fixture-actor',v_job) then raise exception 'Cancellation failed'; end if;
  if public.cancel_integration_job_v1('fixture-actor',v_job) then raise exception 'Cancelled job was mutable'; end if;
  if has_function_privilege('anon','public.stage_integration_job_v1(text,uuid,text,text,bigint,text,jsonb)','EXECUTE')
    or has_function_privilege('authenticated','public.integration_job_status_v1(text,uuid)','EXECUTE')
    or has_table_privilege('authenticated','prospect_integrations.batches','SELECT') then raise exception 'Private job exposure'; end if;
  raise notice 'PASS: integration staging, idempotency, actor isolation, cancellation, private grants';
end;
$$;
