\set ON_ERROR_STOP on

-- The historical migration's inline proof assumes fewer than 500 never-scanned
-- rows. This disposable fixture independently validates v2 with a saturated
-- fresh backlog; it cannot retroactively make that historical proof replay-safe.
do $$ begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'Refusing MX saturation fixture outside its disposable database.';
  end if;
end $$;

-- Isolate selection inside the outer rollback without deleting baseline rows.
update public.companies
set mx_checked_at = now(), mx_status = 'resolved'
where normalized_domain <> '' and mx_checked_at is null;

insert into public.companies(id, name, normalized_name, domain, normalized_domain, mx_status, mx_checked_at)
select 'mx-saturation-fresh-' || lpad(n::text, 3, '0'), 'MX Fresh ' || n, 'mx fresh ' || n,
       'mx-fresh-' || n || '.test', 'mx-fresh-' || n || '.test', 'pending', null
from generate_series(1, 500) n;
insert into public.companies(id, name, normalized_name, domain, normalized_domain, mx_status, mx_checked_at) values
  ('mx-saturation-stale', 'MX Stale', 'mx stale', 'mx-stale.test', 'mx-stale.test', 'lookup_failed', now() - interval '8 days'),
  ('mx-saturation-recent', 'MX Recent', 'mx recent', 'mx-recent.test', 'mx-recent.test', 'lookup_failed', now() - interval '1 day');

do $$
declare v_ids text[]; v_retries integer;
begin
  select coalesce(array_agg(id order by id), array[]::text[]), count(*) filter (where retry)
    into v_ids, v_retries from public.claim_mx_scan_batch_v2(500);
  if cardinality(v_ids) <> 500 or v_retries <> 0
     or 'mx-saturation-stale' = any(v_ids) or 'mx-saturation-recent' = any(v_ids) then
    raise exception 'fresh backlog must fill the batch before retries: %, retries %', cardinality(v_ids), v_retries;
  end if;

  update public.companies set mx_checked_at = now(), mx_status = 'resolved'
  where id like 'mx-saturation-fresh-%';
  select coalesce(array_agg(id order by id), array[]::text[]) into v_ids from public.claim_mx_scan_batch_v2(500);
  if not coalesce('mx-saturation-stale' = any(v_ids), false)
     or coalesce('mx-saturation-recent' = any(v_ids), false) then
    raise exception 'stale retry was not selected when fresh capacity became available: %', v_ids;
  end if;
end $$;
