-- Synthetic data only; run inside a transaction that is rolled back.
do $$
declare a text:=gen_random_uuid()::text; b text:=gen_random_uuid()::text; campaign bigint:=9007199254740990; state jsonb;
begin
  insert into public.clients(id,name,normalized_name) values(a,'Destination A',a),(b,'Destination B',b);
  update public.integration_connections set connected=true,credential_ciphertext='fixture',checked_at=now(),
    campaigns=jsonb_build_array(jsonb_build_object('id',campaign,'name','Fixture','status','DRAFTED')) where provider='smartlead';
  if not public.set_integration_destination_v1('fixture',a,campaign,true) then raise exception 'Valid mapping failed'; end if;
  begin
    perform public.set_integration_destination_v1('fixture',b,campaign,true);
    raise exception 'Cross-client reassignment accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.set_integration_destination_v1('fixture',a,campaign-1,true);
    raise exception 'Unknown campaign accepted';
  exception when invalid_parameter_value then null; end;
  update public.integration_connections set checked_at=now()-interval '16 minutes' where provider='smartlead';
  begin
    perform public.set_integration_destination_v1('fixture',a,campaign,true);
    raise exception 'Stale catalog accepted';
  exception when invalid_parameter_value then null; end;
  update public.integration_connections set generation=gen_random_uuid() where provider='smartlead';
  select value into state from jsonb_array_elements(public.integration_destinations_v1()) where value->>'client_id'=a;
  if (state->>'connection_current')::boolean then raise exception 'Old credential mapping remained current'; end if;
  if public.set_integration_destination_v1('fixture',b,campaign,false) then raise exception 'Wrong-client removal accepted'; end if;
  if not public.set_integration_destination_v1('fixture',a,campaign,false) then raise exception 'Removal failed'; end if;
  if has_table_privilege('authenticated','prospect_integrations.client_campaigns','SELECT')
    or has_function_privilege('anon','public.set_integration_destination_v1(text,text,bigint,boolean)','EXECUTE') then raise exception 'Mapping privilege leak'; end if;
  raise notice 'PASS: campaign ownership, stale catalog, credential generation, removal and grants';
end;
$$;
