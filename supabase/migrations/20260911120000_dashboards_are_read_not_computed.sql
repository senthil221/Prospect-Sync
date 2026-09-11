-- Three functions behind tabs are O(table) on every request, and that is the
-- shape that does not survive growth. Measured now, and extrapolated to 10M
-- prospects (15x, linear - optimistic for anything with a sort):
--
--   function                    now      at 10M   its ceiling
--   prospect_index_drift       13.3s      ~200s       90s   breaks
--   data_quality_overview      12.2s      ~183s       90s   breaks
--   prospect_title_taxonomy_v1  2.3s       ~34s       30s   breaks
--
-- None of them needs to be computed at the instant somebody looks. They are
-- summaries of the whole database; the answer changes when the data changes,
-- not when the page opens. So they are computed once per data version by the
-- operations worker and read back as a single row.
--
-- EXACT, NOT EVENTUALLY CONSISTENT. The snapshot carries the data versions it
-- was computed from - the same sequences 20260910170000 keys the filter cache
-- on - so a caller can tell whether it is current rather than guessing. When
-- nothing has been written the snapshot is not stale at all; it is the same
-- answer the function would return, already computed.
--
-- WHAT CHANGES FOR A USER. After an import the numbers can lag by one refresh
-- cycle. For a data-quality summary that is the right trade and the API returns
-- computedAt so it can be shown honestly. Nothing else about the tabs changes,
-- and this migration populates the snapshot before it commits, so the tabs have
-- data from the moment it lands rather than after the first worker pass.
--
-- The refresh lives in prospect_operations and is granted to prospect_operator,
-- following the worker's existing boundary: the worker role is deliberately not
-- service_role and gets only the functions it needs.

begin;

create table if not exists public.dashboard_snapshot (
  key text primary key,
  payload jsonb not null,
  -- The whole version object, not one number: the quality summary depends on
  -- prospects and companies both, and a company-only edit must invalidate it.
  data_version jsonb not null,
  computed_at timestamptz not null default now(),
  duration_ms integer
);

alter table public.dashboard_snapshot enable row level security;
revoke all on public.dashboard_snapshot from public, anon, authenticated;
grant select, insert, update, delete on public.dashboard_snapshot to service_role;

comment on table public.dashboard_snapshot is
  'Whole-database summaries computed once per data version by the operations worker, so the tabs that show them are a row read rather than a full scan.';

create or replace function prospect_operations.refresh_dashboard_snapshots_v1()
returns integer
language plpgsql
volatile
security definer
set search_path to 'public'
-- Longer than any caller would tolerate, because nobody is waiting on it. The
-- individual functions keep their own ceilings.
set statement_timeout to '300s'
as $function$
declare
  v_versions jsonb := public.data_versions_v1(array['prospect', 'company']);
  v_refreshed integer := 0;
  v_started timestamptz;
  v_payload jsonb;
  v_key text;
begin
  foreach v_key in array array['dataQuality', 'indexDrift', 'titleTaxonomy'] loop
    -- Same version means the stored answer is the answer. Skipping is the
    -- point: a quiet database costs three cheap comparisons per cycle.
    if exists (
      select 1 from public.dashboard_snapshot s
      where s.key = v_key and s.data_version = v_versions
    ) then
      continue;
    end if;

    v_started := clock_timestamp();
    v_payload := case v_key
      when 'dataQuality' then public.data_quality_overview()
      when 'indexDrift' then public.prospect_index_drift()
      when 'titleTaxonomy' then public.prospect_title_taxonomy_v1(null)
    end;

    insert into public.dashboard_snapshot (key, payload, data_version, computed_at, duration_ms)
    values (v_key, coalesce(v_payload, '{}'::jsonb), v_versions, now(),
            (extract(epoch from clock_timestamp() - v_started) * 1000)::integer)
    on conflict (key) do update
      set payload = excluded.payload,
          data_version = excluded.data_version,
          computed_at = excluded.computed_at,
          duration_ms = excluded.duration_ms;
    v_refreshed := v_refreshed + 1;
  end loop;

  return v_refreshed;
end;
$function$;

revoke execute on function prospect_operations.refresh_dashboard_snapshots_v1() from public, anon, authenticated;
grant execute on function prospect_operations.refresh_dashboard_snapshots_v1() to prospect_operator, service_role;

-- What the application reads. One row, by primary key.
create or replace function public.dashboard_snapshot_v1(p_key text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
set statement_timeout to '5s'
as $function$
  select jsonb_build_object(
    'payload', s.payload,
    'computedAt', s.computed_at,
    -- Honest rather than reassuring: says whether anything has been written
    -- since this was computed, so the caller can show it as of a time.
    'current', s.data_version = public.data_versions_v1(array['prospect', 'company'])
  )
  from public.dashboard_snapshot s
  where s.key = p_key;
$function$;

revoke execute on function public.dashboard_snapshot_v1(text) from public, anon, authenticated;
grant execute on function public.dashboard_snapshot_v1(text) to service_role;

-- Populate before committing, so the tabs never show an empty state waiting for
-- the first worker pass.
select prospect_operations.refresh_dashboard_snapshots_v1();

do $$
declare
  v_key text;
  v_row record;
begin
  foreach v_key in array array['dataQuality', 'indexDrift', 'titleTaxonomy'] loop
    select * into v_row from public.dashboard_snapshot where key = v_key;
    if v_row is null then
      raise exception 'no snapshot was written for %', v_key;
    end if;
    if v_row.payload is null or v_row.payload = '{}'::jsonb then
      raise exception 'the snapshot for % is empty, which would blank the tab', v_key;
    end if;
    if (public.dashboard_snapshot_v1(v_key) ->> 'current')::boolean is not true then
      raise exception 'the snapshot for % reports itself out of date the moment it was written', v_key;
    end if;
  end loop;

  -- A second pass must do nothing: the version has not moved.
  if prospect_operations.refresh_dashboard_snapshots_v1() <> 0 then
    raise exception 'the refresh recomputed an unchanged snapshot, so it would run every cycle forever';
  end if;
end;
$$;

commit;
