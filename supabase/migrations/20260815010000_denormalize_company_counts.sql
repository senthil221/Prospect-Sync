-- Kill the Company DB statement timeout by denormalizing company-level counts.
--
-- WHY
-- company_summaries computed prospect_count / client_count live by joining
-- prospects -> list_memberships -> lists and aggregating across EVERY company.
-- With 17k+ companies (of which only a few hundred have any prospects) the
-- unfiltered Company DB page cost ~3.4s cold, and the listing route fires that
-- shape three times per request (page + exact count + covered), so it blew past
-- PostgREST's 8s authenticator cap -> "canceling statement due to statement
-- timeout". The plain view/count queries can't carry a per-function
-- statement_timeout, so the fix is to make them cheap, not longer-running.
--
-- FIX
-- Store prospect_count / client_count on companies, keep them exact with a
-- trigger on prospect_index (the denormalized mirror every read/write path
-- already refreshes), add a covering (prospect_count desc, name) ranking index
-- so the default page is an index-only top-N, and redefine company_summaries to
-- read the stored columns. Same output columns => no app change; every consumer
-- (listing, exact/covered counts, coverage route) gets the fast path.

alter table public.companies
  add column if not exists prospect_count integer not null default 0,
  add column if not exists client_count integer not null default 0;

-- Recompute one company's counts from prospect_index (the source of truth the
-- app already keeps fresh). count(*) = prospects linked to the company;
-- distinct over client_ids = distinct clients touching it.
create or replace function public.recompute_company_counts(p_company_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.companies c set
    prospect_count = coalesce((
      select count(*) from public.prospect_index pi where pi.company_id = p_company_id
    ), 0),
    client_count = coalesce((
      select count(distinct cid)
      from public.prospect_index pi
      cross join lateral unnest(pi.client_ids) as cid
      where pi.company_id = p_company_id
    ), 0)
  where c.id = p_company_id;
$$;

create or replace function public.sync_company_counts_from_index()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') and new.company_id is not null then
    perform public.recompute_company_counts(new.company_id);
  end if;
  if tg_op in ('DELETE', 'UPDATE') and old.company_id is not null
     and (tg_op = 'DELETE' or old.company_id is distinct from new.company_id) then
    perform public.recompute_company_counts(old.company_id);
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_company_counts on public.prospect_index;
create trigger trg_sync_company_counts
after insert or update or delete on public.prospect_index
for each row execute function public.sync_company_counts_from_index();

-- Backfill the stored counts for companies that currently have prospects; the
-- rest keep the 0 default.
update public.companies c set
  prospect_count = coalesce(pc.prospect_count, 0),
  client_count = coalesce(pc.client_count, 0)
from (
  select pi.company_id,
    count(*)::integer as prospect_count,
    count(distinct cid)::integer as client_count
  from public.prospect_index pi
  left join lateral unnest(pi.client_ids) as cid on true
  where pi.company_id is not null
  group by pi.company_id
) pc
where c.id = pc.company_id;

-- Covering ranking index: ORDER BY prospect_count desc, name with LIMIT becomes
-- an index-only top-N, and prospect_count > 0 (covered) is the head of the index.
create index if not exists idx_companies_prospect_ranking
  on public.companies (prospect_count desc, name)
  include (id, domain, created_at, client_count);

-- Same columns as before, now read straight from companies -- so the listing,
-- its exact/covered counts, and the coverage route all avoid the live aggregate.
create or replace view public.company_summaries as
  select c.id, c.name, c.domain, c.created_at, c.prospect_count, c.client_count
  from public.companies c;
