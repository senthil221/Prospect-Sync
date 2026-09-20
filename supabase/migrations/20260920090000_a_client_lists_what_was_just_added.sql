-- "What just arrived in this client?", for people and for companies.
--
-- WHAT NEEDS IT. After an import there is no way to see what it actually put
-- into the client. The People DB and Company DB both sort by their own measures
-- - created_at, then prospect count - so a fresh batch is scattered through
-- pages of everything that was already there, and the only way to review an
-- import is to remember what was in the file.
--
-- IT READS added_at, NOT date_added, AND NOT created_at.
--
--   client_prospects.added_at   timestamptz, set by the insert   <- this
--   client_prospects.date_added date, entered by hand            no
--   prospects.created_at        when the record first existed    no
--
-- The three disagree, and only the first answers the question. date_added is a
-- user-editable date whose newest value on production is 2026-08-28, three
-- weeks behind added_at - it is somebody's own bookkeeping, not a system clock,
-- and the existing idx_client_prospects_date_added indexes that one rather than
-- this. created_at is the wrong question entirely: a company that has existed
-- for a year and was pushed to this client an hour ago is new TO THIS CLIENT,
-- which is what is being asked, and created_at would hide it.
--
-- ADDITIVE ON PURPOSE. This adds a function and two indexes and alters nothing
-- that already runs. The listing functions it sits beside are heavily tuned and
-- carry their own caps and timeouts; a window this narrow does not need any of
-- that, and patching them to carry a date range would put the whole Company DB
-- at risk for a tab that reads one day of rows.
--
-- REMOVAL IS NOT HERE. Taking a record back out is remove_prospects_from_client_v2
-- and remove_companies_from_client_v1, which already exist, already re-index,
-- and already write the audit row. This is a read.
-- ---------------------------------------------------------------------------

-- added_at had no index on either table; the only near miss indexes date_added,
-- the column this deliberately does not read. Client first so one client's
-- window is a range scan rather than a filter over everybody's.
create index if not exists idx_client_prospects_added_at
  on public.client_prospects (client_id, added_at desc);

create index if not exists idx_client_companies_added_at
  on public.client_companies (client_id, added_at desc);

create or replace function public.client_recently_added_v1(
  p_client_id text,
  p_entity text default 'people',
  p_hours integer default 24,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
declare
  -- Bounded rather than trusted: the window arrives from a query string. Ninety
  -- days is well past the point where "recently added" means anything, and it
  -- keeps the scan inside the index range above.
  v_hours integer := greatest(1, least(coalesce(p_hours, 24), 24 * 90));
  v_since timestamptz := now() - make_interval(hours => v_hours);
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  if p_entity = 'companies' then
    return query
      with matched as (
        select c.id, c.name, c.domain, cc.prospect_count, cc.added_at
        from public.client_companies cc
        join public.companies c on c.id = cc.company_id
        where cc.client_id = p_client_id
          and cc.added_at >= v_since
      ), page_rows as (
        select * from matched
        order by added_at desc, lower(name), id
        limit v_limit offset v_offset
      )
      select coalesce((
          select jsonb_agg(to_jsonb(page_rows) order by page_rows.added_at desc, lower(page_rows.name), page_rows.id)
          from page_rows
        ), '[]'::jsonb),
        (select count(*) from matched);
  else
    return query
      with matched as (
        select pi.id, pi.full_name, pi.title, pi.work_email, pi.company_name,
               cp.added_at, cp.added_via
        from public.client_prospects cp
        join public.prospect_index pi on pi.id = cp.prospect_id
        where cp.client_id = p_client_id
          and cp.added_at >= v_since
      ), page_rows as (
        select * from matched
        order by added_at desc, id
        limit v_limit offset v_offset
      )
      select coalesce((
          select jsonb_agg(to_jsonb(page_rows) order by page_rows.added_at desc, page_rows.id)
          from page_rows
        ), '[]'::jsonb),
        (select count(*) from matched);
  end if;
end;
$function$;

revoke execute on function public.client_recently_added_v1(text, text, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.client_recently_added_v1(text, text, integer, integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- It returns the rows the membership tables say it should, for both entities,
-- and the window is a real filter rather than something that quietly matches
-- everything.
do $$
declare
  v_client text;
  v_people_expected bigint;
  v_people_got bigint;
  v_companies_expected bigint;
  v_companies_got bigint;
  v_wide bigint;
  v_narrow bigint;
  v_rows jsonb;
  v_hours integer;
begin
  -- A client that has had anything added at all. The window is widened to reach
  -- it, because a database mid-week may have nothing at all from the last day -
  -- which is exactly the case this function has to return empty for, not fail.
  select cp.client_id, ceil(extract(epoch from (now() - min(cp.added_at))) / 3600)::integer + 1
    into v_client, v_hours
  from public.client_prospects cp
  group by cp.client_id
  having count(*) > 0
  order by max(cp.added_at) desc
  limit 1;

  if v_client is null then
    raise notice 'no client has any people; the recently-added listing is unproven';
    return;
  end if;
  v_hours := least(v_hours, 24 * 90);

  select count(*) into v_people_expected
  from public.client_prospects cp
  join public.prospect_index pi on pi.id = cp.prospect_id
  where cp.client_id = v_client and cp.added_at >= now() - make_interval(hours => v_hours);

  select total_count into v_people_got
  from public.client_recently_added_v1(v_client, 'people', v_hours, 1, 0);

  if v_people_got is distinct from v_people_expected then
    raise exception 'people: listing counted %, the membership table says %', v_people_got, v_people_expected;
  end if;

  select count(*) into v_companies_expected
  from public.client_companies cc
  where cc.client_id = v_client and cc.added_at >= now() - make_interval(hours => v_hours);

  select total_count into v_companies_got
  from public.client_recently_added_v1(v_client, 'companies', v_hours, 1, 0);

  if v_companies_got is distinct from v_companies_expected then
    raise exception 'companies: listing counted %, the membership table says %', v_companies_got, v_companies_expected;
  end if;

  -- A narrower window may never return more than a wider one. This is what
  -- catches a predicate that is not actually filtering.
  select total_count into v_wide from public.client_recently_added_v1(v_client, 'people', v_hours, 1, 0);
  select total_count into v_narrow from public.client_recently_added_v1(v_client, 'people', 1, 1, 0);
  if v_narrow > v_wide then
    raise exception 'a 1-hour window returned % people, more than the %-hour window (%)', v_narrow, v_hours, v_wide;
  end if;

  -- The page carries what the tab renders, and every row is inside the window.
  select result_rows into v_rows from public.client_recently_added_v1(v_client, 'people', v_hours, 50, 0);
  if jsonb_array_length(v_rows) > 0 then
    if not (v_rows -> 0) ? 'added_at' then
      raise exception 'the people page has no added_at to sort or display';
    end if;
    if exists (
      select 1 from jsonb_array_elements(v_rows) row_value
      where (row_value->>'added_at')::timestamptz < now() - make_interval(hours => v_hours)
    ) then
      raise exception 'the people page returned a row older than its own window';
    end if;
  end if;

  -- An entity it does not know is people, not everything.
  if (select total_count from public.client_recently_added_v1(v_client, 'nonsense', v_hours, 1, 0))
     is distinct from v_people_expected then
    raise exception 'an unknown entity did not fall back to people';
  end if;

  raise notice 'recently added, client % over %h: % people, % companies', v_client, v_hours, v_people_expected, v_companies_expected;
end $$;
