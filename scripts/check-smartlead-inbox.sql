insert into public.clients(id,name,normalized_name) values
  ('fixture-acme','Acme','acme'),('fixture-acme-labs','Acme Labs','acme labs'),('fixture-other','Other Client','other client');

do $$
declare
  token uuid; action jsonb; result jsonb; status_json jsonb;
  generation_one uuid:=gen_random_uuid(); generation_two uuid:=gen_random_uuid();
  reserve_one uuid:=gen_random_uuid(); reserve_two uuid:=gen_random_uuid();
  categories_one jsonb:='[{"id":1,"name":"Interested"},{"id":3,"name":"Not Interested"},{"id":6,"name":"Out of Office"},{"id":120097,"name":"Not the right fit"}]'::jsonb;
  categories_two jsonb:='[{"id":11,"name":"Interested"},{"id":33,"name":"Not Interested"},{"id":600,"name":"Out of Office"},{"id":700,"name":"Not the right fit"}]'::jsonb;
begin
  if (select enabled from prospect_integrations.smartlead_inbox_settings) then raise exception 'Inbox sync must default disabled'; end if;
  update public.integration_connections set attempt_token=reserve_one,next_request_at='-infinity' where provider='smartlead';
  if not public.rotate_smartlead_connection_v1('fixture',reserve_one,'fixture','[]'::jsonb,categories_one,generation_one)
    then raise exception 'Initial account rotation failed'; end if;
  if (select enabled from prospect_integrations.smartlead_inbox_settings) then raise exception 'Rotation must leave inbox paused'; end if;
  if public.confirm_smartlead_inbox_contract_v1('fixture',generation_one,'official-v1') then
    raise exception 'Legacy validation bypassed category readiness'; end if;
  if not public.confirm_smartlead_inbox_contract_v2('fixture',generation_one,'official-v1',categories_one)
    then raise exception 'Generation-scoped contract validation failed'; end if;
  if not public.set_smartlead_inbox_mapping_v1('fixture','Legacy Prefix','fixture-other',true)
    then raise exception 'Generation-scoped mapping failed'; end if;
  if not public.set_smartlead_inbox_enabled_v1('fixture',true) then raise exception 'Enable failed'; end if;
  update public.integration_connections set next_request_at='-infinity' where provider='smartlead';
  result:=prospect_integrations.claim_smartlead_inbox_sync_v1(); token:=(result->>'token')::uuid;
  if token is null then raise exception 'Initial sync was not claimable'; end if;
  if not prospect_integrations.finish_smartlead_inbox_sync_v1(token,'completed',jsonb_build_object(
    'contract','official-v1','rows',jsonb_build_array(
      jsonb_build_object('providerKey','same-provider-key','campaignId',1,'campaignName','Acme Labs | Sequence','email','person@example.test','categoryId',3,'replyTime','2026-09-25T15:55:32.000Z'),
      jsonb_build_object('providerKey','domain-one','campaignId',2,'campaignName','Acme - Sequence','email','domain@example.test','categoryId',120097,'replyTime','2026-09-25T15:55:32.000Z'),
      jsonb_build_object('providerKey','ooo-one','campaignId',3,'campaignName','Acme - Sequence','email','ooo@example.test','categoryId',6,'replyTime','2026-09-25T15:55:32.000Z')
    )),5) then raise exception 'First account page failed'; end if;
  if (select count(*) from prospect_integrations.smartlead_inbox_actions where connection_generation=generation_one)<>3
    then raise exception 'First account category behavior is incorrect'; end if;
  loop
    action:=prospect_integrations.claim_smartlead_inbox_action_v1(); exit when action is null;
    perform prospect_integrations.apply_smartlead_inbox_action_v1((action->>'id')::uuid,(action->>'token')::uuid);
  end loop;
  if not exists(select 1 from public.client_blocklist where client_id='fixture-acme' and kind='domain' and value='example.test')
    then raise exception 'Not-right-fit domain missing'; end if;
  delete from public.client_blocklist where client_id='fixture-acme-labs' and kind='email' and value='person@example.test';
  if not exists(select 1 from prospect_integrations.smartlead_inbox_tombstones
    where client_id='fixture-acme-labs' and kind='email' and value='person@example.test')
    then raise exception 'Manual removal tombstone missing'; end if;

  insert into prospect_integrations.smartlead_inbox_observations(
    connection_generation,provider_key,campaign_id,campaign_name,email,domain,category_id,reply_time,client_id,mapping_status,last_cycle)
  values(generation_one,'stale-action',9,'Acme | stale','stale@example.test','example.test',3,now(),'fixture-acme','matched',gen_random_uuid());
  insert into prospect_integrations.smartlead_inbox_actions(
    connection_generation,provider_key,category_id,client_id,kind,value)
  values(generation_one,'stale-action',3,'fixture-acme','email','stale@example.test');
  update prospect_integrations.smartlead_inbox_settings set status='queued',next_sync_at='infinity' where singleton;
  action:=prospect_integrations.claim_smartlead_inbox_action_v1();
  if action is null then raise exception 'Stale action was not claimed for race test'; end if;

  update public.integration_connections set attempt_token=reserve_two,next_request_at='-infinity' where provider='smartlead';
  if not public.rotate_smartlead_connection_v1('fixture',reserve_two,'fixture-two','[]'::jsonb,categories_two,generation_two)
    then raise exception 'Second account rotation failed'; end if;
  result:=prospect_integrations.apply_smartlead_inbox_action_v1((action->>'id')::uuid,(action->>'token')::uuid);
  if result is not null or exists(select 1 from public.client_blocklist where client_id='fixture-acme' and value='stale@example.test')
    then raise exception 'Old-generation claimed action crossed rotation fence'; end if;
  status_json:=public.smartlead_inbox_status_v1();
  if (status_json#>>'{counts,observed}')::integer<>0 or jsonb_array_length(status_json->'mappings')<>0
    then raise exception 'Old account observations or mappings leaked into current status'; end if;
  if (status_json#>>'{settings,connection_current}')::boolean
    then raise exception 'Rotated account was shown as validated'; end if;
  if not (status_json#>>'{settings,category_ready}')::boolean
    then raise exception 'New account category catalog was not ready'; end if;
  if (select client_id from prospect_integrations.resolve_smartlead_inbox_client_v2(generation_two,'Legacy Prefix | Sequence')) is not null
    then raise exception 'Old account mapping leaked into new resolver'; end if;

  if not public.confirm_smartlead_inbox_contract_v2('fixture',generation_two,'observed-flat-v1',categories_two)
    or not public.set_smartlead_inbox_enabled_v1('fixture',true) then raise exception 'Second account enable failed'; end if;
  update public.integration_connections set next_request_at='-infinity' where provider='smartlead';
  result:=prospect_integrations.claim_smartlead_inbox_sync_v1(); token:=(result->>'token')::uuid;
  perform prospect_integrations.finish_smartlead_inbox_sync_v1(token,'completed',jsonb_build_object(
    'contract','observed-flat-v1','rows',jsonb_build_array(
      jsonb_build_object('providerKey','same-provider-key','campaignId',20,'campaignName','Acme Labs | New account','email','person@example.test','categoryId',33,'replyTime','2026-09-26T15:55:32.000Z'),
      jsonb_build_object('providerKey','domain-two','campaignId',21,'campaignName','Acme | New account','email','new-domain@example.test','categoryId',700,'replyTime','2026-09-26T15:55:32.000Z'),
      jsonb_build_object('providerKey','old-custom-id','campaignId',22,'campaignName','Acme | New account','email','unsafe@example.test','categoryId',120097,'replyTime','2026-09-26T15:55:32.000Z')
    )),5);
  if (select count(*) from prospect_integrations.smartlead_inbox_observations where provider_key='same-provider-key')<>2
    then raise exception 'Provider key collision was not isolated by account generation'; end if;
  if (select mapping_status from prospect_integrations.smartlead_inbox_observations
    where connection_generation=generation_two and provider_key='old-custom-id')<>'unsupported_category'
    then raise exception 'Old account category ID was trusted in new account'; end if;
  if exists(select 1 from prospect_integrations.smartlead_inbox_actions
    where connection_generation=generation_two and provider_key='old-custom-id')
    then raise exception 'Unknown new-account category created an action'; end if;
  if (select status from prospect_integrations.smartlead_inbox_actions
    where connection_generation=generation_two and provider_key='same-provider-key')<>'manual_removed'
    then raise exception 'Cross-account tombstone was not preserved'; end if;
  if not exists(select 1 from public.client_blocklist where client_id='fixture-acme' and kind='domain' and value='example.test')
    then raise exception 'Account rotation removed an existing client blocklist entry'; end if;
end $$;

do $$ begin
  if has_table_privilege('anon','prospect_integrations.smartlead_inbox_observations','SELECT')
    or has_table_privilege('authenticated','prospect_integrations.smartlead_inbox_actions','SELECT')
    or has_table_privilege('service_role','prospect_integrations.smartlead_inbox_categories','SELECT')
    or has_function_privilege('anon','public.smartlead_inbox_status_v1()','EXECUTE')
    or has_function_privilege('authenticated','public.rotate_smartlead_connection_v1(text,uuid,text,jsonb,jsonb,uuid)','EXECUTE')
    or not has_function_privilege('service_role','public.rotate_smartlead_connection_v1(text,uuid,text,jsonb,jsonb,uuid)','EXECUTE')
    or has_function_privilege('service_role','prospect_integrations.claim_smartlead_inbox_sync_v1()','EXECUTE')
    or not has_function_privilege('prospect_integrator','prospect_integrations.claim_smartlead_inbox_sync_v1()','EXECUTE') then
    raise exception 'Smartlead inbox privilege boundary failed';
  end if;
  raise notice 'PASS: account-scoped inbox, category discovery, rotation fences, tombstones and grants';
end $$;
