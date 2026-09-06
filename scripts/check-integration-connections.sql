-- Caller must BEGIN, apply candidate migration, run this test and ROLLBACK.
do $$
declare v_token uuid; v_second uuid;
begin
  if has_table_privilege('anon','public.integration_connections','SELECT')
    or has_table_privilege('authenticated','public.integration_connections','UPDATE')
    or has_function_privilege('anon','public.reserve_integration_read_v1(text)','EXECUTE')
    or has_function_privilege('authenticated','public.reserve_integration_read_v1(text)','EXECUTE') then
    raise exception 'Integration secrets or privileged RPC exposed';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.integration_connections'::regclass) then
    raise exception 'RLS missing';
  end if;
  v_token := public.reserve_integration_read_v1('smartlead');
  v_second := public.reserve_integration_read_v1('smartlead');
  if v_token is null or v_second is not null then raise exception 'Shared cooldown failed'; end if;
  if public.reserve_integration_read_v1('invalid') is not null then raise exception 'Invalid provider accepted'; end if;
  update public.integration_connections set attempt_token=gen_random_uuid() where provider='smartlead';
  update public.integration_connections set credential_ciphertext='fixture',connected=true
    where provider='smartlead' and attempt_token=v_token;
  if found then raise exception 'Disconnected credential was resurrected'; end if;
  raise notice 'PASS: integration grants, RLS, shared cooldown and stale-attempt fencing';
end;
$$;
