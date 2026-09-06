-- Caller applies candidate migrations and wraps this entire check in ROLLBACK.
do $$
declare c text:=gen_random_uuid()::text; p text:=gen_random_uuid()::text; rows jsonb; j uuid;
begin
  insert into public.clients(id,name,normalized_name) values(c,'Preview fixture',c);
  insert into public.prospects(id,work_email) values(p,'fixture@example.test');
  rows:=public.integration_selection_v1(c,array[p]);
  if jsonb_array_length(rows)<>1 or (rows->0->>'suppressed')::boolean then raise exception 'Clean source failed'; end if;
  insert into public.client_blocklist(client_id,kind,value) values(c,'email','fixture@example.test');
  rows:=public.integration_selection_v1(c,array[p]);
  if not (rows->0->>'suppressed')::boolean then raise exception 'Email suppression failed'; end if;
  begin
    perform public.integration_selection_v1(c,array[gen_random_uuid()::text]);
    raise exception 'Missing ID silently dropped';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.stage_mapped_integration_job_v1('fixture',gen_random_uuid(),repeat('a',64),c,123,'[[{"email":"fixture@example.test"}]]','{}');
    raise exception 'Unmapped destination accepted';
  exception when invalid_parameter_value then null; end;
  update public.integration_connections set connected=true,credential_ciphertext='fixture',checked_at=now(),
    campaigns='[{"id":9007199254740989,"name":"Preview fixture","status":"DRAFTED"}]' where provider='smartlead';
  perform public.set_integration_destination_v1('fixture',c,9007199254740989,true);
  j:=public.stage_mapped_integration_job_v1('fixture',gen_random_uuid(),repeat('c',64),c,9007199254740989,'[[{"email":"fixture@example.test"}]]','{"selected":1}');
  if not exists(select 1 from prospect_integrations.jobs where id=j and status='draft' and connection_generation is not null) then raise exception 'Frozen job binding failed'; end if;
  update public.integration_connections set generation=gen_random_uuid() where provider='smartlead';
  begin
    perform public.stage_mapped_integration_job_v1('fixture',gen_random_uuid(),repeat('d',64),c,9007199254740989,'[[{"email":"fixture@example.test"}]]','{}');
    raise exception 'Changed credential accepted';
  exception when invalid_parameter_value then null; end;
  if has_function_privilege('authenticated','public.integration_selection_v1(text,text[])','EXECUTE')
    or has_function_privilege('anon','public.stage_mapped_integration_job_v1(text,uuid,text,text,bigint,jsonb,jsonb)','EXECUTE') then raise exception 'Preview RPC exposed'; end if;
  raise notice 'PASS: full selection, suppression, destination guard, frozen generation, private preview';
end;
$$;
