-- The client-facing operations that client_prospects makes possible:
-- push master records into a client, mark ICP Verified in bulk, and manage a
-- per-client blocklist. All three take a filter payload rather than a list of
-- ids, so "select all 40,000 matching, then act" is one request instead of
-- 40,000 ids crossing the wire.
--
-- Every one of them is also recorded in an operation log, because these are the
-- four ways to change tens of thousands of rows with one click.

-- ---------------------------------------------------------------------------
-- 1. Operation log
-- ---------------------------------------------------------------------------

create table if not exists public.operation_log (
  id text primary key default gen_random_uuid()::text,
  action text not null,
  client_id text references public.clients(id) on delete set null,
  actor text not null default '',
  summary text not null default '',
  affected integer not null default 0,
  prospect_ids text[] not null default '{}'::text[],
  undone_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_operation_log_created on public.operation_log (created_at desc);
create index if not exists idx_operation_log_client on public.operation_log (client_id, created_at desc);

alter table public.operation_log enable row level security;
revoke all on public.operation_log from anon, authenticated;

-- Ids are kept so an operation can be undone, but only up to a bound: a
-- database-wide push should not store a million ids in one row.
create or replace function public.record_operation(
  p_action text, p_client_id text, p_actor text, p_summary text,
  p_affected integer, p_ids text[]
)
returns text
language sql
security definer
set search_path = public
as $$
  insert into public.operation_log (action, client_id, actor, summary, affected, prospect_ids)
  values (
    left(coalesce(p_action, ''), 60), p_client_id, left(coalesce(p_actor, ''), 200),
    left(coalesce(p_summary, ''), 500), coalesce(p_affected, 0),
    coalesce(p_ids[1:50000], '{}'::text[])
  )
  returning id;
$$;

-- ---------------------------------------------------------------------------
-- 2. Resolve a filter payload to prospect ids, server-side
-- ---------------------------------------------------------------------------
-- The same search/filter contract the People DB uses, so what you selected on
-- screen is exactly what the operation acts on.

create or replace function public.prospect_ids_matching_v1(
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_client_id text default null,
  p_excluded_ids text[] default null,
  p_limit integer default 200000
)
returns table(prospect_id text)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_prefilter text := public.prospect_prefilter_sql(coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb));
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_sql text := 'select pi.id from public.prospect_index pi where true';
begin
  if p_client_id is not null then
    v_sql := v_sql || format(' and pi.client_ids @> array[%L]', p_client_id);
  end if;
  if v_has_people then
    if v_prefilter <> 'true' then v_sql := v_sql || ' and (' || v_prefilter || ')'; end if;
    v_sql := v_sql || format(' and public.prospect_index_matches_v1(pi, %L, %L::jsonb)',
      coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text);
  end if;
  if p_excluded_ids is not null and cardinality(p_excluded_ids) > 0 then
    v_sql := v_sql || format(' and not (pi.id = any (%L::text[]))', p_excluded_ids);
  end if;
  v_sql := v_sql || format(' limit %s', greatest(1, least(coalesce(p_limit, 200000), 1000000)));
  return query execute v_sql;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Push master records into a client
-- ---------------------------------------------------------------------------

create or replace function public.push_prospects_to_client_v1(
  p_client_id text,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_source_client_id text default null,
  p_prospect_ids text[] default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_blocked integer := 0;
  v_added integer := 0;
  v_present integer := 0;
  v_reindex record;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_source_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('added', 0, 'alreadyPresent', 0, 'blocked', 0, 'queued', 0);
  end if;

  -- Never push a record this client has already blocked: the whole point of the
  -- blocklist is that it survives a later bulk action.
  select count(*)::integer into v_blocked
  from public.prospect_index pi
  join public.client_blocklist b on b.client_id = p_client_id
  where pi.id = any(v_ids)
    and (
      (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
      or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
    );

  select count(*)::integer into v_present
  from public.client_prospects cp
  where cp.client_id = p_client_id and cp.prospect_id = any(v_ids);

  with eligible as (
    select pi.id
    from public.prospect_index pi
    where pi.id = any(v_ids)
      and not exists (
        select 1 from public.client_blocklist b
        where b.client_id = p_client_id
          and (
            (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
            or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
          )
      )
  ), inserted as (
    insert into public.client_prospects (client_id, prospect_id, added_via)
    select p_client_id, eligible.id, 'push' from eligible
    on conflict (client_id, prospect_id) do nothing
    returning 1
  )
  select count(*)::integer into v_added from inserted;

  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    'push_to_client', p_client_id, p_actor,
    format('Pushed %s prospects into the client', v_added), v_added, v_ids);

  return jsonb_build_object(
    'added', v_added,
    'alreadyPresent', v_present,
    'blocked', v_blocked,
    'queued', v_reindex.queued);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Bulk ICP Verified
-- ---------------------------------------------------------------------------

create or replace function public.set_icp_verified_v1(
  p_client_id text,
  p_verified boolean,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_prospect_ids text[] default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_updated integer := 0;
  v_reindex record;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  update public.client_prospects cp set
    icp_verified = p_verified,
    verified_at = case when p_verified then now() else null end,
    verified_by = case when p_verified then left(coalesce(p_actor, ''), 200) else '' end
  where cp.client_id = p_client_id
    and cp.prospect_id = any(v_ids)
    and cp.icp_verified is distinct from p_verified;
  get diagnostics v_updated = row_count;

  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    case when p_verified then 'icp_verify' else 'icp_unverify' end,
    p_client_id, p_actor,
    format('Marked %s prospects %s', v_updated, case when p_verified then 'ICP verified' else 'not verified' end),
    v_updated, v_ids);

  return jsonb_build_object('updated', v_updated, 'queued', v_reindex.queued);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Blocklist maintenance
-- ---------------------------------------------------------------------------

create or replace function public.add_client_blocklist_v1(
  p_client_id text,
  p_domains text[] default null,
  p_emails text[] default null,
  p_reason text default '',
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_added integer := 0;
  v_blocked integer := 0;
  v_ids text[];
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  with incoming as (
    select 'domain'::text as kind, lower(btrim(value)) as value
    from unnest(coalesce(p_domains, array[]::text[])) as value
    where btrim(value) <> ''
    union
    select 'email', lower(btrim(value))
    from unnest(coalesce(p_emails, array[]::text[])) as value
    where btrim(value) <> ''
  ), inserted as (
    insert into public.client_blocklist (client_id, kind, value, reason, source)
    select p_client_id, incoming.kind, incoming.value, left(coalesce(p_reason, ''), 300), 'paste'
    from incoming
    on conflict (client_id, kind, value) do nothing
    returning 1
  )
  select count(*)::integer into v_added from inserted;

  -- Suppress anything already in the client that the new entries match.
  select coalesce(array_agg(cp.prospect_id), array[]::text[]) into v_ids
  from public.client_prospects cp
  join public.prospect_index pi on pi.id = cp.prospect_id
  join public.client_blocklist b on b.client_id = p_client_id
  where cp.client_id = p_client_id
    and (
      (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
      or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
    );

  v_blocked := public.apply_client_blocklist_v1(p_client_id);
  perform public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    'blocklist_add', p_client_id, p_actor,
    format('Blocked %s new entries, suppressing %s records', v_added, v_blocked), v_blocked, v_ids);

  return jsonb_build_object('added', v_added, 'suppressed', v_blocked);
end;
$$;

create or replace function public.remove_client_blocklist_v1(
  p_client_id text, p_ids text[], p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_removed integer := 0;
  v_ids text[];
begin
  delete from public.client_blocklist
  where client_id = p_client_id and id = any(coalesce(p_ids, array[]::text[]));
  get diagnostics v_removed = row_count;

  -- Un-suppress anything no remaining entry still matches.
  with still_blocked as (
    select distinct cp.prospect_id
    from public.client_prospects cp
    join public.prospect_index pi on pi.id = cp.prospect_id
    join public.client_blocklist b on b.client_id = p_client_id
    where cp.client_id = p_client_id
      and (
        (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
        or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
      )
  ), restored as (
    update public.client_prospects cp set
      status = 'active', blocked_at = null, blocked_reason = ''
    where cp.client_id = p_client_id
      and cp.status = 'blocked'
      and cp.prospect_id not in (select prospect_id from still_blocked)
    returning cp.prospect_id
  )
  select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids from restored;

  perform public.reindex_scope_v1(p_prospect_ids => v_ids);
  perform public.record_operation('blocklist_remove', p_client_id, p_actor,
    format('Removed %s blocklist entries, restoring %s records', v_removed, cardinality(v_ids)),
    cardinality(v_ids), v_ids);

  return jsonb_build_object('removed', v_removed, 'restored', cardinality(v_ids));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Remove from client (bulk), replacing the one-at-a-time function
-- ---------------------------------------------------------------------------

create or replace function public.remove_prospects_from_client_v2(
  p_client_id text,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_prospect_ids text[] default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_removed integer := 0;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('removed', 0, 'masterProspectPreserved', true);
  end if;

  -- Drop the list links first so the membership trigger cannot re-add the row,
  -- then the membership itself (which covers pushed records with no list).
  delete from public.list_memberships lm
  using public.lists l
  where lm.list_id = l.id and l.client_id = p_client_id and lm.prospect_id = any(v_ids);

  delete from public.client_prospects
  where client_id = p_client_id and prospect_id = any(v_ids);
  get diagnostics v_removed = row_count;

  perform public.reindex_scope_v1(p_prospect_ids => v_ids);
  perform public.record_operation('remove_from_client', p_client_id, p_actor,
    format('Removed %s prospects from the client', v_removed), v_removed, v_ids);

  return jsonb_build_object('removed', v_removed, 'masterProspectPreserved', true);
end;
$$;

revoke execute on function public.record_operation(text, text, text, text, integer, text[]) from public, anon, authenticated;
revoke execute on function public.prospect_ids_matching_v1(text, jsonb, text, text[], integer) from public, anon, authenticated;
revoke execute on function public.push_prospects_to_client_v1(text, text, jsonb, text, text[], text[], text) from public, anon, authenticated;
revoke execute on function public.set_icp_verified_v1(text, boolean, text, jsonb, text[], text[], text) from public, anon, authenticated;
revoke execute on function public.add_client_blocklist_v1(text, text[], text[], text, text) from public, anon, authenticated;
revoke execute on function public.remove_client_blocklist_v1(text, text[], text) from public, anon, authenticated;
revoke execute on function public.remove_prospects_from_client_v2(text, text, jsonb, text[], text[], text) from public, anon, authenticated;

grant execute on function public.record_operation(text, text, text, text, integer, text[]) to service_role;
grant execute on function public.prospect_ids_matching_v1(text, jsonb, text, text[], integer) to service_role;
grant execute on function public.push_prospects_to_client_v1(text, text, jsonb, text, text[], text[], text) to service_role;
grant execute on function public.set_icp_verified_v1(text, boolean, text, jsonb, text[], text[], text) to service_role;
grant execute on function public.add_client_blocklist_v1(text, text[], text[], text, text) to service_role;
grant execute on function public.remove_client_blocklist_v1(text, text[], text) to service_role;
grant execute on function public.remove_prospects_from_client_v2(text, text, jsonb, text[], text[], text) to service_role;

-- ---------------------------------------------------------------------------
-- 7. Smoke test
-- ---------------------------------------------------------------------------
-- These functions mutate real data, so the test builds its own client and
-- prospect, exercises every path against them, and removes them again.
do $smoke$
declare
  v_client text := '__smoke_ops_client__';
  v_prospect text := '__smoke_ops_prospect__';
  v_result jsonb;
begin
  insert into public.clients (id, name, normalized_name)
    values (v_client, 'Smoke Ops', '__smoke_ops_client__') on conflict (id) do nothing;
  insert into public.companies (id, name, normalized_name, domain, normalized_domain)
    values ('domain:smoke-ops.invalid', 'Smoke Ops Co', 'smoke ops co', 'smoke-ops.invalid', 'smoke-ops.invalid')
    on conflict (id) do nothing;
  insert into public.prospects (id, full_name, work_email, company_id)
    values (v_prospect, 'Smoke Ops Person', '__smoke_ops__@example.invalid', 'domain:smoke-ops.invalid')
    on conflict (id) do nothing;
  perform public.reindex_prospects(array[v_prospect]);

  -- Push by explicit id.
  v_result := public.push_prospects_to_client_v1(v_client, '', '[]'::jsonb, null, array[v_prospect], null, 'smoke');
  if (v_result->>'added')::integer <> 1 then
    raise exception 'push did not add the prospect: %', v_result;
  end if;

  -- ICP verify, then unverify.
  v_result := public.set_icp_verified_v1(v_client, true, '', '[]'::jsonb, array[v_prospect], null, 'smoke');
  if (v_result->>'updated')::integer <> 1 then raise exception 'ICP verify failed: %', v_result; end if;
  if not exists (select 1 from public.prospect_index where id = v_prospect and icp_verified_client_ids @> array[v_client]) then
    raise exception 'ICP verification did not reach the search index';
  end if;
  perform public.set_icp_verified_v1(v_client, false, '', '[]'::jsonb, array[v_prospect], null, 'smoke');

  -- Blocklist the company domain: the record must be suppressed, not deleted.
  v_result := public.add_client_blocklist_v1(v_client, array['smoke-ops.invalid'], null, 'smoke test', 'smoke');
  if (v_result->>'suppressed')::integer <> 1 then
    raise exception 'blocklist did not suppress the matching record: %', v_result;
  end if;
  if not exists (select 1 from public.client_prospects where client_id = v_client and prospect_id = v_prospect and status = 'blocked') then
    raise exception 'blocklist did not set the membership status';
  end if;
  if not exists (select 1 from public.prospects where id = v_prospect) then
    raise exception 'blocklist deleted the master record — it must only suppress';
  end if;

  -- A blocked record must not be re-added by a later push.
  v_result := public.push_prospects_to_client_v1(v_client, '', '[]'::jsonb, null, array[v_prospect], null, 'smoke');
  if (v_result->>'blocked')::integer <> 1 then
    raise exception 'push ignored the blocklist: %', v_result;
  end if;

  -- Removing the entry restores the record.
  v_result := public.remove_client_blocklist_v1(v_client,
    array(select id from public.client_blocklist where client_id = v_client), 'smoke');
  if (v_result->>'restored')::integer <> 1 then
    raise exception 'removing the blocklist entry did not restore the record: %', v_result;
  end if;

  -- Bulk removal leaves the master record intact.
  v_result := public.remove_prospects_from_client_v2(v_client, '', '[]'::jsonb, array[v_prospect], null, 'smoke');
  if (v_result->>'removed')::integer <> 1 then raise exception 'bulk removal failed: %', v_result; end if;
  if not exists (select 1 from public.prospects where id = v_prospect) then
    raise exception 'removing from a client deleted the master record';
  end if;

  -- Filter-payload resolution must work without ids too.
  perform public.prospect_ids_matching_v1('', '[{"field":"__work_email","operator":"contains","values":["@example.invalid"]}]'::jsonb, null, null, 10);

  delete from public.operation_log where client_id = v_client;
  delete from public.prospects where id = v_prospect;
  delete from public.companies where id = 'domain:smoke-ops.invalid';
  delete from public.clients where id = v_client;
end;
$smoke$;
