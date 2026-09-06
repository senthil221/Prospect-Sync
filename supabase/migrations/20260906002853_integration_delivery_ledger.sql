create schema prospect_integrations;
revoke all on schema prospect_integrations from public, anon, authenticated;

create table prospect_integrations.jobs (
  id uuid primary key default gen_random_uuid(),
  actor text not null,
  request_id uuid not null,
  content_hash text not null,
  client_id text not null references public.clients(id),
  campaign_id bigint not null check (campaign_id>0),
  mode text not null check (mode in ('direct','verify')),
  status text not null default 'draft' check (status in ('draft','queued','running','completed','needs_review','cancelled')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '1 day',
  unique(actor, request_id)
);
create table prospect_integrations.batches (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references prospect_integrations.jobs(id),
  ordinal integer not null,
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending','sending','completed','needs_review','cancelled')),
  attempt_token uuid,
  attempts integer not null default 0,
  lease_until timestamptz,
  outcome jsonb,
  unique(job_id,ordinal),
  check (jsonb_typeof(payload)='array' and jsonb_array_length(payload) between 1 and 400),
  check (octet_length(payload::text)<=524288)
);
create index integration_jobs_queue on prospect_integrations.jobs(created_at) where status in ('queued','running');
create index integration_jobs_actor on prospect_integrations.jobs(actor,created_at desc);
create index integration_batches_work on prospect_integrations.batches(job_id,ordinal) where status in ('pending','sending');
alter table prospect_integrations.jobs enable row level security;
alter table prospect_integrations.batches enable row level security;
revoke all on all tables in schema prospect_integrations from public, anon, authenticated;

-- Only prevalidated, bounded snapshots reach this server-only function. A reused
-- request ID with changed input is an error, never a different recipient list.
create function public.stage_integration_job_v1(p_actor text,p_request_id uuid,p_hash text,p_client text,p_campaign bigint,p_mode text,p_batches jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_hash text; v_batch jsonb; v_total integer:=0; v_ordinal integer:=0;
begin
  if length(p_actor) not between 1 and 300 or p_request_id is null or p_hash !~ '^[a-f0-9]{64}$'
    or p_campaign is null or p_campaign<=0 or p_mode not in ('direct','verify')
    or jsonb_typeof(p_batches) is distinct from 'array' or jsonb_array_length(p_batches) not between 1 and 50
    or octet_length(p_batches::text)>5242880 then raise exception 'Invalid integration snapshot' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('integration-admission-v1',0));
  select id,content_hash into v_id,v_hash from prospect_integrations.jobs where actor=p_actor and request_id=p_request_id;
  if found then
    if v_hash<>p_hash then raise exception 'Request identity conflict' using errcode='22023'; end if;
    return v_id;
  end if;
  if (select count(*) from prospect_integrations.jobs where status in ('draft','queued','running'))>=10
    or (select count(*) from prospect_integrations.jobs)>=1000
    or pg_total_relation_size('prospect_integrations.batches')>=268435456 then
    raise exception 'Integration queue is full' using errcode='53300'; end if;
  insert into prospect_integrations.jobs(actor,request_id,content_hash,client_id,campaign_id,mode)
    values(p_actor,p_request_id,p_hash,p_client,p_campaign,p_mode) returning id into v_id;
  for v_batch in select value from jsonb_array_elements(p_batches) loop
    if jsonb_typeof(v_batch) is distinct from 'array' then raise exception 'Invalid batch' using errcode='22023'; end if;
    v_total:=v_total+jsonb_array_length(v_batch);
    if v_total>5000 then raise exception 'Snapshot exceeds 5000 leads' using errcode='22023'; end if;
    insert into prospect_integrations.batches(job_id,ordinal,payload) values(v_id,v_ordinal,v_batch);
    v_ordinal:=v_ordinal+1;
  end loop;
  return v_id;
end;
$$;

create function public.integration_job_status_v1(p_actor text,p_job uuid default null)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from (
   select j.id,j.client_id,j.campaign_id,j.mode,j.status,j.created_at,j.expires_at,
     (select sum(jsonb_array_length(b.payload)) from prospect_integrations.batches b where b.job_id=j.id) as total,
     (select count(*) from prospect_integrations.batches b where b.job_id=j.id and b.status='completed') as completed_batches,
     (select count(*) from prospect_integrations.batches b where b.job_id=j.id) as batches
   from prospect_integrations.jobs j where j.actor=p_actor and (p_job is null or j.id=p_job)
   order by j.created_at desc limit 50
 ) s;
$$;

-- Explicit cancellation never deletes or pretends to retract completed uploads.
create function public.cancel_integration_job_v1(p_actor text,p_job uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  select id into v_id from prospect_integrations.jobs where id=p_job and actor=p_actor and status in ('draft','queued','running') for update;
  if not found then return false; end if;
  update prospect_integrations.batches set status='cancelled' where job_id=v_id and status='pending';
  update prospect_integrations.jobs set status=case when exists(select 1 from prospect_integrations.batches where job_id=v_id and status='sending') then 'needs_review' else 'cancelled' end where id=v_id;
  return true;
end;
$$;

-- Dispatch is deliberately a separate future release gate. There is no RPC here
-- that can enqueue a draft or expose payloads to browser roles.
revoke execute on function public.stage_integration_job_v1(text,uuid,text,text,bigint,text,jsonb) from public,anon,authenticated;
revoke execute on function public.integration_job_status_v1(text,uuid) from public,anon,authenticated;
revoke execute on function public.cancel_integration_job_v1(text,uuid) from public,anon,authenticated;
grant execute on function public.stage_integration_job_v1(text,uuid,text,text,bigint,text,jsonb) to service_role;
grant execute on function public.integration_job_status_v1(text,uuid) to service_role;
grant execute on function public.cancel_integration_job_v1(text,uuid) to service_role;
