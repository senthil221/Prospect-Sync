begin;

-- Browser retries use the same request id. Storing the completed result makes a
-- lost HTTP response exactly-once from the user's perspective: retrying returns
-- the original counts instead of advancing another prospect slice invisibly.
create table if not exists public.client_blocklist_batch_results (
  request_id text primary key,
  client_id text not null references public.clients(id) on delete cascade,
  result jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_client_blocklist_batch_results_client_created
  on public.client_blocklist_batch_results (client_id, created_at desc);
alter table public.client_blocklist_batch_results enable row level security;
revoke all on public.client_blocklist_batch_results from anon, authenticated;
grant select, insert, delete on public.client_blocklist_batch_results to service_role;

-- Large blocklists are applied in bounded, repeatable slices. The entry rows are
-- inserted idempotently first; each call then blocks at most p_match_limit
-- active client prospects and reports whether the caller should continue. This
-- prevents one large company or paste from holding an HTTP request indefinitely.
create or replace function public.add_client_blocklist_batch_v2(
  p_client_id text,
  p_domains text[] default null,
  p_emails text[] default null,
  p_reason text default '',
  p_actor text default '',
  p_request_id text default '',
  p_match_limit integer default 5000
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '90s'
as $$
declare
  v_domains text[] := array[]::text[];
  v_emails text[] := array[]::text[];
  v_ids text[] := array[]::text[];
  v_added integer := 0;
  v_blocked integer := 0;
  v_reindexed integer := 0;
  v_queued integer := 0;
  v_limit integer := greatest(100, least(coalesce(p_match_limit, 5000), 5000));
  v_remaining boolean := false;
  v_client_name text := '';
  v_cached_client_id text := '';
  v_result jsonb;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  if cardinality(coalesce(p_domains, array[]::text[]))
      + cardinality(coalesce(p_emails, array[]::text[])) > 200 then
    raise exception using errcode = '22023', message = 'A blocklist batch can contain at most 200 entries.';
  end if;
  if length(btrim(coalesce(p_request_id, ''))) < 8 or length(p_request_id) > 100 then
    raise exception using errcode = '22023', message = 'A valid blocklist request id is required.';
  end if;

  select cached.client_id, cached.result into v_cached_client_id, v_result
  from public.client_blocklist_batch_results cached
  where cached.request_id = p_request_id;
  if found then
    if v_cached_client_id <> p_client_id then
      raise exception using errcode = '22023', message = 'That blocklist request id belongs to another client.';
    end if;
    return v_result;
  end if;

  select coalesce(array_agg(value order by value), array[]::text[]) into v_domains
  from (
    select distinct lower(btrim(value)) as value
    from unnest(coalesce(p_domains, array[]::text[])) submitted(value)
    where btrim(value) <> ''
  ) normalized;
  select coalesce(array_agg(value order by value), array[]::text[]) into v_emails
  from (
    select distinct lower(btrim(value)) as value
    from unnest(coalesce(p_emails, array[]::text[])) submitted(value)
    where btrim(value) <> ''
  ) normalized;

  with incoming as (
    select 'domain'::text as kind, value from unnest(v_domains) submitted(value)
    union all
    select 'email'::text, value from unnest(v_emails) submitted(value)
  ), inserted as (
    insert into public.client_blocklist (client_id, kind, value, reason, source)
    select p_client_id, kind, value, left(coalesce(p_reason, ''), 300), 'paste'
    from incoming
    on conflict (client_id, kind, value) do nothing
    returning 1
  )
  select count(*)::integer into v_added from inserted;

  with candidates as materialized (
    select cp.prospect_id
    from public.client_prospects cp
    join public.prospect_index pi on pi.id = cp.prospect_id
    where cp.client_id = p_client_id
      and cp.status = 'active'
      and (
        (cardinality(v_domains) > 0 and lower(coalesce(pi.company_domain, '')) = any(v_domains))
        or (cardinality(v_emails) > 0 and (
          lower(coalesce(pi.work_email, '')) = any(v_emails)
          or lower(coalesce(pi.personal_email, '')) = any(v_emails)
        ))
      )
    order by cp.prospect_id
    limit v_limit
  ), blocked as (
    update public.client_prospects cp set
      status = 'blocked',
      blocked_at = coalesce(cp.blocked_at, now()),
      blocked_reason = coalesce(nullif(cp.blocked_reason, ''), nullif(left(coalesce(p_reason, ''), 300), ''), 'Matched client blocklist')
    from candidates
    where cp.client_id = p_client_id and cp.prospect_id = candidates.prospect_id
    returning cp.prospect_id
  )
  select coalesce(array_agg(prospect_id order by prospect_id), array[]::text[])
  into v_ids from blocked;
  v_blocked := cardinality(v_ids);

  -- Make the client visibility boundary correct immediately, even if a full
  -- search-index rebuild is queued because a batch is unusually expensive.
  if v_blocked > 0 then
    select name into v_client_name from public.clients where id = p_client_id;
    update public.prospect_index pi set
      client_ids = array_remove(coalesce(pi.client_ids, array[]::text[]), p_client_id),
      client_names = array_remove(coalesce(pi.client_names, array[]::text[]), v_client_name),
      client_count = cardinality(array_remove(coalesce(pi.client_ids, array[]::text[]), p_client_id)),
      icp_verified_client_ids = array_remove(coalesce(pi.icp_verified_client_ids, array[]::text[]), p_client_id),
      blocked_client_ids = case
        when coalesce(pi.blocked_client_ids, array[]::text[]) @> array[p_client_id]
          then coalesce(pi.blocked_client_ids, array[]::text[])
        else array_append(coalesce(pi.blocked_client_ids, array[]::text[]), p_client_id)
      end
    where pi.id = any(v_ids);

    select reindexed, queued into v_reindexed, v_queued
    from public.reindex_scope_v1(p_prospect_ids => v_ids, p_batch => 1000);
  end if;

  select exists (
    select 1
    from public.client_prospects cp
    join public.prospect_index pi on pi.id = cp.prospect_id
    where cp.client_id = p_client_id
      and cp.status = 'active'
      and (
        (cardinality(v_domains) > 0 and lower(coalesce(pi.company_domain, '')) = any(v_domains))
        or (cardinality(v_emails) > 0 and (
          lower(coalesce(pi.work_email, '')) = any(v_emails)
          or lower(coalesce(pi.personal_email, '')) = any(v_emails)
        ))
      )
  ) into v_remaining;

  perform public.record_operation(
    'blocklist_add_batch', p_client_id, p_actor,
    format('Added %s blocklist entries and removed %s client records%s',
      v_added, v_blocked, case when v_remaining then ' (more queued by caller)' else '' end),
    v_blocked, v_ids
  );

  v_result := jsonb_build_object(
    'added', v_added,
    'suppressed', v_blocked,
    'remaining', v_remaining,
    'reindexed', v_reindexed,
    'queued', v_queued
  );
  insert into public.client_blocklist_batch_results (request_id, client_id, result)
  values (p_request_id, p_client_id, v_result)
  on conflict (request_id) do nothing;
  return v_result;
end;
$$;

revoke execute on function public.add_client_blocklist_batch_v2(text, text[], text[], text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.add_client_blocklist_batch_v2(text, text[], text[], text, text, text, integer)
  to service_role;

analyze public.client_blocklist;
analyze public.client_prospects;
analyze public.prospect_index;

commit;
