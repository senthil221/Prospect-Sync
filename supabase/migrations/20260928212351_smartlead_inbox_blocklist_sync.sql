-- Smartlead Master Inbox is a read-only provider feed. These tables retain only
-- the fields needed for idempotency, client routing and blocklist provenance;
-- message subjects, bodies and history are deliberately never stored.
create table prospect_integrations.smartlead_inbox_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  verified_generation uuid,
  verified_contract text check (verified_contract in ('official-v1','observed-flat-v1')),
  verified_at timestamptz,
  initial_backfill_complete boolean not null default false,
  scan_cycle uuid not null default gen_random_uuid(),
  scan_mode text not null default 'full' check (scan_mode in ('incremental','full')),
  scan_offset integer not null default 0 check (scan_offset >= 0),
  scan_from timestamptz,
  scan_to timestamptz,
  incremental_cursor timestamptz,
  next_full_sync_at timestamptz not null default now(),
  next_sync_at timestamptz not null default 'infinity',
  status text not null default 'disabled' check (status in ('disabled','queued','running','idle','paused','needs_review')),
  lease_token uuid,
  lease_until timestamptz,
  attempts integer not null default 0,
  pages_scanned bigint not null default 0,
  rows_observed bigint not null default 0,
  last_synced_at timestamptz,
  last_error_code text,
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
insert into prospect_integrations.smartlead_inbox_settings(singleton) values(true);

create table prospect_integrations.smartlead_inbox_client_mappings (
  prefix text primary key,
  client_id text not null references public.clients(id) on delete cascade,
  created_by text not null default '',
  created_at timestamptz not null default now(),
  check (length(prefix) between 1 and 200 and prefix = lower(btrim(prefix)))
);
create index smartlead_inbox_client_mappings_client
  on prospect_integrations.smartlead_inbox_client_mappings(client_id);

create table prospect_integrations.smartlead_inbox_observations (
  provider_key text primary key,
  campaign_id bigint not null check (campaign_id > 0),
  campaign_name text not null check (length(campaign_name) between 1 and 300),
  email text not null check (length(email) between 3 and 254),
  domain text not null check (length(domain) between 1 and 253),
  category_id integer,
  reply_time timestamptz not null,
  client_id text references public.clients(id) on delete set null,
  mapping_status text not null check (mapping_status in ('matched','unmatched','ambiguous','unsupported_category')),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  last_cycle uuid not null
);
create index smartlead_inbox_observations_mapping
  on prospect_integrations.smartlead_inbox_observations(mapping_status,last_seen_at desc);
create index smartlead_inbox_observations_client
  on prospect_integrations.smartlead_inbox_observations(client_id);

create table prospect_integrations.smartlead_inbox_tombstones (
  client_id text not null references public.clients(id) on delete cascade,
  kind text not null check (kind in ('email','domain')),
  value text not null,
  removed_at timestamptz not null default now(),
  primary key(client_id,kind,value)
);

create table prospect_integrations.smartlead_inbox_actions (
  id uuid primary key default gen_random_uuid(),
  provider_key text not null references prospect_integrations.smartlead_inbox_observations(provider_key) on delete cascade,
  category_id integer not null,
  connection_generation uuid not null,
  client_id text not null references public.clients(id) on delete cascade,
  kind text not null check (kind in ('email','domain')),
  value text not null,
  status text not null default 'pending' check (status in ('pending','applying','applied','manual_removed','needs_review')),
  attempt_token uuid,
  lease_until timestamptz,
  attempts integer not null default 0,
  slices integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_result jsonb,
  last_error_code text,
  created_at timestamptz not null default now(),
  applied_at timestamptz,
  unique(provider_key,category_id,client_id,kind,value)
);
create index smartlead_inbox_actions_queue
  on prospect_integrations.smartlead_inbox_actions(next_attempt_at,created_at)
  where status in ('pending','applying');
create index smartlead_inbox_actions_client
  on prospect_integrations.smartlead_inbox_actions(client_id);

alter table prospect_integrations.smartlead_inbox_settings enable row level security;
alter table prospect_integrations.smartlead_inbox_client_mappings enable row level security;
alter table prospect_integrations.smartlead_inbox_observations enable row level security;
alter table prospect_integrations.smartlead_inbox_tombstones enable row level security;
alter table prospect_integrations.smartlead_inbox_actions enable row level security;
revoke all on prospect_integrations.smartlead_inbox_settings,
  prospect_integrations.smartlead_inbox_client_mappings,
  prospect_integrations.smartlead_inbox_observations,
  prospect_integrations.smartlead_inbox_tombstones,
  prospect_integrations.smartlead_inbox_actions
  from public,anon,authenticated,service_role,prospect_integrator;

create function prospect_integrations.resolve_smartlead_inbox_client_v1(p_campaign text)
returns table(client_id text,mapping_status text)
language plpgsql stable security definer set search_path='' as $$
declare
  v_campaign text := lower(regexp_replace(btrim(coalesce(p_campaign,'')),'[[:space:]]+',' ','g'));
  v_max integer;
  v_count integer;
begin
  if v_campaign='' then return query select null::text,'unmatched'::text; return; end if;
  with candidates as (
    select m.client_id,m.prefix,length(m.prefix) as size
    from prospect_integrations.smartlead_inbox_client_mappings m
    where left(v_campaign,length(m.prefix))=m.prefix
      and (length(v_campaign)=length(m.prefix) or substring(v_campaign from length(m.prefix)+1 for 1) ~ '[[:space:]|:/_-]')
    union all
    select c.id,lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')) as prefix,
      length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))) as size
    from public.clients c
    where left(v_campaign,length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))))=lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))
      and (length(v_campaign)=length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))
        or substring(v_campaign from length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))+1 for 1) ~ '[[:space:]|:/_-]')
  ) select max(length(c.prefix)),count(distinct c.client_id) into v_max,v_count
    from candidates c where c.size=(select max(size) from candidates);
  if coalesce(v_count,0)=0 then return query select null::text,'unmatched'::text;
  elsif v_count>1 then return query select null::text,'ambiguous'::text;
  else return query
    with candidates as (
      select m.client_id,m.prefix,length(m.prefix) as size from prospect_integrations.smartlead_inbox_client_mappings m
      where left(v_campaign,length(m.prefix))=m.prefix and (length(v_campaign)=length(m.prefix) or substring(v_campaign from length(m.prefix)+1 for 1) ~ '[[:space:]|:/_-]')
      union all
      select c.id,lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')),length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))
      from public.clients c where left(v_campaign,length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))))=lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))
        and (length(v_campaign)=length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))) or substring(v_campaign from length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))+1 for 1) ~ '[[:space:]|:/_-]')
    ) select min(c.client_id),'matched'::text from candidates c where c.size=v_max;
  end if;
end $$;

create function prospect_integrations.claim_smartlead_inbox_sync_v1()
returns jsonb language plpgsql security definer set search_path='' as $$
declare s prospect_integrations.smartlead_inbox_settings%rowtype; c public.integration_connections%rowtype;
begin
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for update;
  if s.status='running' and s.lease_until<=now() then
    update prospect_integrations.smartlead_inbox_settings set status='queued',lease_token=null,lease_until=null,
      last_error_code='worker_lease_expired',next_sync_at=now() where singleton;
    s.status:='queued'; s.lease_token:=null;
  end if;
  if not s.enabled or not c.connected or s.verified_generation is distinct from c.generation then
    if s.enabled and s.verified_generation is distinct from c.generation then
      update prospect_integrations.smartlead_inbox_settings set enabled=false,status='needs_review',last_error_code='connection_changed',updated_at=now() where singleton;
    end if;
    return null;
  end if;
  if s.next_sync_at>now() or s.status='running' or c.next_request_at>now() then return null; end if;
  if s.scan_offset=0 then
    if not s.initial_backfill_complete or s.next_full_sync_at<=now() then
      update prospect_integrations.smartlead_inbox_settings set scan_mode='full',scan_from=null,scan_to=now() where singleton;
    else
      update prospect_integrations.smartlead_inbox_settings set scan_mode='incremental',
        scan_from=coalesce(s.incremental_cursor,now())-interval '2 hours',scan_to=now() where singleton;
    end if;
  end if;
  update prospect_integrations.smartlead_inbox_settings set status='running',lease_token=gen_random_uuid(),
    lease_until=now()+interval '90 seconds',attempts=attempts+1,updated_at=now() where singleton returning * into s;
  update public.integration_connections set next_request_at=now()+interval '5 seconds' where provider='smartlead';
  return jsonb_build_object('kind','inbox_sync','token',s.lease_token,'offset',s.scan_offset,
    'mode',s.scan_mode,'from',s.scan_from,'to',s.scan_to,'attempts',s.attempts,'credential',c.credential_ciphertext);
end $$;

create function prospect_integrations.finish_smartlead_inbox_sync_v1(
  p_token uuid,p_state text,p_result jsonb,p_delay integer default 60)
returns boolean language plpgsql security definer set search_path='' as $$
declare
  s prospect_integrations.smartlead_inbox_settings%rowtype;
  item jsonb;
  resolved record;
  v_count integer;
  v_category integer;
  v_domain text;
  v_status text;
  v_client text;
  v_supported boolean;
  c public.integration_connections%rowtype;
begin
  if p_state not in ('completed','retry','cooldown','connection_paused','needs_review') or p_result is null
    or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>1048576 then return false; end if;
  select * into s from prospect_integrations.smartlead_inbox_settings
    where singleton and lease_token=p_token and status='running' and lease_until>now() for update;
  if not found then return false; end if;
  select * into c from public.integration_connections where provider='smartlead' for share;
  if not c.connected or s.verified_generation is distinct from c.generation then
    update prospect_integrations.smartlead_inbox_settings set enabled=false,status='needs_review',lease_token=null,lease_until=null,
      last_error_code='connection_changed',updated_at=now() where singleton;
    return true;
  end if;
  if p_state='completed' then
    if jsonb_typeof(p_result->'rows') is distinct from 'array' or jsonb_array_length(p_result->'rows')>20
      or coalesce(p_result->>'contract','') not in ('official-v1','observed-flat-v1') then return false; end if;
    v_count:=jsonb_array_length(p_result->'rows');
    for item in select value from jsonb_array_elements(p_result->'rows') loop
      if jsonb_typeof(item)<>'object' or item->>'providerKey' is null or length(item->>'providerKey') not between 1 and 160
        or (item->>'campaignId')!~'^[0-9]+$'
        or length(btrim(coalesce(item->>'campaignName',''))) not between 1 and 300
        or length(coalesce(item->>'email','')) not between 3 and 254 or item->>'email'<>lower(btrim(item->>'email'))
        or item->>'email'!~'^[^[:space:]@,;<>]+@[^[:space:]@,;<>]+\.[^[:space:]@,;<>]+$'
        or coalesce(item->>'replyTime','')!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
        or (item->'categoryId' is not null and item->'categoryId'<>'null'::jsonb and (
          jsonb_typeof(item->'categoryId')<>'number' or (item->>'categoryId')!~'^[0-9]+$')) then return false; end if;
      if (item->>'campaignId')::numeric not between 1 and 9223372036854775807 then return false; end if;
      if item->'categoryId' is not null and item->'categoryId'<>'null'::jsonb
        and (item->>'categoryId')::numeric not between 1 and 2147483647 then return false; end if;
      begin perform (item->>'replyTime')::timestamptz; exception when others then return false; end;
      v_category:=case when item->'categoryId'='null'::jsonb then null else (item->>'categoryId')::integer end;
      v_supported:=v_category is null or v_category in (1,2,3,4,5,6,7,8,9,115247,115248,120097,163624,171350);
      v_domain:=split_part(item->>'email','@',2);
      select * into resolved from prospect_integrations.resolve_smartlead_inbox_client_v1(item->>'campaignName');
      v_client:=resolved.client_id; v_status:=case when not v_supported then 'unsupported_category' else resolved.mapping_status end;
      insert into prospect_integrations.smartlead_inbox_observations(provider_key,campaign_id,campaign_name,email,domain,category_id,reply_time,client_id,mapping_status,last_cycle)
      values(item->>'providerKey',(item->>'campaignId')::bigint,btrim(item->>'campaignName'),item->>'email',v_domain,v_category,(item->>'replyTime')::timestamptz,v_client,v_status,s.scan_cycle)
      on conflict(provider_key) do update set campaign_id=excluded.campaign_id,campaign_name=excluded.campaign_name,
        email=excluded.email,domain=excluded.domain,category_id=excluded.category_id,reply_time=excluded.reply_time,
        client_id=excluded.client_id,mapping_status=excluded.mapping_status,last_cycle=excluded.last_cycle,last_seen_at=now();
      if v_supported and v_category is not null and v_category<>6 and v_status='matched' then
        insert into prospect_integrations.smartlead_inbox_actions as existing(provider_key,category_id,connection_generation,client_id,kind,value,status)
        values(item->>'providerKey',v_category,s.verified_generation,v_client,'email',item->>'email',
          case when exists(select 1 from prospect_integrations.smartlead_inbox_tombstones t where t.client_id=v_client and t.kind='email' and t.value=item->>'email') then 'manual_removed' else 'pending' end)
        on conflict(provider_key,category_id,client_id,kind,value) do update set
          connection_generation=case when existing.status in ('pending','needs_review') then excluded.connection_generation else existing.connection_generation end,
          status=case when existing.status='needs_review' and existing.last_error_code='connection_changed' then excluded.status else existing.status end,
          next_attempt_at=case when existing.status='needs_review' and existing.last_error_code='connection_changed' then now() else existing.next_attempt_at end,
          last_error_code=case when existing.status='needs_review' and existing.last_error_code='connection_changed' then null else existing.last_error_code end;
        if v_category=120097 then
          insert into prospect_integrations.smartlead_inbox_actions as existing(provider_key,category_id,connection_generation,client_id,kind,value,status)
          values(item->>'providerKey',v_category,s.verified_generation,v_client,'domain',v_domain,
            case when exists(select 1 from prospect_integrations.smartlead_inbox_tombstones t where t.client_id=v_client and t.kind='domain' and t.value=v_domain) then 'manual_removed' else 'pending' end)
          on conflict(provider_key,category_id,client_id,kind,value) do update set
            connection_generation=case when existing.status in ('pending','needs_review') then excluded.connection_generation else existing.connection_generation end,
            status=case when existing.status='needs_review' and existing.last_error_code='connection_changed' then excluded.status else existing.status end,
            next_attempt_at=case when existing.status='needs_review' and existing.last_error_code='connection_changed' then now() else existing.next_attempt_at end,
            last_error_code=case when existing.status='needs_review' and existing.last_error_code='connection_changed' then null else existing.last_error_code end;
        end if;
      end if;
    end loop;
    update prospect_integrations.smartlead_inbox_settings set
      status=case when v_count<20 then 'idle' else 'queued' end,
      scan_offset=case when v_count<20 then 0 else scan_offset+15 end,
      scan_cycle=case when v_count<20 then gen_random_uuid() else scan_cycle end,
      scan_from=case when v_count<20 then null else scan_from end,
      scan_to=case when v_count<20 then null else scan_to end,
      incremental_cursor=case when v_count<20 then scan_to else incremental_cursor end,
      initial_backfill_complete=initial_backfill_complete or (v_count<20 and scan_mode='full'),
      next_full_sync_at=case when v_count<20 and scan_mode='full' then now()+interval '24 hours' else next_full_sync_at end,
      next_sync_at=case when v_count<20 then now()+interval '5 minutes' else now()+interval '5 seconds' end,
      lease_token=null,lease_until=null,attempts=0,pages_scanned=pages_scanned+1,rows_observed=rows_observed+v_count,
      last_synced_at=now(),last_error_code=null,updated_at=now() where singleton;
  else
    update prospect_integrations.smartlead_inbox_settings set
      enabled=case when p_state in ('connection_paused','needs_review') then false else enabled end,
      status=case when p_state in ('connection_paused','needs_review') then 'needs_review' else 'queued' end,
      next_sync_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),86400))),
      lease_token=null,lease_until=null,last_error_code=left(coalesce(p_result->>'reason',p_state),100),updated_at=now()
      where singleton;
    if p_state='connection_paused' then update public.integration_connections set connected=false where provider='smartlead'; end if;
  end if;
  return true;
end $$;

create function prospect_integrations.claim_smartlead_inbox_action_v1()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  a prospect_integrations.smartlead_inbox_actions%rowtype;
  s prospect_integrations.smartlead_inbox_settings%rowtype;
  c public.integration_connections%rowtype;
begin
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for share;
  if s.enabled and s.verified_generation is distinct from c.generation then
    update prospect_integrations.smartlead_inbox_settings set enabled=false,status='needs_review',last_error_code='connection_changed',updated_at=now() where singleton;
    return null;
  end if;
  if not s.enabled or not c.connected then return null; end if;
  update prospect_integrations.smartlead_inbox_actions set status='pending',attempt_token=null,lease_until=null,
    last_error_code='worker_lease_expired',next_attempt_at=now()
    where status='applying' and lease_until<=now();
  update prospect_integrations.smartlead_inbox_actions set status='needs_review',attempt_token=null,lease_until=null,last_error_code='connection_changed'
    where status='pending' and connection_generation is distinct from s.verified_generation;
  update prospect_integrations.smartlead_inbox_actions x set status='manual_removed'
    where x.status='pending' and exists(select 1 from prospect_integrations.smartlead_inbox_tombstones t
      where t.client_id=x.client_id and t.kind=x.kind and t.value=x.value);
  select * into a from prospect_integrations.smartlead_inbox_actions
    where status='pending' and connection_generation=s.verified_generation and next_attempt_at<=now()
    order by created_at for update skip locked limit 1;
  if not found then return null; end if;
  if a.attempts>=8 then
    update prospect_integrations.smartlead_inbox_actions set status='needs_review',last_error_code='retry_limit' where id=a.id;
    return null;
  end if;
  update prospect_integrations.smartlead_inbox_actions set status='applying',attempt_token=gen_random_uuid(),
    lease_until=now()+interval '120 seconds',attempts=attempts+1 where id=a.id returning * into a;
  return jsonb_build_object('kind','inbox_action','id',a.id,'token',a.attempt_token);
end $$;

create function prospect_integrations.apply_smartlead_inbox_action_v1(p_id uuid,p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  a prospect_integrations.smartlead_inbox_actions%rowtype;
  result jsonb;
  request_id text;
  entry_id text;
  s prospect_integrations.smartlead_inbox_settings%rowtype;
  c public.integration_connections%rowtype;
begin
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for share;
  select * into a from prospect_integrations.smartlead_inbox_actions
    where id=p_id and attempt_token=p_token and status='applying' and lease_until>now() for update;
  if not found then return null; end if;
  if not s.enabled then
    update prospect_integrations.smartlead_inbox_actions set status='pending',attempt_token=null,lease_until=null,next_attempt_at=now() where id=a.id;
    return jsonb_build_object('state','paused');
  end if;
  if not c.connected or s.verified_generation is distinct from c.generation or a.connection_generation is distinct from s.verified_generation then
    update prospect_integrations.smartlead_inbox_actions set status='needs_review',attempt_token=null,lease_until=null,last_error_code='connection_changed' where id=a.id;
    update prospect_integrations.smartlead_inbox_settings set enabled=false,status='needs_review',last_error_code='connection_changed',updated_at=now() where singleton;
    return jsonb_build_object('state','connection_changed');
  end if;
  if exists(select 1 from prospect_integrations.smartlead_inbox_tombstones t where t.client_id=a.client_id and t.kind=a.kind and t.value=a.value) then
    update prospect_integrations.smartlead_inbox_actions set status='manual_removed',attempt_token=null,lease_until=null where id=a.id;
    return jsonb_build_object('state','manual_removed');
  end if;
  request_id:='slinbox-'||replace(a.id::text,'-','')||'-'||a.slices::text;
  result:=public.add_client_blocklist_batch_v2(a.client_id,
    case when a.kind='domain' then array[a.value] else null end,
    case when a.kind='email' then array[a.value] else null end,
    'Campaign Reply','smartlead-inbox',request_id,500);
  if coalesce((result->>'added')::integer,0)>0 then
    update public.client_blocklist set source='smartlead_inbox'
      where client_id=a.client_id and kind=a.kind and value=a.value and source='paste' and reason='Campaign Reply'
      returning id into entry_id;
  end if;
  -- A manual DELETE can commit while add_client_blocklist_batch_v2 is waiting
  -- on the old unique-key row. Recheck with this statement's fresh READ
  -- COMMITTED snapshot and remove only the row this action just inserted.
  if exists(select 1 from prospect_integrations.smartlead_inbox_tombstones t
    where t.client_id=a.client_id and t.kind=a.kind and t.value=a.value) then
    if entry_id is not null then
      perform public.remove_client_blocklist_v1(a.client_id,array[entry_id],'smartlead_inbox');
    end if;
    update prospect_integrations.smartlead_inbox_actions set status='manual_removed',attempt_token=null,lease_until=null,
      attempts=0,last_result=result,last_error_code=null where id=a.id;
    return jsonb_build_object('state','manual_removed');
  end if;
  update prospect_integrations.smartlead_inbox_actions set
    status=case when coalesce((result->>'remaining')::boolean,false) then 'pending' else 'applied' end,
    attempt_token=null,lease_until=null,attempts=0,slices=slices+1,
    next_attempt_at=case when coalesce((result->>'remaining')::boolean,false) then now()+interval '1 second' else next_attempt_at end,
    last_result=result,last_error_code=null,applied_at=case when coalesce((result->>'remaining')::boolean,false) then applied_at else now() end
    where id=a.id;
  return jsonb_build_object('state',case when coalesce((result->>'remaining')::boolean,false) then 'pending' else 'applied' end,'result',result);
end $$;

create function prospect_integrations.retry_smartlead_inbox_action_v1(p_id uuid,p_token uuid,p_error text,p_delay integer default 60)
returns boolean language plpgsql security definer set search_path='' as $$
declare changed integer;
begin
  update prospect_integrations.smartlead_inbox_actions set status='pending',attempt_token=null,lease_until=null,
    next_attempt_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),3600))),
    last_error_code=left(coalesce(p_error,'apply_failed'),100)
    where id=p_id and attempt_token=p_token and status='applying' and lease_until>now();
  get diagnostics changed=row_count; return changed=1;
end $$;

create function prospect_integrations.remember_smartlead_inbox_removal_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.source='smartlead_inbox' or exists(
    select 1 from prospect_integrations.smartlead_inbox_actions a
    where a.client_id=old.client_id and a.kind=old.kind and a.value=old.value
  ) then
    insert into prospect_integrations.smartlead_inbox_tombstones(client_id,kind,value)
      values(old.client_id,old.kind,old.value) on conflict(client_id,kind,value) do update set removed_at=now();
  end if;
  return old;
end $$;
create trigger trg_remember_smartlead_inbox_removal
  after delete on public.client_blocklist for each row execute function prospect_integrations.remember_smartlead_inbox_removal_v1();

create function public.confirm_smartlead_inbox_contract_v1(p_actor text,p_generation uuid,p_contract text)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_contract not in ('official-v1','observed-flat-v1') or not exists(select 1 from public.integration_connections
    where provider='smartlead' and connected and generation=p_generation) then return false; end if;
  update prospect_integrations.smartlead_inbox_settings set verified_generation=p_generation,verified_contract=p_contract,
    verified_at=now(),enabled=false,status='paused',initial_backfill_complete=false,scan_mode='full',scan_offset=0,
    scan_from=null,scan_to=null,incremental_cursor=null,next_full_sync_at=now(),next_sync_at='infinity',
    last_error_code=null,updated_by=left(coalesce(p_actor,''),300),updated_at=now()
    where singleton; return true;
end $$;

create function public.set_smartlead_inbox_enabled_v1(p_actor text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare c public.integration_connections%rowtype; s prospect_integrations.smartlead_inbox_settings%rowtype;
begin
  select * into c from public.integration_connections where provider='smartlead';
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  if p_enabled and (not c.connected or s.verified_generation is distinct from c.generation or s.verified_at is null) then return false; end if;
  update prospect_integrations.smartlead_inbox_settings set enabled=p_enabled,status=case when p_enabled then 'queued' else 'paused' end,
    next_sync_at=case when p_enabled then now() else 'infinity' end,lease_token=null,lease_until=null,
    updated_by=left(coalesce(p_actor,''),300),updated_at=now() where singleton; return true;
end $$;

create function public.request_smartlead_inbox_sync_v1(p_actor text)
returns boolean language plpgsql security definer set search_path='' as $$
declare changed integer;
begin
  update prospect_integrations.smartlead_inbox_settings set scan_mode='full',scan_offset=0,scan_from=null,scan_to=null,
    scan_cycle=gen_random_uuid(),next_full_sync_at=now(),next_sync_at=now(),status='queued',
    updated_by=left(coalesce(p_actor,''),300),updated_at=now() where singleton and enabled and status<>'running';
  get diagnostics changed=row_count; return changed=1;
end $$;

create function public.set_smartlead_inbox_mapping_v1(p_actor text,p_prefix text,p_client text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_prefix text:=lower(regexp_replace(btrim(coalesce(p_prefix,'')),'[[:space:]]+',' ','g'));
begin
  if length(v_prefix) not between 1 and 200 or not exists(select 1 from public.clients where id=p_client) then return false; end if;
  if p_enabled then
    insert into prospect_integrations.smartlead_inbox_client_mappings(prefix,client_id,created_by)
      values(v_prefix,p_client,left(coalesce(p_actor,''),300))
      on conflict(prefix) do update set client_id=excluded.client_id,created_by=excluded.created_by,created_at=now();
  else delete from prospect_integrations.smartlead_inbox_client_mappings where smartlead_inbox_client_mappings.prefix=v_prefix and client_id=p_client;
  end if;
  update prospect_integrations.smartlead_inbox_settings set scan_mode='full',scan_offset=0,scan_from=null,scan_to=null,
    scan_cycle=gen_random_uuid(),next_full_sync_at=now(),next_sync_at=case when enabled then now() else next_sync_at end,
    status=case when enabled then 'queued' else status end,updated_by=left(coalesce(p_actor,''),300),updated_at=now() where singleton;
  return true;
end $$;

create function public.smartlead_inbox_status_v1()
returns jsonb language sql stable security definer set search_path='' as $$
select jsonb_build_object(
  'settings',(select to_jsonb(s)-'lease_token'-'lease_until' from prospect_integrations.smartlead_inbox_settings s where singleton),
  'counts',jsonb_build_object(
    'observed',(select count(*) from prospect_integrations.smartlead_inbox_observations),
    'unmatched',(select count(*) from prospect_integrations.smartlead_inbox_observations where mapping_status<>'matched'),
    'pending',(select count(*) from prospect_integrations.smartlead_inbox_actions where status in ('pending','applying')),
    'applied',(select count(*) from prospect_integrations.smartlead_inbox_actions where status='applied'),
    'manualRemoved',(select count(*) from prospect_integrations.smartlead_inbox_tombstones)),
  'unmatched',coalesce((select jsonb_agg(to_jsonb(x)) from (select campaign_name,mapping_status,count(*)::integer as replies
    from prospect_integrations.smartlead_inbox_observations where mapping_status<>'matched'
    group by campaign_name,mapping_status order by max(last_seen_at) desc limit 50)x),'[]'::jsonb),
  'mappings',coalesce((select jsonb_agg(to_jsonb(x)) from (select m.prefix,m.client_id,c.name as client_name
    from prospect_integrations.smartlead_inbox_client_mappings m join public.clients c on c.id=m.client_id order by m.prefix)x),'[]'::jsonb));
$$;

revoke execute on function prospect_integrations.resolve_smartlead_inbox_client_v1(text) from public,anon,authenticated,service_role,prospect_integrator;
revoke execute on function prospect_integrations.claim_smartlead_inbox_sync_v1() from public,anon,authenticated,service_role;
revoke execute on function prospect_integrations.finish_smartlead_inbox_sync_v1(uuid,text,jsonb,integer) from public,anon,authenticated,service_role;
revoke execute on function prospect_integrations.claim_smartlead_inbox_action_v1() from public,anon,authenticated,service_role;
revoke execute on function prospect_integrations.apply_smartlead_inbox_action_v1(uuid,uuid) from public,anon,authenticated,service_role;
revoke execute on function prospect_integrations.retry_smartlead_inbox_action_v1(uuid,uuid,text,integer) from public,anon,authenticated,service_role;
revoke execute on function prospect_integrations.remember_smartlead_inbox_removal_v1() from public,anon,authenticated,service_role,prospect_integrator;
revoke execute on function public.confirm_smartlead_inbox_contract_v1(text,uuid,text) from public,anon,authenticated;
revoke execute on function public.set_smartlead_inbox_enabled_v1(text,boolean) from public,anon,authenticated;
revoke execute on function public.request_smartlead_inbox_sync_v1(text) from public,anon,authenticated;
revoke execute on function public.set_smartlead_inbox_mapping_v1(text,text,text,boolean) from public,anon,authenticated;
revoke execute on function public.smartlead_inbox_status_v1() from public,anon,authenticated;
grant execute on function prospect_integrations.claim_smartlead_inbox_sync_v1() to prospect_integrator;
grant execute on function prospect_integrations.finish_smartlead_inbox_sync_v1(uuid,text,jsonb,integer) to prospect_integrator;
grant execute on function prospect_integrations.claim_smartlead_inbox_action_v1() to prospect_integrator;
grant execute on function prospect_integrations.apply_smartlead_inbox_action_v1(uuid,uuid) to prospect_integrator;
grant execute on function prospect_integrations.retry_smartlead_inbox_action_v1(uuid,uuid,text,integer) to prospect_integrator;
grant execute on function public.confirm_smartlead_inbox_contract_v1(text,uuid,text) to service_role;
grant execute on function public.set_smartlead_inbox_enabled_v1(text,boolean) to service_role;
grant execute on function public.request_smartlead_inbox_sync_v1(text) to service_role;
grant execute on function public.set_smartlead_inbox_mapping_v1(text,text,text,boolean) to service_role;
grant execute on function public.smartlead_inbox_status_v1() to service_role;
