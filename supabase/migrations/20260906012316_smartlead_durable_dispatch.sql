do $$ begin
  if not exists(select 1 from pg_roles where rolname='prospect_integrator') then create role prospect_integrator nologin noinherit; end if;
end $$;
grant usage on schema prospect_integrations to prospect_integrator;
alter table prospect_integrations.jobs add column allow_active boolean not null default false,
  add column error_code text, add column last_attempt_at timestamptz;
alter table prospect_integrations.batches add column dispatch_payload jsonb,
  add column suppressed integer not null default 0,
  add column next_attempt_at timestamptz not null default now();
create index integration_inflight_lease on prospect_integrations.batches(lease_until) where status='sending';
alter table prospect_integrations.batches add column payload_bytes integer generated always as
  (octet_length(payload::text)+coalesce(octet_length(dispatch_payload::text),0)) stored;

-- Account for live payload bytes, not physical relation size: PostgreSQL reuses
-- pages after retention, and a high-water file size must not lock the queue forever.
create or replace function public.stage_integration_job_v1(p_actor text,p_request_id uuid,p_hash text,p_client text,p_campaign bigint,p_mode text,p_batches jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_hash text; v_batch jsonb; v_total integer:=0; v_ordinal integer:=0;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_request_id is null or p_hash is null or p_hash !~ '^[a-f0-9]{64}$'
    or p_campaign is null or p_campaign<=0 or p_mode is null or p_mode not in ('direct','verify')
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
    or coalesce((select sum(payload_bytes) from prospect_integrations.batches),0)>=134217728 then
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
create table prospect_integrations.campaign_requests (
  id uuid primary key default gen_random_uuid(),actor text not null,request_id uuid not null,
  client_id text not null references public.clients(id),name text not null check(length(name) between 1 and 160),
  generation uuid not null,status text not null default 'queued' check(status in ('queued','sending','completed','needs_review','cancelled')),
  token uuid,lease_until timestamptz,attempts integer not null default 0,next_attempt_at timestamptz not null default now(),
  campaign_id bigint,error_code text,created_at timestamptz not null default now(),unique(actor,request_id)
);
alter table prospect_integrations.campaign_requests enable row level security;
create index integration_creation_queue on prospect_integrations.campaign_requests(next_attempt_at,created_at) where status='queued';
revoke all on prospect_integrations.campaign_requests from public,anon,authenticated,service_role,prospect_integrator;

create function public.enqueue_integration_job_v1(p_actor text,p_job uuid,p_allow_active boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare c public.integration_connections%rowtype; j prospect_integrations.jobs%rowtype;
begin
  select * into c from public.integration_connections where provider='smartlead' for share;
  select * into j from prospect_integrations.jobs where id=p_job and actor=p_actor for update;
  if not found then return false; end if;
  if j.status in ('queued','running','completed') then return true; end if;
  if j.status<>'draft' or j.mode<>'direct' or j.expires_at<=now() or j.preview_summary is null
    or not c.connected or j.connection_generation is distinct from c.generation then return false; end if;
  perform 1 from prospect_integrations.client_campaigns where client_id=j.client_id and campaign_id=j.campaign_id and enabled and generation=c.generation for share;
  if not found then return false; end if;
  update prospect_integrations.jobs set status='queued',allow_active=coalesce(p_allow_active,false) where id=p_job;
  return true;
end;
$$;

create function public.request_smartlead_campaign_v1(p_actor text,p_request uuid,p_client text,p_name text)
returns uuid language plpgsql security definer set search_path='' as $$
declare c public.integration_connections%rowtype; r prospect_integrations.campaign_requests%rowtype; result uuid;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 160 then
    raise exception 'Invalid campaign request' using errcode='22023'; end if;
  select * into c from public.integration_connections where provider='smartlead' for update;
  select * into r from prospect_integrations.campaign_requests where actor=p_actor and request_id=p_request;
  if found then
    if r.client_id<>p_client or r.name<>btrim(p_name) then raise exception 'Request identity conflict' using errcode='22023'; end if;
    return r.id;
  end if;
  if not c.connected then raise exception 'Connect Smartlead first' using errcode='22023'; end if;
  if (select count(*) from prospect_integrations.campaign_requests where status in ('queued','sending'))>=10
    or (select count(*) from prospect_integrations.campaign_requests)>=1000 then raise exception 'Campaign queue full' using errcode='53300'; end if;
  insert into prospect_integrations.campaign_requests(actor,request_id,client_id,name,generation)
    values(p_actor,p_request,p_client,btrim(p_name),c.generation) returning id into result;
  return result;
end;
$$;

-- No HTTP request is made while this transaction holds a lock. A lost lease
-- marks an ambiguous external operation for review, never replays its POST.
create function prospect_integrations.claim_v1(p_kind text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.integration_connections%rowtype; j prospect_integrations.jobs%rowtype; b prospect_integrations.batches%rowtype; r prospect_integrations.campaign_requests%rowtype;
begin
  select * into c from public.integration_connections where provider='smartlead' for update;
  update prospect_integrations.jobs expired_job set status='needs_review',error_code='worker_lease_expired'
    where expired_job.status in ('queued','running') and exists(select 1 from prospect_integrations.batches expired_batch where expired_batch.job_id=expired_job.id and (expired_batch.status='needs_review' or (expired_batch.status='sending' and expired_batch.lease_until<=now())));
  update prospect_integrations.batches set status='needs_review',outcome='{"reason":"worker_lease_expired"}' where status='sending' and lease_until<=now();
  update prospect_integrations.campaign_requests set status='needs_review',error_code='worker_lease_expired' where status='sending' and lease_until<=now();
  update prospect_integrations.jobs set status='needs_review',error_code='draft_expired' where status in ('queued','running') and expires_at<=now();
  if not c.connected or c.next_request_at>now() or exists(select 1 from prospect_integrations.batches where status='sending')
    or exists(select 1 from prospect_integrations.campaign_requests where status='sending') then return null; end if;
  if p_kind='create' then
    select * into r from prospect_integrations.campaign_requests where status='queued' and next_attempt_at<=now() order by created_at for update skip locked limit 1;
    if not found then return null; end if;
    if r.generation<>c.generation or r.attempts>=8 or r.created_at<now()-interval '1 day' then
      update prospect_integrations.campaign_requests set status='needs_review',error_code='connection_changed_or_retry_limit' where id=r.id; return null; end if;
    update prospect_integrations.campaign_requests set status='sending',token=gen_random_uuid(),lease_until=now()+interval '120 seconds',attempts=attempts+1 where id=r.id returning * into r;
    update public.integration_connections set next_request_at=now()+interval '120 seconds' where provider='smartlead';
    return jsonb_build_object('kind','create','id',r.id,'token',r.token,'name',r.name,'attempts',r.attempts,'credential',c.credential_ciphertext);
  end if;
  if p_kind<>'upload' then return null; end if;
  select * into j from prospect_integrations.jobs queued_job where queued_job.status in ('queued','running')
    and exists(select 1 from prospect_integrations.batches queued_batch where queued_batch.job_id=queued_job.id and queued_batch.status='pending' and queued_batch.next_attempt_at<=now())
    order by coalesce(queued_job.last_attempt_at,queued_job.created_at) for update skip locked limit 1;
  if not found then return null; end if;
  if j.connection_generation is distinct from c.generation or not exists(select 1 from prospect_integrations.client_campaigns where client_id=j.client_id and campaign_id=j.campaign_id and enabled and generation=c.generation) then
    update prospect_integrations.jobs set status='needs_review',error_code='destination_changed' where id=j.id; return null; end if;
  select * into b from prospect_integrations.batches where job_id=j.id and status='pending' and next_attempt_at<=now() order by ordinal for update limit 1;
  if b.attempts>=8 then update prospect_integrations.jobs set status='needs_review',error_code='retry_limit' where id=j.id; return null; end if;
  update prospect_integrations.batches set status='sending',attempt_token=gen_random_uuid(),lease_until=now()+interval '120 seconds',attempts=attempts+1 where id=b.id returning * into b;
  update prospect_integrations.jobs set status='running',last_attempt_at=now(),error_code=null where id=j.id;
  update public.integration_connections set next_request_at=now()+interval '120 seconds' where provider='smartlead';
  return jsonb_build_object('kind','upload','id',b.id,'token',b.attempt_token,'campaign',j.campaign_id,'allowActive',j.allow_active,'attempts',b.attempts,'credential',c.credential_ciphertext);
end;
$$;

-- Called immediately before upload: recheck cancellation, binding and local
-- suppressions, including a source record deleted since preview was confirmed.
create function prospect_integrations.prepare_upload_v1(p_batch uuid,p_token uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.integration_connections%rowtype; j prospect_integrations.jobs%rowtype; b prospect_integrations.batches%rowtype; v_payload jsonb;
begin
  select * into c from public.integration_connections where provider='smartlead' for share;
  select j0.* into j from prospect_integrations.jobs j0 join prospect_integrations.batches b0 on b0.job_id=j0.id where b0.id=p_batch for update of j0;
  select * into b from prospect_integrations.batches where id=p_batch and attempt_token=p_token and status='sending' and lease_until>now() for update;
  if not found or j.status<>'running' or not c.connected or j.connection_generation is distinct from c.generation
    or not exists(select 1 from prospect_integrations.client_campaigns where client_id=j.client_id and campaign_id=j.campaign_id and enabled and generation=c.generation) then return null; end if;
  select coalesce(jsonb_agg(lead),'[]') into v_payload from jsonb_array_elements(b.payload) lead where
    exists(select 1 from jsonb_array_elements_text(j.preview_summary->'sourceIds'->(lead->>'email')) sid join public.prospects p on p.id=sid)
    and not exists(select 1 from public.client_blocklist bl where bl.client_id=j.client_id and (
      (bl.kind='email' and bl.value=lead->>'email') or (bl.kind='domain' and bl.value=split_part(lead->>'email','@',2))))
    and not exists(select 1 from jsonb_array_elements_text(j.preview_summary->'sourceIds'->(lead->>'email')) sid
      join public.prospects p on p.id=sid left join public.companies co on co.id=p.company_id
      where exists(select 1 from public.client_prospects cp where cp.client_id=j.client_id and cp.prospect_id=p.id and cp.status='blocked')
      or exists(select 1 from public.client_blocklist bl where bl.client_id=j.client_id and bl.kind='domain' and bl.value<>'' and bl.value=co.normalized_domain));
  update prospect_integrations.batches set dispatch_payload=v_payload,suppressed=jsonb_array_length(b.payload)-jsonb_array_length(v_payload) where id=p_batch;
  return v_payload;
end;
$$;

create function prospect_integrations.finish_v1(p_kind text,p_id uuid,p_token uuid,p_state text,p_result jsonb,p_delay integer default 5)
returns boolean language plpgsql security definer set search_path='' as $$
declare c public.integration_connections%rowtype; b prospect_integrations.batches%rowtype; r prospect_integrations.campaign_requests%rowtype; j prospect_integrations.jobs%rowtype; v_generation uuid;
begin
  if p_state not in ('completed','cooldown','read_retry','connection_paused','rejected','needs_review')
    or p_result is null or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>262144 then return false; end if;
  select * into c from public.integration_connections where provider='smartlead' for update;
  if p_kind='create' then
    select * into r from prospect_integrations.campaign_requests where id=p_id and token=p_token and status='sending' and lease_until>now() for update;
    if not found then return false; end if;
    v_generation:=r.generation;
    update prospect_integrations.campaign_requests set status=case when p_state='completed' then 'completed' when p_state in ('cooldown','read_retry') then 'queued' else 'needs_review' end,
      error_code=p_result->>'reason',campaign_id=(p_result->>'campaignId')::bigint,next_attempt_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),86400))) where id=p_id;
    if p_state='completed' and r.generation=c.generation and c.connected then
      insert into prospect_integrations.client_campaigns(campaign_id,client_id,generation,campaign_name,updated_by)
        values((p_result->>'campaignId')::bigint,r.client_id,r.generation,r.name,r.actor) on conflict(campaign_id) do nothing;
      if not exists(select 1 from prospect_integrations.client_campaigns where campaign_id=(p_result->>'campaignId')::bigint and client_id=r.client_id and enabled and generation=r.generation) then
        update prospect_integrations.campaign_requests set status='needs_review',error_code='campaign_destination_conflict' where id=p_id;
      end if;
    elsif p_state='completed' then
      update prospect_integrations.campaign_requests set status='needs_review',error_code='connection_changed_after_creation' where id=p_id;
    end if;
  elsif p_kind='upload' then
    select j0.* into j from prospect_integrations.jobs j0 join prospect_integrations.batches b0 on b0.job_id=j0.id where b0.id=p_id for update of j0;
    select * into b from prospect_integrations.batches where id=p_id and attempt_token=p_token and status='sending' and lease_until>now() for update;
    if not found then return false; end if;
    v_generation:=j.connection_generation;
    update prospect_integrations.batches set status=case when p_state='completed' then 'completed' when p_state in ('cooldown','read_retry') and j.status='running' then 'pending' else 'needs_review' end,
      outcome=p_result,next_attempt_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),86400))) where id=p_id;
    update prospect_integrations.jobs set status=case when exists(select 1 from prospect_integrations.batches where job_id=j.id and status='needs_review') or j.status='needs_review' then 'needs_review'
      when not exists(select 1 from prospect_integrations.batches where job_id=j.id and status<>'completed') then 'completed' else status end,
      error_code=p_result->>'reason' where id=j.id;
  else return false; end if;
  update public.integration_connections set next_request_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),86400))),
    connected=case when p_state='connection_paused' then false else connected end where provider='smartlead' and generation=v_generation;
  return true;
end;
$$;

create function public.smartlead_progress_v1(p_actor text)
returns jsonb language sql stable security definer set search_path='' as $$
select jsonb_build_object('creations',coalesce((select jsonb_agg(to_jsonb(r)) from (
  select id,name,client_id,status,campaign_id,error_code,created_at from prospect_integrations.campaign_requests where actor=p_actor order by created_at desc limit 50) r),'[]'::jsonb),
  'deliveries',coalesce((select jsonb_agg(to_jsonb(r)) from (
    select j.id,j.status,j.error_code,j.campaign_id,
      coalesce(sum((b.outcome->>'addedCount')::integer),0) as added,
      coalesce(sum((b.outcome->>'skippedCount')::integer),0) as skipped,
      coalesce(sum(b.suppressed),0) as suppressed
    from prospect_integrations.jobs j left join prospect_integrations.batches b on b.job_id=j.id
    where j.actor=p_actor group by j.id order by j.created_at desc limit 50) r),'[]'::jsonb));
$$;

create function public.smartlead_report_v1(p_actor text,p_job uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_agg(jsonb_build_object('status',b.status,'outcome',b.outcome,
    'emails',(select jsonb_agg(x->>'email') from jsonb_array_elements(b.payload) x),
    'dispatchEmails',case when b.dispatch_payload is null then null else coalesce((select jsonb_agg(x->>'email') from jsonb_array_elements(b.dispatch_payload) x),'[]'::jsonb) end))
  from prospect_integrations.jobs j join prospect_integrations.batches b on b.job_id=j.id where j.actor=p_actor and j.id=p_job;
$$;

-- Bounded 30-day history retention. Never deletes prospects or provider data;
-- unresolved/active jobs are kept for manual review, not silently discarded.
create function prospect_integrations.cleanup_v1()
returns integer language plpgsql security definer set search_path='' as $$
declare ids uuid[]; removed integer;
begin
  select array_agg(id) into ids from (select id from prospect_integrations.jobs where status in ('completed','cancelled')
    and created_at<now()-interval '30 days' order by created_at for update skip locked limit 10) old_jobs;
  delete from prospect_integrations.batches where job_id=any(ids);
  delete from prospect_integrations.jobs where id=any(ids);
  get diagnostics removed=row_count;
  delete from prospect_integrations.campaign_requests where id in (select id from prospect_integrations.campaign_requests
    where status in ('completed','cancelled') and created_at<now()-interval '30 days' order by created_at limit 10);
  return removed;
end;
$$;

revoke execute on function public.enqueue_integration_job_v1(text,uuid,boolean) from public,anon,authenticated;
revoke execute on function public.stage_integration_job_v1(text,uuid,text,text,bigint,text,jsonb) from public,anon,authenticated;
revoke execute on function public.request_smartlead_campaign_v1(text,uuid,text,text) from public,anon,authenticated;
revoke execute on function public.smartlead_progress_v1(text) from public,anon,authenticated;
revoke execute on function public.smartlead_report_v1(text,uuid) from public,anon,authenticated;
revoke execute on function prospect_integrations.cleanup_v1() from public,anon,authenticated;
revoke execute on function prospect_integrations.claim_v1(text) from public,anon,authenticated;
revoke execute on function prospect_integrations.prepare_upload_v1(uuid,uuid) from public,anon,authenticated;
revoke execute on function prospect_integrations.finish_v1(text,uuid,uuid,text,jsonb,integer) from public,anon,authenticated;
grant execute on function public.enqueue_integration_job_v1(text,uuid,boolean) to service_role;
grant execute on function public.request_smartlead_campaign_v1(text,uuid,text,text) to service_role;
grant execute on function public.smartlead_progress_v1(text) to service_role;
grant execute on function public.smartlead_report_v1(text,uuid) to service_role;
grant execute on function prospect_integrations.cleanup_v1() to prospect_integrator;
grant execute on function prospect_integrations.claim_v1(text) to prospect_integrator;
grant execute on function prospect_integrations.prepare_upload_v1(uuid,uuid) to prospect_integrator;
grant execute on function prospect_integrations.finish_v1(text,uuid,uuid,text,jsonb,integer) to prospect_integrator;
