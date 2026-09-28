-- Bound manual verification by unique normalized work email while preserving
-- the exact authorized candidate set and every person who shares a selected
-- address. Omitting maxEmails retains the original unlimited behavior.

alter table prospect_verification.runs
  add column if not exists max_emails integer,
  add column if not exists eligible_email_count integer,
  add column if not exists selected_email_count integer;

do $$ begin
  alter table prospect_verification.runs add constraint verification_runs_max_emails_check
    check (max_emails is null or max_emails between 1 and 200000);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table prospect_verification.runs add constraint verification_runs_email_counts_check
    check (
      (eligible_email_count is null or eligible_email_count >= 0)
      and (selected_email_count is null or selected_email_count >= 0)
      and (eligible_email_count is null or selected_email_count is null or selected_email_count <= eligible_email_count)
      and (max_emails is null or selected_email_count is null or selected_email_count <= max_emails)
    );
exception when duplicate_object then null; end $$;

create or replace function public.request_email_verification_v1(
  p_request_id uuid, p_payload jsonb, p_actor_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_hash text := pg_catalog.md5((
  (coalesce(p_payload,'{}'::jsonb)-'companyScope'-'intentCompanyScope') ||
  jsonb_build_object('companyScope',coalesce(p_payload->'intentCompanyScope',p_payload->'companyScope','{}'::jsonb))
)::text);
declare v_run prospect_verification.runs;
declare v_scope text := coalesce(p_payload->>'scope', '');
declare v_max_emails integer;
begin
  if v_scope not in ('all','filtered') then raise exception 'Invalid verification scope' using errcode='22023'; end if;
  if jsonb_typeof(coalesce(p_payload->'filters', '[]'::jsonb)) <> 'array' then raise exception 'Filters must be an array' using errcode='22023'; end if;
  if length(coalesce(p_payload->>'search','')) > 500 then raise exception 'Search is too long' using errcode='22023'; end if;
  if p_payload ? 'maxEmails' and p_payload->'maxEmails' <> 'null'::jsonb then
    if jsonb_typeof(p_payload->'maxEmails') <> 'number' then
      raise exception 'Maximum emails must be an integer' using errcode='22023';
    end if;
    begin
      v_max_emails := (p_payload->>'maxEmails')::integer;
    exception when invalid_text_representation or numeric_value_out_of_range then
      raise exception 'Maximum emails must be an integer' using errcode='22023';
    end;
    if v_max_emails not between 1 and 200000 then
      raise exception 'Maximum emails must be between 1 and 200000' using errcode='22023';
    end if;
  end if;
  insert into prospect_verification.runs(
    request_id,payload_hash,actor_id,scope,search,filters,company_scope,
    force_reverify,priority,max_emails
  )
  values(p_request_id,v_hash,p_actor_id,v_scope,
    case when v_scope='filtered' then coalesce(p_payload->>'search','') else '' end,
    case when v_scope='filtered' then coalesce(p_payload->'filters','[]'::jsonb) else '[]'::jsonb end,
    case when v_scope='filtered' then coalesce(p_payload->'companyScope','{}'::jsonb) else '{}'::jsonb end,
    coalesce((p_payload->>'forceReverify')::boolean,false),case when v_scope='filtered' then 30 else 5 end,
    v_max_emails)
  on conflict(request_id) do nothing returning * into v_run;
  if v_run.id is null then
    select * into v_run from prospect_verification.runs where request_id=p_request_id;
    if v_run.payload_hash <> v_hash then raise exception 'Request ID was already used with a different payload' using errcode='23505'; end if;
  end if;
  return to_jsonb(v_run);
end $$;

-- A capped run first freezes its complete authorized candidate population in a
-- transaction-local table. The cap is then applied to DISTINCT normalized
-- addresses in bytewise order, and all candidate people carrying those
-- addresses become targets. This makes selection deterministic without
-- weakening filters, company scope, or the people-per-company rule.
create or replace function public.prepare_email_verification_run_v1(
  p_run_id uuid,p_preparation_token uuid,p_limit integer default 2000000
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_run prospect_verification.runs;
declare v_prefilter text;
declare v_predicate text;
declare v_scope_cte text := '';
declare v_scope_join text := '';
declare v_has_scope boolean;
declare v_has_cap boolean;
declare v_inserted bigint;
declare v_eligible_emails bigint;
declare v_selected_emails bigint;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('verification-prepare:'||p_run_id::text,7193)) then
    select * into v_run from prospect_verification.runs where id=p_run_id;
    return to_jsonb(v_run);
  end if;
  select * into v_run from prospect_verification.runs where id=p_run_id;
  if v_run.id is null then raise exception 'Verification run not found' using errcode='P0002'; end if;
  if v_run.snapshot_complete or v_run.preparation_token is distinct from p_preparation_token
     or v_run.status not in ('preparing','paused','cancelled') then return to_jsonb(v_run); end if;
  begin
    if v_run.scope <> 'import' then
      v_has_cap := exists(select 1 from jsonb_array_elements(v_run.filters) f where f->>'field'='__max_people_per_company');
      if v_run.scope='all' then
        v_predicate:='true'; v_prefilter:='true';
      else
        v_prefilter:=public.prospect_prefilter_sql(v_run.search,v_run.filters);
        v_predicate:=coalesce(public.prospect_filter_sql_v1(v_run.search,v_run.filters),
          format('public.prospect_index_matches_v1(pi,%L,%L::jsonb)',v_run.search,v_run.filters::text));
      end if;
      v_has_scope:=v_run.scope='filtered' and v_run.company_scope<>'{}'::jsonb
        and (btrim(coalesce(v_run.company_scope->>'search',''))<>'' or coalesce(v_run.company_scope->'filters','[]'::jsonb)<>'[]'::jsonb);

      if v_run.max_emails is not null then
        drop table if exists pg_temp.verification_candidate_people;
        drop table if exists pg_temp.verification_selected_emails;
        create temporary table verification_candidate_people(
          prospect_id text primary key,
          normalized_email text not null,
          email_revision bigint not null,
          deletion_epoch bigint not null,
          generation_floor integer not null
        ) on commit drop;
        create temporary table verification_selected_emails(
          normalized_email text primary key
        ) on commit drop;

        if v_has_cap then
          execute format($q$
            insert into pg_temp.verification_candidate_people(
              prospect_id,normalized_email,email_revision,deletion_epoch,generation_floor
            )
            select pi.id,prospect_verification.normalize_email(pi.work_email),pi.work_email_revision,
              coalesce(pd.deletion_epoch,0),coalesce((select max(ec.generation) from prospect_verification.email_checks ec
                where ec.normalized_email=prospect_verification.normalize_email(pi.work_email) and ec.execution_state='completed'),0)
            from public.prospect_capped_candidate_ids_v1(%L,%L::jsonb,null,%L::jsonb) candidate
            join public.prospect_index pi on pi.id=candidate.prospect_id
            left join prospect_verification.prospect_deletions pd on pd.prospect_id=pi.id
            where nullif(prospect_verification.normalize_email(pi.work_email),'') is not null
            on conflict do nothing$q$,v_run.search,v_run.filters::text,v_run.company_scope::text);
        else
          if v_has_scope then
            v_scope_cte:=format('with eligible_companies as materialized (select company_id from public.company_scope_ids_v2(null,%L::jsonb)) ',v_run.company_scope::text);
            v_scope_join:=' join eligible_companies eligible on eligible.company_id=pi.company_id ';
          end if;
          execute format($q$
            insert into pg_temp.verification_candidate_people(
              prospect_id,normalized_email,email_revision,deletion_epoch,generation_floor
            )
            %s select pi.id,prospect_verification.normalize_email(pi.work_email),pi.work_email_revision,
            coalesce(pd.deletion_epoch,0),coalesce((select max(ec.generation) from prospect_verification.email_checks ec
              where ec.normalized_email=prospect_verification.normalize_email(pi.work_email) and ec.execution_state='completed'),0)
            from public.prospect_index pi %s
            left join prospect_verification.prospect_deletions pd on pd.prospect_id=pi.id
            where nullif(prospect_verification.normalize_email(pi.work_email),'') is not null
              and (%s) and (%s) on conflict do nothing$q$,v_scope_cte,v_scope_join,v_prefilter,v_predicate);
        end if;

        select count(distinct normalized_email) into v_eligible_emails
        from pg_temp.verification_candidate_people;
        insert into pg_temp.verification_selected_emails(normalized_email)
        select normalized_email
        from (select distinct normalized_email from pg_temp.verification_candidate_people) eligible_email
        order by normalized_email collate "C"
        limit v_run.max_emails;
        get diagnostics v_selected_emails = row_count;

        insert into prospect_verification.run_targets(
          run_id,prospect_id,normalized_email,email_revision,deletion_epoch,generation_floor
        )
        select p_run_id,c.prospect_id,c.normalized_email,c.email_revision,c.deletion_epoch,c.generation_floor
        from pg_temp.verification_candidate_people c
        join pg_temp.verification_selected_emails selected using(normalized_email)
        on conflict do nothing;
      else
        if v_has_cap then
          execute format($q$
            insert into prospect_verification.run_targets(run_id,prospect_id,normalized_email,email_revision,deletion_epoch,generation_floor)
            select %L::uuid,pi.id,prospect_verification.normalize_email(pi.work_email),pi.work_email_revision,
              coalesce(pd.deletion_epoch,0),coalesce((select max(ec.generation) from prospect_verification.email_checks ec
                where ec.normalized_email=prospect_verification.normalize_email(pi.work_email) and ec.execution_state='completed'),0)
            from public.prospect_capped_candidate_ids_v1(%L,%L::jsonb,null,%L::jsonb) candidate
            join public.prospect_index pi on pi.id=candidate.prospect_id
            left join prospect_verification.prospect_deletions pd on pd.prospect_id=pi.id
            where nullif(prospect_verification.normalize_email(pi.work_email),'') is not null
            on conflict do nothing$q$,p_run_id,v_run.search,v_run.filters::text,v_run.company_scope::text);
        else
          if v_has_scope then
            v_scope_cte:=format('with eligible_companies as materialized (select company_id from public.company_scope_ids_v2(null,%L::jsonb)) ',v_run.company_scope::text);
            v_scope_join:=' join eligible_companies eligible on eligible.company_id=pi.company_id ';
          end if;
          execute format($q$
            insert into prospect_verification.run_targets(run_id,prospect_id,normalized_email,email_revision,deletion_epoch,generation_floor)
            %s select %L::uuid,pi.id,prospect_verification.normalize_email(pi.work_email),pi.work_email_revision,
            coalesce(pd.deletion_epoch,0),coalesce((select max(ec.generation) from prospect_verification.email_checks ec
              where ec.normalized_email=prospect_verification.normalize_email(pi.work_email) and ec.execution_state='completed'),0)
            from public.prospect_index pi %s
            left join prospect_verification.prospect_deletions pd on pd.prospect_id=pi.id
            where nullif(prospect_verification.normalize_email(pi.work_email),'') is not null
              and (%s) and (%s) on conflict do nothing$q$,v_scope_cte,p_run_id,v_scope_join,v_prefilter,v_predicate);
        end if;
      end if;
    end if;

    select count(*) into v_inserted from prospect_verification.run_targets where run_id=p_run_id;
    if v_run.scope <> 'import' and v_run.max_emails is null then
      select count(distinct normalized_email),count(distinct normalized_email)
      into v_eligible_emails,v_selected_emails
      from prospect_verification.run_targets where run_id=p_run_id;
    end if;
    if v_inserted>greatest(1,coalesce(p_limit,2000000)) then
      raise exception 'Verification selection has % people; configured preparation limit is %',v_inserted,p_limit using errcode='54000';
    end if;
  exception when query_canceled then
    update prospect_verification.runs set status='failed',last_error='Verification preparation timed out.',completed_at=now(),updated_at=now() where id=p_run_id returning * into v_run;
    return to_jsonb(v_run);
  when others then
    delete from prospect_verification.run_targets where run_id=p_run_id;
    update prospect_verification.runs set status='failed',last_error=left(sqlerrm,500),completed_at=now(),updated_at=now() where id=p_run_id returning * into v_run;
    return to_jsonb(v_run);
  end;
  update prospect_verification.runs set snapshot_complete=true,total_count=v_inserted,
    eligible_email_count=v_eligible_emails,selected_email_count=v_selected_emails,
    preparation_lease_expires_at=null,
    status=case when status in ('paused','cancelled') then status when v_inserted=0 then 'completed' else 'running' end,
    completed_at=case when status='cancelled' or (status not in ('paused','cancelled') and v_inserted=0) then coalesce(completed_at,now()) else completed_at end,
    updated_at=now()
  where id=p_run_id and preparation_token=p_preparation_token
    and status in ('preparing','paused','cancelled') returning * into v_run;
  if v_run.id is null then
    delete from prospect_verification.run_targets where run_id=p_run_id;
    select * into v_run from prospect_verification.runs where id=p_run_id;
  end if;
  return to_jsonb(v_run);
end $$;

revoke execute on function public.request_email_verification_v1(uuid,jsonb,uuid) from public,anon,authenticated;
revoke execute on function public.prepare_email_verification_run_v1(uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.request_email_verification_v1(uuid,jsonb,uuid) to service_role;
do $$ begin
  if exists(select 1 from pg_roles where rolname='prospect_verifier') then
    execute 'grant execute on function public.prepare_email_verification_run_v1(uuid,uuid,integer) to prospect_verifier';
  end if;
end $$;

comment on column prospect_verification.runs.max_emails is
  'Optional manual-run cap on distinct normalized work emails; NULL preserves unlimited legacy behavior.';
comment on column prospect_verification.runs.eligible_email_count is
  'Distinct normalized work emails in the full authorized candidate set at snapshot time.';
comment on column prospect_verification.runs.selected_email_count is
  'Distinct normalized work emails selected for this immutable run snapshot.';
