-- Re-check MX lookups that failed, once a week.
--
-- A scan is written once (apply_email_provider_scan_v2) and claim_mx_scan_batch_v1
-- only ever returned companies never scanned, so a lookup that failed for a
-- passing reason (a DNS timeout, a registrar hiccup) stayed "Lookup failed"
-- forever: 2,776 companies on 2026-10-05, about 1.2% of the backfill. Their
-- ESP is unknown, so a client discarding SEG emails cannot hide them.
--
-- v2 fills each batch with never-scanned companies first and tops it up with
-- failed lookups last checked more than seven days ago, oldest first. A retry
-- writes a new mx_checked_at whatever it finds, so a domain that still fails
-- comes round again a week later - about 2,800 lookups a week, nothing next to
-- an import. `retry` tells the worker which rows are second attempts: its
-- DNS-outage guard judges first-time lookups only.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

-- Only the failed rows (2,776 of 449k), ordered by when they were last tried.
create index if not exists idx_companies_mx_lookup_failed
  on public.companies (mx_checked_at)
  where mx_status = 'lookup_failed' and normalized_domain <> '';

create or replace function public.claim_mx_scan_batch_v2(p_limit integer default 100)
returns table (id text, domain text, retry boolean)
language sql
stable
security definer
set search_path = public
set statement_timeout = '10s'
as $$
  with fresh as (
    select c.id, c.normalized_domain as domain, false as retry
      from public.companies c
     where c.normalized_domain <> '' and c.mx_checked_at is null
     order by c.id
     limit greatest(1, least(coalesce(p_limit, 100), 500))
  ), retried as (
    select c.id, c.normalized_domain as domain, true as retry
      from public.companies c
     where c.mx_status = 'lookup_failed' and c.normalized_domain <> ''
       and c.mx_checked_at < now() - interval '7 days'
     order by c.mx_checked_at
     limit greatest(0, least(coalesce(p_limit, 100), 500) - (select count(*) from fresh))
  )
  select * from fresh
  union all
  select * from retried
$$;

revoke execute on function public.claim_mx_scan_batch_v2(integer) from public, anon, authenticated;
grant execute on function public.claim_mx_scan_batch_v2(integer) to service_role;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'prospect_icp_validator') then
    execute 'grant execute on function public.claim_mx_scan_batch_v2(integer) to prospect_icp_validator';
  end if;
end $$;

-- Proof, rolled back: a never-scanned company comes before a stale failure,
-- a recent failure is left alone, and the batch never exceeds the limit.
do $proof$
declare
  v_ids text[];
  v_fresh text := 'mx-retry-proof-fresh-' || gen_random_uuid();
  v_stale text := 'mx-retry-proof-stale-' || gen_random_uuid();
  v_recent text := 'mx-retry-proof-recent-' || gen_random_uuid();
  v_rows jsonb;
begin
  begin
    insert into public.companies (id, name, normalized_name, domain, normalized_domain, mx_status, mx_checked_at) values
      (v_fresh, 'Fresh', 'fresh', v_fresh || '.test', v_fresh || '.test', 'pending', null),
      (v_stale, 'Stale', 'stale', v_stale || '.test', v_stale || '.test', 'lookup_failed', now() - interval '3650 days'),
      (v_recent, 'Recent', 'recent', v_recent || '.test', v_recent || '.test', 'lookup_failed', now() - interval '1 day');

    select jsonb_agg(to_jsonb(b)) into v_rows from public.claim_mx_scan_batch_v2(500) b;
    if not exists (select 1 from jsonb_array_elements(v_rows) r where r->>'id' = v_fresh and r->>'retry' = 'false')
       or not exists (select 1 from jsonb_array_elements(v_rows) r where r->>'id' = v_stale and r->>'retry' = 'true')
       or exists (select 1 from jsonb_array_elements(v_rows) r where r->>'id' = v_recent)
       or jsonb_array_length(v_rows) > 500 then
      raise exception 'MX retry proof: wrong batch %', v_rows;
    end if;
    -- Retries only fill what fresh companies leave.
    if (select count(*) filter (where retry) from public.claim_mx_scan_batch_v2(1)) <> 0
       or (select count(*) from public.claim_mx_scan_batch_v2(1)) <> 1 then
      raise exception 'MX retry proof: the limit was not respected';
    end if;
    raise exception 'mx-retry-proof-passed';
  exception when others then
    if sqlerrm <> 'mx-retry-proof-passed' then raise; end if;
  end;
  raise notice 'MX retry proof passed and was rolled back.';
end;
$proof$;
