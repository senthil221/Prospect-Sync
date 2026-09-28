insert into public.clients(id,name,normalized_name) values
  ('fixture-acme','Acme','acme'),('fixture-acme-labs','Acme Labs','acme labs'),('fixture-other','Other Client','other client');

-- Deterministically emulate a concurrent manual deletion becoming visible
-- during add_client_blocklist_batch_v2, after apply's first tombstone check.
create function prospect_integrations.fixture_tombstone_after_insert_v1()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.value='race@example.test' and new.source='paste' then
    insert into prospect_integrations.smartlead_inbox_tombstones(client_id,kind,value)
      values(new.client_id,new.kind,new.value) on conflict(client_id,kind,value) do nothing;
  end if;
  return new;
end $$;
create trigger trg_fixture_tombstone_after_insert
  after insert on public.client_blocklist for each row
  execute function prospect_integrations.fixture_tombstone_after_insert_v1();

do $$
declare token uuid; action jsonb; result jsonb; v_generation uuid; i integer:=0;
begin
  if (select enabled from prospect_integrations.smartlead_inbox_settings) then raise exception 'Inbox sync must default disabled'; end if;
  if prospect_integrations.claim_smartlead_inbox_sync_v1() is not null then raise exception 'Disabled sync was claimable'; end if;
  update public.integration_connections as connection
    set connected=true,credential_ciphertext='fixture',generation=gen_random_uuid(),next_request_at='-infinity'
    where connection.provider='smartlead' returning connection.generation into v_generation;
  insert into public.client_blocklist(client_id,kind,value,reason,source) values('fixture-acme','email','manual@example.test','Client Provided','manual');
  if not public.confirm_smartlead_inbox_contract_v1('fixture',v_generation,'official-v1') then raise exception 'Contract validation failed'; end if;
  if not public.set_smartlead_inbox_enabled_v1('fixture',true) then raise exception 'Enable failed'; end if;
  select prospect_integrations.claim_smartlead_inbox_sync_v1() into result;
  token:=(result->>'token')::uuid;
  if token is null or (result->>'offset')::integer<>0 or result->>'mode'<>'full' then raise exception 'Initial full-sync claim failed'; end if;
  if prospect_integrations.finish_smartlead_inbox_sync_v1(token,'completed',jsonb_build_object('rows','[]'::jsonb),5) then
    raise exception 'Missing provider contract advanced checkpoint';
  end if;
  if not prospect_integrations.finish_smartlead_inbox_sync_v1(token,'completed',jsonb_build_object('contract','official-v1','rows',jsonb_build_array(
    jsonb_build_object('providerKey','reply-email','campaignId',1,'campaignName','Acme Labs | Sequence','email','email@example.test','categoryId',3,'replyTime','2026-09-25T15:55:32.000Z'),
    jsonb_build_object('providerKey','reply-domain','campaignId',2,'campaignName','Acme - Sequence','email','domain@example.test','categoryId',120097,'replyTime','2026-09-25T15:55:32.000Z'),
    jsonb_build_object('providerKey','reply-ooo','campaignId',3,'campaignName','Acme - Sequence','email','ooo@example.test','categoryId',6,'replyTime','2026-09-25T15:55:32.000Z'),
    jsonb_build_object('providerKey','reply-unmatched','campaignId',4,'campaignName','Unknown Campaign','email','unknown@example.test','categoryId',1,'replyTime','2026-09-25T15:55:32.000Z'),
    jsonb_build_object('providerKey','reply-unknown-category','campaignId',5,'campaignName','Acme - Sequence','email','new-tag@example.test','categoryId',999999,'replyTime','2026-09-25T15:55:32.000Z'),
    jsonb_build_object('providerKey','reply-manual-existing','campaignId',6,'campaignName','Acme - Sequence','email','manual@example.test','categoryId',4,'replyTime','2026-09-25T15:55:32.000Z')
  )),5) then raise exception 'Page checkpoint failed'; end if;
  if prospect_integrations.finish_smartlead_inbox_sync_v1(token,'completed',jsonb_build_object('contract','official-v1','rows','[]'::jsonb),5) then raise exception 'Completed checkpoint replayed'; end if;
  if (select client_id from prospect_integrations.smartlead_inbox_observations where provider_key='reply-email')<>'fixture-acme-labs' then raise exception 'Longest prefix did not win'; end if;
  if (select mapping_status from prospect_integrations.smartlead_inbox_observations where provider_key='reply-unmatched')<>'unmatched' then raise exception 'Unmatched campaign was not held'; end if;
  if (select mapping_status from prospect_integrations.smartlead_inbox_observations where provider_key='reply-unknown-category')<>'unsupported_category' then raise exception 'Unknown category was not held'; end if;
  if exists(select 1 from prospect_integrations.smartlead_inbox_actions where provider_key in ('reply-ooo','reply-unmatched','reply-unknown-category')) then raise exception 'Unsafe category or mapping created action'; end if;
  if (select count(*) from prospect_integrations.smartlead_inbox_actions)<>4 then raise exception 'Expected email plus domain actions'; end if;
  loop
    action:=prospect_integrations.claim_smartlead_inbox_action_v1(); exit when action is null;
    perform prospect_integrations.apply_smartlead_inbox_action_v1((action->>'id')::uuid,(action->>'token')::uuid);
    i:=i+1; if i>10 then raise exception 'Action loop did not finish'; end if;
  end loop;
  if not exists(select 1 from public.client_blocklist where client_id='fixture-acme-labs' and kind='email' and value='email@example.test' and reason='Campaign Reply' and source='smartlead_inbox') then raise exception 'Reply email not applied to resolved client'; end if;
  if not exists(select 1 from public.client_blocklist where client_id='fixture-acme' and kind='domain' and value='example.test' and source='smartlead_inbox') then raise exception 'Not-right-fit domain missing'; end if;
  if not exists(select 1 from public.client_blocklist where client_id='fixture-acme' and kind='email' and value='manual@example.test' and source='manual' and reason='Client Provided') then raise exception 'Existing manual entry was overwritten'; end if;
  if exists(select 1 from public.client_blocklist where client_id='fixture-other') then raise exception 'Cross-client write'; end if;

  update prospect_integrations.smartlead_inbox_settings set next_sync_at=now() where singleton;
  update public.integration_connections set next_request_at='-infinity' where provider='smartlead';
  result:=prospect_integrations.claim_smartlead_inbox_sync_v1(); token:=(result->>'token')::uuid;
  if result->>'mode'<>'incremental' or result->>'from' is null or result->>'to' is null
    or (select next_full_sync_at<now()+interval '23 hours' from prospect_integrations.smartlead_inbox_settings) then
    raise exception 'Bounded incremental scan or daily full cadence missing';
  end if;
  perform prospect_integrations.finish_smartlead_inbox_sync_v1(token,'completed',jsonb_build_object('contract','official-v1','rows','[]'::jsonb),5);

  delete from public.client_blocklist where client_id='fixture-acme-labs' and kind='email' and value='email@example.test';
  if not exists(select 1 from prospect_integrations.smartlead_inbox_tombstones where client_id='fixture-acme-labs' and kind='email' and value='email@example.test') then raise exception 'Manual removal not remembered'; end if;
  if (select status from prospect_integrations.smartlead_inbox_actions where provider_key='reply-email')<>'applied' then raise exception 'Manual delete unexpectedly rewrote action ledger'; end if;

  perform public.request_smartlead_inbox_sync_v1('fixture');
  update public.integration_connections set next_request_at='-infinity' where provider='smartlead';
  result:=prospect_integrations.claim_smartlead_inbox_sync_v1(); token:=(result->>'token')::uuid;
  perform prospect_integrations.finish_smartlead_inbox_sync_v1(token,'completed',jsonb_build_object('contract','official-v1','rows',jsonb_build_array(
    jsonb_build_object('providerKey','reply-email','campaignId',1,'campaignName','Acme Labs | Sequence','email','email@example.test','categoryId',3,'replyTime','2026-09-25T15:55:32.000Z'),
    jsonb_build_object('providerKey','reply-domain','campaignId',2,'campaignName','Acme - Sequence','email','domain@example.test','categoryId',6,'replyTime','2026-09-25T15:55:32.000Z')
  )),5);
  if exists(select 1 from public.client_blocklist where client_id='fixture-acme-labs' and value='email@example.test') then raise exception 'Manual removal was recreated'; end if;
  if not exists(select 1 from public.client_blocklist where client_id='fixture-acme' and kind='email' and value='domain@example.test') then raise exception 'OOO change retracted earlier email'; end if;

  insert into prospect_integrations.smartlead_inbox_observations(provider_key,campaign_id,campaign_name,email,domain,category_id,reply_time,client_id,mapping_status,last_cycle)
    values('reply-delete-race',8,'Acme - Race','race@example.test','example.test',3,now(),'fixture-acme','matched',gen_random_uuid());
  insert into prospect_integrations.smartlead_inbox_actions(provider_key,category_id,connection_generation,client_id,kind,value)
    values('reply-delete-race',3,v_generation,'fixture-acme','email','race@example.test');
  action:=prospect_integrations.claim_smartlead_inbox_action_v1();
  result:=prospect_integrations.apply_smartlead_inbox_action_v1((action->>'id')::uuid,(action->>'token')::uuid);
  if result->>'state'<>'manual_removed'
    or exists(select 1 from public.client_blocklist where client_id='fixture-acme' and kind='email' and value='race@example.test')
    or (select status from prospect_integrations.smartlead_inbox_actions where provider_key='reply-delete-race')<>'manual_removed' then
    raise exception 'Post-insert manual deletion race recreated a Smartlead row';
  end if;

  if not public.set_smartlead_inbox_mapping_v1('fixture','Unknown','fixture-other',true) then raise exception 'Explicit mapping failed'; end if;
  if (select client_id from prospect_integrations.resolve_smartlead_inbox_client_v1('Unknown | Sequence'))<>'fixture-other' then raise exception 'Explicit mapping not resolved'; end if;

  insert into prospect_integrations.smartlead_inbox_observations(provider_key,campaign_id,campaign_name,email,domain,category_id,reply_time,client_id,mapping_status,last_cycle)
    values('reply-fenced',7,'Acme - Fence','fenced@example.test','example.test',3,now(),'fixture-acme','matched',gen_random_uuid());
  insert into prospect_integrations.smartlead_inbox_actions(provider_key,category_id,connection_generation,client_id,kind,value)
    values('reply-fenced',3,v_generation,'fixture-acme','email','fenced@example.test');
  perform public.set_smartlead_inbox_enabled_v1('fixture',false);
  if prospect_integrations.claim_smartlead_inbox_action_v1() is not null then raise exception 'Paused sync claimed a blocklist write'; end if;
  if not public.set_smartlead_inbox_enabled_v1('fixture',true) then raise exception 'Resume before fencing failed'; end if;
  action:=prospect_integrations.claim_smartlead_inbox_action_v1();
  if action is null then raise exception 'Fencing action was not claimed'; end if;
  update public.integration_connections set generation=gen_random_uuid() where provider='smartlead';
  result:=prospect_integrations.apply_smartlead_inbox_action_v1((action->>'id')::uuid,(action->>'token')::uuid);
  if result->>'state'<>'connection_changed' or exists(select 1 from public.client_blocklist where client_id='fixture-acme' and value='fenced@example.test') then
    raise exception 'Replaced connection was allowed to write';
  end if;
  if (select enabled from prospect_integrations.smartlead_inbox_settings) then raise exception 'Generation mismatch did not pause sync'; end if;
  if prospect_integrations.claim_smartlead_inbox_action_v1() is not null then raise exception 'Old-generation action remained claimable'; end if;
end $$;

do $$ begin
  if has_table_privilege('anon','prospect_integrations.smartlead_inbox_observations','SELECT')
    or has_table_privilege('authenticated','prospect_integrations.smartlead_inbox_actions','SELECT')
    or has_table_privilege('service_role','prospect_integrations.smartlead_inbox_observations','SELECT')
    or has_function_privilege('anon','public.smartlead_inbox_status_v1()','EXECUTE')
    or has_function_privilege('authenticated','public.set_smartlead_inbox_enabled_v1(text,boolean)','EXECUTE')
    or has_function_privilege('service_role','prospect_integrations.claim_smartlead_inbox_sync_v1()','EXECUTE')
    or not has_function_privilege('prospect_integrator','prospect_integrations.claim_smartlead_inbox_sync_v1()','EXECUTE') then
    raise exception 'Smartlead inbox privilege boundary failed';
  end if;
  raise notice 'PASS: Smartlead inbox categories, client scope, durable actions, manual deletion and grants';
end $$;
