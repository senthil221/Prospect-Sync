-- Scope every Smartlead inbox artifact to the credential generation that
-- produced it. Credential rotation becomes a fenced, atomic state transition:
-- old observations stay available for audit, but can never appear in or write
-- from the newly connected account.

alter table prospect_integrations.smartlead_inbox_client_mappings
  add column connection_generation uuid;
alter table prospect_integrations.smartlead_inbox_observations
  add column connection_generation uuid;

do $$
declare v_legacy_generation uuid;
begin
  select coalesce(s.verified_generation, gen_random_uuid()) into v_legacy_generation
  from prospect_integrations.smartlead_inbox_settings s where s.singleton;
  update prospect_integrations.smartlead_inbox_client_mappings
    set connection_generation=v_legacy_generation where connection_generation is null;
  update prospect_integrations.smartlead_inbox_observations
    set connection_generation=v_legacy_generation where connection_generation is null;
end $$;

alter table prospect_integrations.smartlead_inbox_client_mappings
  alter column connection_generation set not null,
  drop constraint smartlead_inbox_client_mappings_pkey,
  add constraint smartlead_inbox_client_mappings_pkey primary key(connection_generation,prefix);

alter table prospect_integrations.smartlead_inbox_actions
  drop constraint if exists smartlead_inbox_actions_provider_key_fkey;

do $$
declare v_constraint name;
begin
  select c.conname into v_constraint
  from pg_catalog.pg_constraint c
  where c.conrelid='prospect_integrations.smartlead_inbox_actions'::regclass
    and c.contype='u'
    and pg_catalog.pg_get_constraintdef(c.oid)='UNIQUE (provider_key, category_id, client_id, kind, value)';
  if v_constraint is not null then
    execute format('alter table prospect_integrations.smartlead_inbox_actions drop constraint %I',v_constraint);
  end if;
end $$;

alter table prospect_integrations.smartlead_inbox_observations
  alter column connection_generation set not null,
  drop constraint smartlead_inbox_observations_pkey;

-- An older installation may already contain fenced actions from a previous
-- credential generation. Give each such generation its own immutable copy of
-- the observation before the composite FK is installed.
insert into prospect_integrations.smartlead_inbox_observations(
  connection_generation,provider_key,campaign_id,campaign_name,email,domain,category_id,reply_time,
  client_id,mapping_status,first_seen_at,last_seen_at,last_cycle)
select distinct a.connection_generation,o.provider_key,o.campaign_id,o.campaign_name,o.email,o.domain,
  o.category_id,o.reply_time,o.client_id,o.mapping_status,o.first_seen_at,o.last_seen_at,o.last_cycle
from prospect_integrations.smartlead_inbox_actions a
join prospect_integrations.smartlead_inbox_observations o on o.provider_key=a.provider_key
where a.connection_generation is distinct from o.connection_generation;

alter table prospect_integrations.smartlead_inbox_observations
  add constraint smartlead_inbox_observations_pkey primary key(connection_generation,provider_key);

alter table prospect_integrations.smartlead_inbox_actions
  add constraint smartlead_inbox_actions_observation_fkey
    foreign key(connection_generation,provider_key)
    references prospect_integrations.smartlead_inbox_observations(connection_generation,provider_key)
    on delete cascade,
  add constraint smartlead_inbox_actions_generation_unique
    unique(connection_generation,provider_key,category_id,client_id,kind,value);

create index smartlead_inbox_mappings_generation_client
  on prospect_integrations.smartlead_inbox_client_mappings(connection_generation,client_id);
create index smartlead_inbox_observations_generation_mapping
  on prospect_integrations.smartlead_inbox_observations(connection_generation,mapping_status,last_seen_at desc);
create index smartlead_inbox_actions_generation_status
  on prospect_integrations.smartlead_inbox_actions(connection_generation,status,next_attempt_at);

create table prospect_integrations.smartlead_inbox_categories (
  connection_generation uuid not null,
  category_id integer not null check(category_id>0),
  category_name text not null check(length(category_name) between 1 and 100),
  normalized_name text not null check(length(normalized_name) between 1 and 100),
  behavior text not null check(behavior in ('email','email_and_domain','ignore')),
  discovered_at timestamptz not null default now(),
  primary key(connection_generation,category_id)
);
create index smartlead_inbox_categories_generation_name
  on prospect_integrations.smartlead_inbox_categories(connection_generation,normalized_name);
alter table prospect_integrations.smartlead_inbox_categories enable row level security;
revoke all on prospect_integrations.smartlead_inbox_categories
  from public,anon,authenticated,service_role,prospect_integrator;

create or replace function prospect_integrations.replace_smartlead_inbox_categories_v1(
  p_generation uuid,p_categories jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_ooo integer; v_nrf integer;
begin
  if p_generation is null or p_categories is null or jsonb_typeof(p_categories)<>'array'
    or jsonb_array_length(p_categories) not between 2 and 200
    or octet_length(p_categories::text)>262144 then return false; end if;
  if exists(
    select 1 from jsonb_array_elements(p_categories) x
    where jsonb_typeof(x)<>'object' or not (x ? 'id') or not (x ? 'name')
      or jsonb_typeof(x->'id')<>'number'
      or (x->>'id')!~'^[0-9]+$' or (x->>'id')::numeric not between 1 and 2147483647
      or jsonb_typeof(x->'name')<>'string'
      or length(btrim(x->>'name')) not between 1 and 100
  ) then return false; end if;
  select count(*) filter(where lower(regexp_replace(btrim(x->>'name'),'[[:space:]]+',' ','g'))='out of office'),
    count(*) filter(where lower(regexp_replace(btrim(x->>'name'),'[[:space:]]+',' ','g'))='not the right fit')
    into v_ooo,v_nrf from jsonb_array_elements(p_categories) x;
  if (select count(*)<>count(distinct (x->>'id')::integer) from jsonb_array_elements(p_categories) x)
    or v_ooo<>1 or v_nrf<>1 then return false; end if;
  delete from prospect_integrations.smartlead_inbox_categories where connection_generation=p_generation;
  insert into prospect_integrations.smartlead_inbox_categories(
    connection_generation,category_id,category_name,normalized_name,behavior)
  select p_generation,(x->>'id')::integer,btrim(x->>'name'),
    lower(regexp_replace(btrim(x->>'name'),'[[:space:]]+',' ','g')),
    case lower(regexp_replace(btrim(x->>'name'),'[[:space:]]+',' ','g'))
      when 'out of office' then 'ignore'
      when 'not the right fit' then 'email_and_domain'
      else 'email' end
  from jsonb_array_elements(p_categories) x;
  return true;
end $$;

-- Called only after the API key has been tested against Smartlead. The worker
-- and rotation paths share settings -> connection -> action lock ordering.
create function public.rotate_smartlead_connection_v1(
  p_actor text,p_attempt_token uuid,p_ciphertext text,p_campaigns jsonb,
  p_categories jsonb,p_new_generation uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare s prospect_integrations.smartlead_inbox_settings%rowtype;
  c public.integration_connections%rowtype;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_attempt_token is null
    or p_new_generation is null or length(coalesce(p_ciphertext,'')) not between 1 and 8192
    or jsonb_typeof(p_campaigns) is distinct from 'array'
    or jsonb_array_length(p_campaigns)>10000 or octet_length(p_campaigns::text)>4194304 then return false; end if;
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections
    where provider='smartlead' and attempt_token=p_attempt_token for update;
  if not found then return false; end if;
  perform 1 from prospect_integrations.smartlead_inbox_actions
    where status in ('pending','applying') order by id for update;
  if not prospect_integrations.replace_smartlead_inbox_categories_v1(p_new_generation,p_categories) then return false; end if;
  update prospect_integrations.smartlead_inbox_actions set status='needs_review',attempt_token=null,lease_until=null,
    last_error_code='connection_changed'
    where status in ('pending','applying') and connection_generation is distinct from p_new_generation;
  update prospect_integrations.smartlead_inbox_settings set enabled=false,verified_generation=null,
    verified_contract=null,verified_at=null,initial_backfill_complete=false,scan_cycle=gen_random_uuid(),
    scan_mode='full',scan_offset=0,scan_from=null,scan_to=null,incremental_cursor=null,
    next_full_sync_at=now(),next_sync_at='infinity',status='needs_review',lease_token=null,lease_until=null,
    attempts=0,pages_scanned=0,rows_observed=0,last_synced_at=null,last_error_code='connection_changed',
    updated_by=left(p_actor,300),updated_at=now() where singleton;
  update public.integration_connections set credential_ciphertext=p_ciphertext,connected=true,checked_at=now(),
    campaigns=p_campaigns,generation=p_new_generation,updated_by=p_actor,attempt_token=gen_random_uuid(),
    next_request_at=clock_timestamp()+interval '2 seconds' where provider='smartlead';
  return found;
end $$;

create function public.disconnect_smartlead_connection_v1(p_actor text,p_new_generation uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare s prospect_integrations.smartlead_inbox_settings%rowtype;
  c public.integration_connections%rowtype;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_new_generation is null then return false; end if;
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for update;
  if not found then return false; end if;
  perform 1 from prospect_integrations.smartlead_inbox_actions
    where status in ('pending','applying') order by id for update;
  update prospect_integrations.smartlead_inbox_actions set status='needs_review',attempt_token=null,lease_until=null,
    last_error_code='connection_changed' where status in ('pending','applying');
  update prospect_integrations.smartlead_inbox_settings set enabled=false,verified_generation=null,
    verified_contract=null,verified_at=null,initial_backfill_complete=false,scan_cycle=gen_random_uuid(),
    scan_mode='full',scan_offset=0,scan_from=null,scan_to=null,incremental_cursor=null,
    next_full_sync_at=now(),next_sync_at='infinity',status='disabled',lease_token=null,lease_until=null,
    attempts=0,pages_scanned=0,rows_observed=0,last_synced_at=null,last_error_code=null,
    updated_by=left(p_actor,300),updated_at=now() where singleton;
  update public.integration_connections set credential_ciphertext=null,connected=false,checked_at=null,campaigns='[]'::jsonb,
    generation=p_new_generation,updated_by=p_actor,attempt_token=gen_random_uuid(),next_request_at='-infinity'
    where provider='smartlead';
  return found;
end $$;

create or replace function prospect_integrations.resolve_smartlead_inbox_client_v2(
  p_generation uuid,p_campaign text)
returns table(client_id text,mapping_status text)
language plpgsql stable security definer set search_path='' as $$
declare v_campaign text:=lower(regexp_replace(btrim(coalesce(p_campaign,'')),'[[:space:]]+',' ','g'));
  v_max integer; v_count integer;
begin
  if p_generation is null or v_campaign='' then return query select null::text,'unmatched'::text; return; end if;
  with candidates as (
    select m.client_id,m.prefix,length(m.prefix) size
    from prospect_integrations.smartlead_inbox_client_mappings m
    where m.connection_generation=p_generation and left(v_campaign,length(m.prefix))=m.prefix
      and (length(v_campaign)=length(m.prefix) or substring(v_campaign from length(m.prefix)+1 for 1)~'[[:space:]|:/_-]')
    union all
    select c.id,lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')),
      length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))
    from public.clients c
    where left(v_campaign,length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))))=lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))
      and (length(v_campaign)=length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))
        or substring(v_campaign from length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))+1 for 1)~'[[:space:]|:/_-]')
  ) select max(c.size),count(distinct c.client_id) into v_max,v_count
    from candidates c where c.size=(select max(size) from candidates);
  if coalesce(v_count,0)=0 then return query select null::text,'unmatched'::text;
  elsif v_count>1 then return query select null::text,'ambiguous'::text;
  else return query
    with candidates as (
      select m.client_id,m.prefix,length(m.prefix) size
      from prospect_integrations.smartlead_inbox_client_mappings m
      where m.connection_generation=p_generation and left(v_campaign,length(m.prefix))=m.prefix
        and (length(v_campaign)=length(m.prefix) or substring(v_campaign from length(m.prefix)+1 for 1)~'[[:space:]|:/_-]')
      union all
      select c.id,lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')),
        length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))
      from public.clients c
      where left(v_campaign,length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))))=lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))
        and (length(v_campaign)=length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))
          or substring(v_campaign from length(lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g')))+1 for 1)~'[[:space:]|:/_-]')
    ) select min(c.client_id),'matched'::text from candidates c where c.size=v_max;
  end if;
end $$;

create or replace function prospect_integrations.resolve_smartlead_inbox_client_v1(p_campaign text)
returns table(client_id text,mapping_status text)
language sql stable security definer set search_path='' as $$
  select r.client_id,r.mapping_status
  from public.integration_connections c
  cross join lateral prospect_integrations.resolve_smartlead_inbox_client_v2(c.generation,p_campaign) r
  where c.provider='smartlead';
$$;

create or replace function prospect_integrations.finish_smartlead_inbox_sync_v1(
  p_token uuid,p_state text,p_result jsonb,p_delay integer default 60)
returns boolean language plpgsql security definer set search_path='' as $$
declare s prospect_integrations.smartlead_inbox_settings%rowtype; item jsonb; resolved record;
  v_count integer; v_category integer; v_domain text; v_status text; v_client text;
  v_behavior text; c public.integration_connections%rowtype;
begin
  if p_state not in ('completed','retry','cooldown','connection_paused','needs_review') or p_result is null
    or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>1048576 then return false; end if;
  select * into s from prospect_integrations.smartlead_inbox_settings
    where singleton and lease_token=p_token and status='running' and lease_until>now() for update;
  if not found then return false; end if;
  select * into c from public.integration_connections where provider='smartlead' for share;
  if not c.connected or s.verified_generation is distinct from c.generation then
    update prospect_integrations.smartlead_inbox_settings set enabled=false,status='needs_review',lease_token=null,
      lease_until=null,last_error_code='connection_changed',updated_at=now() where singleton; return true;
  end if;
  if p_state='completed' then
    if jsonb_typeof(p_result->'rows') is distinct from 'array' or jsonb_array_length(p_result->'rows')>20
      or coalesce(p_result->>'contract','') not in ('official-v1','observed-flat-v1') then return false; end if;
    v_count:=jsonb_array_length(p_result->'rows');
    for item in select value from jsonb_array_elements(p_result->'rows') loop
      if jsonb_typeof(item)<>'object' or item->>'providerKey' is null or length(item->>'providerKey') not between 1 and 160
        or (item->>'campaignId')!~'^[0-9]+$' or length(btrim(coalesce(item->>'campaignName',''))) not between 1 and 300
        or length(coalesce(item->>'email','')) not between 3 and 254 or item->>'email'<>lower(btrim(item->>'email'))
        or item->>'email'!~'^[^[:space:]@,;<>]+@[^[:space:]@,;<>]+\.[^[:space:]@,;<>]+$'
        or coalesce(item->>'replyTime','')!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
        or (item->'categoryId' is not null and item->'categoryId'<>'null'::jsonb and
          (jsonb_typeof(item->'categoryId')<>'number' or (item->>'categoryId')!~'^[0-9]+$')) then return false; end if;
      if (item->>'campaignId')::numeric not between 1 and 9223372036854775807 then return false; end if;
      if item->'categoryId' is not null and item->'categoryId'<>'null'::jsonb
        and (item->>'categoryId')::numeric not between 1 and 2147483647 then return false; end if;
      begin perform (item->>'replyTime')::timestamptz; exception when others then return false; end;
      v_category:=case when item->'categoryId' is null or item->'categoryId'='null'::jsonb then null else (item->>'categoryId')::integer end;
      v_behavior:=null;
      if v_category is not null then select behavior into v_behavior
        from prospect_integrations.smartlead_inbox_categories
        where connection_generation=s.verified_generation and category_id=v_category; end if;
      v_domain:=split_part(item->>'email','@',2);
      select * into resolved from prospect_integrations.resolve_smartlead_inbox_client_v2(s.verified_generation,item->>'campaignName');
      v_client:=resolved.client_id;
      v_status:=case when v_category is not null and v_behavior is null then 'unsupported_category' else resolved.mapping_status end;
      insert into prospect_integrations.smartlead_inbox_observations(
        connection_generation,provider_key,campaign_id,campaign_name,email,domain,category_id,reply_time,client_id,mapping_status,last_cycle)
      values(s.verified_generation,item->>'providerKey',(item->>'campaignId')::bigint,btrim(item->>'campaignName'),
        item->>'email',v_domain,v_category,(item->>'replyTime')::timestamptz,v_client,v_status,s.scan_cycle)
      on conflict(connection_generation,provider_key) do update set campaign_id=excluded.campaign_id,
        campaign_name=excluded.campaign_name,email=excluded.email,domain=excluded.domain,category_id=excluded.category_id,
        reply_time=excluded.reply_time,client_id=excluded.client_id,mapping_status=excluded.mapping_status,
        last_cycle=excluded.last_cycle,last_seen_at=now();
      if v_behavior in ('email','email_and_domain') and v_status='matched' then
        insert into prospect_integrations.smartlead_inbox_actions as existing(
          connection_generation,provider_key,category_id,client_id,kind,value,status)
        values(s.verified_generation,item->>'providerKey',v_category,v_client,'email',item->>'email',
          case when exists(select 1 from prospect_integrations.smartlead_inbox_tombstones t
            where t.client_id=v_client and t.kind='email' and t.value=item->>'email') then 'manual_removed' else 'pending' end)
        on conflict(connection_generation,provider_key,category_id,client_id,kind,value) do update set
          status=case when existing.status='needs_review' and existing.last_error_code in ('connection_changed','categories_revalidated') then excluded.status else existing.status end,
          next_attempt_at=case when existing.status='needs_review' and existing.last_error_code in ('connection_changed','categories_revalidated') then now() else existing.next_attempt_at end,
          last_error_code=case when existing.status='needs_review' and existing.last_error_code in ('connection_changed','categories_revalidated') then null else existing.last_error_code end;
        if v_behavior='email_and_domain' then
          insert into prospect_integrations.smartlead_inbox_actions as existing(
            connection_generation,provider_key,category_id,client_id,kind,value,status)
          values(s.verified_generation,item->>'providerKey',v_category,v_client,'domain',v_domain,
            case when exists(select 1 from prospect_integrations.smartlead_inbox_tombstones t
              where t.client_id=v_client and t.kind='domain' and t.value=v_domain) then 'manual_removed' else 'pending' end)
          on conflict(connection_generation,provider_key,category_id,client_id,kind,value) do update set
            status=case when existing.status='needs_review' and existing.last_error_code in ('connection_changed','categories_revalidated') then excluded.status else existing.status end,
            next_attempt_at=case when existing.status='needs_review' and existing.last_error_code in ('connection_changed','categories_revalidated') then now() else existing.next_attempt_at end,
            last_error_code=case when existing.status='needs_review' and existing.last_error_code in ('connection_changed','categories_revalidated') then null else existing.last_error_code end;
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

-- The legacy confirmation entry point intentionally cannot enable a new
-- account without a generation-scoped category catalog.
create or replace function public.confirm_smartlead_inbox_contract_v1(
  p_actor text,p_generation uuid,p_contract text)
returns boolean language sql security definer set search_path='' as $$ select false $$;

create function public.confirm_smartlead_inbox_contract_v2(
  p_actor text,p_generation uuid,p_contract text,p_categories jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare s prospect_integrations.smartlead_inbox_settings%rowtype;
  c public.integration_connections%rowtype;
begin
  if p_contract not in ('official-v1','observed-flat-v1') then return false; end if;
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for share;
  if not found or not c.connected or c.generation is distinct from p_generation then return false; end if;
  perform 1 from prospect_integrations.smartlead_inbox_actions
    where connection_generation=p_generation and status in ('pending','applying') order by id for update;
  if not prospect_integrations.replace_smartlead_inbox_categories_v1(p_generation,p_categories) then return false; end if;
  update prospect_integrations.smartlead_inbox_actions set status='needs_review',attempt_token=null,lease_until=null,
    last_error_code='categories_revalidated'
    where connection_generation=p_generation and status in ('pending','applying');
  update prospect_integrations.smartlead_inbox_settings set verified_generation=p_generation,verified_contract=p_contract,
    verified_at=now(),enabled=false,status='paused',initial_backfill_complete=false,scan_cycle=gen_random_uuid(),
    scan_mode='full',scan_offset=0,scan_from=null,scan_to=null,incremental_cursor=null,next_full_sync_at=now(),
    next_sync_at='infinity',lease_token=null,lease_until=null,last_error_code=null,
    updated_by=left(coalesce(p_actor,''),300),updated_at=now() where singleton;
  return true;
end $$;

create or replace function public.set_smartlead_inbox_enabled_v1(p_actor text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare c public.integration_connections%rowtype; s prospect_integrations.smartlead_inbox_settings%rowtype;
begin
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for share;
  if p_enabled and (not c.connected or s.verified_generation is distinct from c.generation or s.verified_at is null
    or (select count(*) from prospect_integrations.smartlead_inbox_categories where connection_generation=c.generation and behavior='ignore')<>1
    or (select count(*) from prospect_integrations.smartlead_inbox_categories where connection_generation=c.generation and behavior='email_and_domain')<>1)
    then return false; end if;
  update prospect_integrations.smartlead_inbox_settings set enabled=p_enabled,
    status=case when p_enabled then 'queued' else 'paused' end,
    next_sync_at=case when p_enabled then now() else 'infinity' end,lease_token=null,lease_until=null,
    updated_by=left(coalesce(p_actor,''),300),updated_at=now() where singleton;
  return true;
end $$;

create or replace function public.set_smartlead_inbox_mapping_v1(
  p_actor text,p_prefix text,p_client text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_prefix text:=lower(regexp_replace(btrim(coalesce(p_prefix,'')),'[[:space:]]+',' ','g'));
  s prospect_integrations.smartlead_inbox_settings%rowtype; c public.integration_connections%rowtype;
begin
  if length(v_prefix) not between 1 and 200 or not exists(select 1 from public.clients where id=p_client) then return false; end if;
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for share;
  if not found or not c.connected then return false; end if;
  if p_enabled then
    insert into prospect_integrations.smartlead_inbox_client_mappings(connection_generation,prefix,client_id,created_by)
    values(c.generation,v_prefix,p_client,left(coalesce(p_actor,''),300))
    on conflict(connection_generation,prefix) do update set client_id=excluded.client_id,
      created_by=excluded.created_by,created_at=now();
  else
    delete from prospect_integrations.smartlead_inbox_client_mappings
    where connection_generation=c.generation and prefix=v_prefix and client_id=p_client;
  end if;
  update prospect_integrations.smartlead_inbox_settings set scan_mode='full',scan_offset=0,scan_from=null,scan_to=null,
    scan_cycle=gen_random_uuid(),next_full_sync_at=now(),next_sync_at=case when enabled then now() else next_sync_at end,
    status=case when enabled then 'queued' else status end,updated_by=left(coalesce(p_actor,''),300),updated_at=now()
    where singleton;
  return true;
end $$;

create or replace function public.smartlead_inbox_status_v1()
returns jsonb language sql stable security definer set search_path='' as $$
with current_connection as (
  select generation,connected from public.integration_connections where provider='smartlead'
), current_settings as (
  select s.*,c.generation,c.connected,
    (c.connected and s.verified_at is not null and s.verified_generation=c.generation) connection_current,
    ((select count(*) from prospect_integrations.smartlead_inbox_categories x
      where x.connection_generation=c.generation and x.behavior='ignore')=1
      and (select count(*) from prospect_integrations.smartlead_inbox_categories x
      where x.connection_generation=c.generation and x.behavior='email_and_domain')=1) category_ready
  from prospect_integrations.smartlead_inbox_settings s cross join current_connection c where s.singleton
)
select jsonb_build_object(
  'settings',(select (to_jsonb(s)-'lease_token'-'lease_until'-'verified_generation'-'generation'-'connected')
    from current_settings s),
  'counts',jsonb_build_object(
    'observed',(select count(*) from prospect_integrations.smartlead_inbox_observations o,current_connection c where o.connection_generation=c.generation),
    'unmatched',(select count(*) from prospect_integrations.smartlead_inbox_observations o,current_connection c where o.connection_generation=c.generation and o.mapping_status<>'matched'),
    'pending',(select count(*) from prospect_integrations.smartlead_inbox_actions a,current_connection c where a.connection_generation=c.generation and a.status in ('pending','applying')),
    'applied',(select count(*) from prospect_integrations.smartlead_inbox_actions a,current_connection c where a.connection_generation=c.generation and a.status='applied'),
    'manualRemoved',(select count(*) from prospect_integrations.smartlead_inbox_actions a,current_connection c where a.connection_generation=c.generation and a.status='manual_removed')),
  'unmatched',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select o.campaign_name,o.mapping_status,count(*)::integer replies
    from prospect_integrations.smartlead_inbox_observations o,current_connection c
    where o.connection_generation=c.generation and o.mapping_status<>'matched'
    group by o.campaign_name,o.mapping_status order by max(o.last_seen_at) desc limit 50)x),'[]'::jsonb),
  'mappings',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select m.prefix,m.client_id,c.name client_name
    from prospect_integrations.smartlead_inbox_client_mappings m
    join public.clients c on c.id=m.client_id cross join current_connection cc
    where m.connection_generation=cc.generation order by m.prefix)x),'[]'::jsonb),
  'categories',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select k.category_id,k.category_name,k.behavior from prospect_integrations.smartlead_inbox_categories k,current_connection c
    where k.connection_generation=c.generation order by k.category_name)x),'[]'::jsonb));
$$;

revoke execute on function prospect_integrations.replace_smartlead_inbox_categories_v1(uuid,jsonb)
  from public,anon,authenticated,service_role,prospect_integrator;
revoke execute on function prospect_integrations.resolve_smartlead_inbox_client_v2(uuid,text)
  from public,anon,authenticated,service_role,prospect_integrator;
revoke execute on function public.rotate_smartlead_connection_v1(text,uuid,text,jsonb,jsonb,uuid)
  from public,anon,authenticated;
revoke execute on function public.disconnect_smartlead_connection_v1(text,uuid)
  from public,anon,authenticated;
revoke execute on function public.confirm_smartlead_inbox_contract_v2(text,uuid,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.rotate_smartlead_connection_v1(text,uuid,text,jsonb,jsonb,uuid) to service_role;
grant execute on function public.disconnect_smartlead_connection_v1(text,uuid) to service_role;
grant execute on function public.confirm_smartlead_inbox_contract_v2(text,uuid,text,jsonb) to service_role;
