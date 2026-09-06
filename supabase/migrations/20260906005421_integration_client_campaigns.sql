-- Additive: existing credentials and prospect data are untouched.
alter table public.integration_connections
  add column generation uuid not null default gen_random_uuid(),
  add column campaigns jsonb not null default '[]'::jsonb
    check (jsonb_typeof(campaigns)='array' and jsonb_array_length(campaigns)<=10000 and octet_length(campaigns::text)<=4194304);

create table prospect_integrations.client_campaigns (
  campaign_id bigint primary key check (campaign_id>0),
  client_id text not null references public.clients(id),
  generation uuid not null,
  campaign_name text not null,
  enabled boolean not null default true,
  updated_by text not null,
  updated_at timestamptz not null default now()
);
create index integration_campaign_client on prospect_integrations.client_campaigns(client_id) where enabled;
alter table prospect_integrations.client_campaigns enable row level security;
revoke all on prospect_integrations.client_campaigns from public,anon,authenticated,service_role;

create function public.integration_destinations_v1()
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(d)),'[]'::jsonb) from (
    select m.client_id,m.campaign_id,m.campaign_name,m.updated_at,
      (c.connected and c.generation=m.generation) as connection_current
    from prospect_integrations.client_campaigns m
    join public.integration_connections c on c.provider='smartlead'
    where m.enabled order by m.client_id,m.campaign_id
  ) d;
$$;

create function public.set_integration_destination_v1(p_actor text,p_client text,p_campaign bigint,p_enabled boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_connection public.integration_connections%rowtype; v_campaign jsonb; v_owner text;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_client is null
    or p_campaign is null or p_campaign<=0 or p_enabled is null then
    raise exception 'Invalid destination' using errcode='22023'; end if;
  -- Serializes mapping changes against credential replacement/disconnect.
  select * into v_connection from public.integration_connections where provider='smartlead' for update;
  if not found then raise exception 'Connection missing' using errcode='22023'; end if;
  if not p_enabled then
    update prospect_integrations.client_campaigns set enabled=false,updated_by=p_actor,updated_at=now()
      where campaign_id=p_campaign and client_id=p_client and enabled;
    return found;
  end if;
  if not v_connection.connected or v_connection.checked_at is null
    or v_connection.checked_at<now()-interval '15 minutes' then
    raise exception 'Refresh Smartlead campaigns before mapping' using errcode='22023'; end if;
  select value into v_campaign from jsonb_array_elements(v_connection.campaigns)
    where value->>'id'=p_campaign::text;
  if not found then raise exception 'Campaign not in connected account' using errcode='22023'; end if;
  perform 1 from public.clients where id=p_client;
  if not found then raise exception 'Client not found' using errcode='22023'; end if;
  select client_id into v_owner from prospect_integrations.client_campaigns where campaign_id=p_campaign and enabled;
  if found and v_owner<>p_client then
    raise exception 'Campaign already assigned to another client' using errcode='22023'; end if;
  if (select count(*) from prospect_integrations.client_campaigns)>=10000
    and not exists(select 1 from prospect_integrations.client_campaigns where campaign_id=p_campaign) then
    raise exception 'Destination capacity reached' using errcode='53300'; end if;
  insert into prospect_integrations.client_campaigns(campaign_id,client_id,generation,campaign_name,updated_by)
    values(p_campaign,p_client,v_connection.generation,left(v_campaign->>'name',300),p_actor)
    on conflict(campaign_id) do update set client_id=excluded.client_id,generation=excluded.generation,
      campaign_name=excluded.campaign_name,enabled=true,updated_by=excluded.updated_by,updated_at=now();
  return true;
end;
$$;
revoke execute on function public.integration_destinations_v1() from public,anon,authenticated;
revoke execute on function public.set_integration_destination_v1(text,text,bigint,boolean) from public,anon,authenticated;
grant execute on function public.integration_destinations_v1() to service_role;
grant execute on function public.set_integration_destination_v1(text,text,bigint,boolean) to service_role;
