alter table prospect_integrations.jobs add column connection_generation uuid,
  add column preview_summary jsonb check (octet_length(preview_summary::text)<=262144);

create function public.integration_selection_v1(p_client text,p_ids text[])
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
  if p_ids is null or cardinality(p_ids) not between 1 and 400
    or exists(select 1 from unnest(p_ids) x where x is null or length(x) not between 1 and 200)
    or not exists(select 1 from public.clients where id=p_client) then
    raise exception 'Invalid selection' using errcode='22023'; end if;
  if (select count(*) from public.prospects where id=any(p_ids))<>(select count(distinct x) from unnest(p_ids) x) then
    raise exception 'Selection changed; reload prospects' using errcode='22023'; end if;
  if exists(select 1 from public.prospects where id=any(p_ids) and octet_length(all_data::text)>65536) then
    raise exception 'Source record exceeds preview size limit' using errcode='22023'; end if;
  select jsonb_agg(jsonb_build_object('id',p.id,'fields',jsonb_build_object(
    'first_name',p.first_name,'last_name',p.last_name,'work_email',p.work_email,'personal_email',p.personal_email,
    'company_name',coalesce(c.name,''),'website',coalesce(c.domain,''),'phone_number',p.mobile_number,
    'location',concat_ws(', ',nullif(p.city,''),nullif(p.state,''),nullif(p.country,'')),
    'linkedin_profile',p.linkedin_url,'title',p.title), 'custom',p.all_data,
    'suppressed',exists(select 1 from public.client_prospects cp where cp.client_id=p_client and cp.prospect_id=p.id and cp.status='blocked')
      or exists(select 1 from public.client_blocklist b where b.client_id=p_client and b.value<>'' and (
        (b.kind='email' and b.value in (lower(btrim(p.work_email)),lower(btrim(p.personal_email))))
        or (b.kind='domain' and b.value in (lower(coalesce(c.normalized_domain,'')),lower(split_part(p.work_email,'@',2)),lower(split_part(p.personal_email,'@',2))))))) order by p.id)
    into v_result from public.prospects p left join public.companies c on c.id=p.company_id where p.id=any(p_ids);
  if octet_length(v_result::text)>2097152 then raise exception 'Selection exceeds preview byte limit' using errcode='22023'; end if;
  return v_result;
end;
$$;

create function public.stage_mapped_integration_job_v1(p_actor text,p_request uuid,p_hash text,p_client text,p_campaign bigint,p_batches jsonb,p_summary jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_generation uuid; v_job uuid;
begin
  select generation into v_generation from public.integration_connections where provider='smartlead' and connected for share;
  if not found then raise exception 'Connect Smartlead first' using errcode='22023'; end if;
  perform 1 from prospect_integrations.client_campaigns where campaign_id=p_campaign and client_id=p_client
    and enabled and generation=v_generation for share;
  if not found then raise exception 'Map this campaign to the client first' using errcode='22023'; end if;
  if p_summary is null or jsonb_typeof(p_summary)<>'object' or octet_length(p_summary::text)>262144 then
    raise exception 'Invalid preview summary' using errcode='22023'; end if;
  v_job:=public.stage_integration_job_v1(p_actor,p_request,p_hash,p_client,p_campaign,'direct',p_batches);
  update prospect_integrations.jobs set connection_generation=v_generation,preview_summary=p_summary
    where id=v_job and status='draft' and (connection_generation is null or connection_generation=v_generation);
  if not found then raise exception 'Preview is no longer editable' using errcode='22023'; end if;
  return v_job;
end;
$$;
revoke execute on function public.integration_selection_v1(text,text[]) from public,anon,authenticated;
revoke execute on function public.stage_mapped_integration_job_v1(text,uuid,text,text,bigint,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.integration_selection_v1(text,text[]) to service_role;
grant execute on function public.stage_mapped_integration_job_v1(text,uuid,text,text,bigint,jsonb,jsonb) to service_role;
