-- Opening a filter dropdown costs 3-4 seconds. Typing in one costs 20-250ms.
--
-- Measured on production against prospect_filter_values_v3:
--
--   field         dropdown opens   after typing
--   __title            3,908ms         253ms
--   __name             3,643ms          21ms
--   __company          3,054ms         250ms
--   __lists            2,984ms           -
--
-- The difference is not a bad plan. With a search term the trigram indexes
-- narrow the scan; with no search term the question is genuinely "the 50 most
-- common values across 682,000 rows", which is a full aggregation and cannot be
-- indexed away. The work is honest. It is just being done at the wrong moment -
-- once per dropdown open, per user, forever, for an answer that only changes
-- when the data does.
--
-- So cache it, keyed on the data version. public.data_version_prospect is a
-- sequence already bumped by every write path (20260902000070), so a cached row
-- stamped with the current version is exact, not merely fresh - the moment
-- anything changes the key stops matching and the next caller recomputes. This
-- is the same versioning that count_companies_exactly uses to skip a count the
-- caller already holds; here it is stored server-side instead, so the first
-- person after an import pays for it and everyone else does not.
--
-- The row is keyed (field, client_id) with the version as a column rather than
-- part of the key, so an upsert replaces the previous generation instead of
-- accumulating one row per version. The table cannot grow beyond the number of
-- distinct fields a workspace filters on.
--
-- Search is deliberately NOT cached and still goes to v3: it is already fast,
-- and caching per search term would be a cache with one entry per keystroke.

begin;

create table if not exists public.prospect_filter_value_cache (
  field text not null,
  -- '' rather than null for the master workspace: null would make the primary
  -- key stop deduplicating, since null is distinct from null in a unique index.
  client_id text not null default '',
  data_version bigint not null,
  entries jsonb not null,
  computed_at timestamptz not null default now(),
  primary key (field, client_id)
);

alter table public.prospect_filter_value_cache enable row level security;
revoke all on public.prospect_filter_value_cache from public, anon, authenticated;
grant select, insert, update, delete on public.prospect_filter_value_cache to service_role;

comment on table public.prospect_filter_value_cache is
  'Top filter values per field, stamped with the prospect data version. Exact, not eventually consistent: a stale stamp is a miss.';

-- Always computed at the ceiling the route allows and sliced on read, so a
-- limit of 25 and a limit of 50 share one cached row rather than each keeping
-- their own copy of the same scan.
create or replace function public.prospect_filter_values_cached_v1(
  p_field text,
  p_client_id text default null,
  p_limit integer default 50
)
returns table(value text, match_count bigint)
language plpgsql
volatile
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_client text := coalesce(nullif(btrim(coalesce(p_client_id, '')), ''), '');
  v_version bigint := coalesce((public.data_versions_v1(array['prospect'])->>'prospect')::bigint, 0);
  v_entries jsonb;
begin
  select c.entries into v_entries
  from public.prospect_filter_value_cache c
  where c.field = p_field and c.client_id = v_client and c.data_version = v_version;

  if v_entries is null then
    select coalesce(jsonb_agg(jsonb_build_object('value', v.value, 'count', v.match_count)), '[]'::jsonb)
    into v_entries
    from public.prospect_filter_values_v3(p_field, '', nullif(v_client, ''), 100) v;

    -- Two callers racing produce the same answer, so the loser overwriting the
    -- winner costs nothing and is cheaper than a lock.
    insert into public.prospect_filter_value_cache (field, client_id, data_version, entries, computed_at)
    values (p_field, v_client, v_version, v_entries, now())
    on conflict (field, client_id) do update
      set data_version = excluded.data_version,
          entries = excluded.entries,
          computed_at = excluded.computed_at;
  end if;

  -- jsonb_agg preserved v3's "most common first" ordering; ordinality keeps it.
  return query
  select entry->>'value', (entry->>'count')::bigint
  from jsonb_array_elements(v_entries) with ordinality as t(entry, ord)
  order by t.ord
  limit v_limit;
end;
$function$;

comment on function public.prospect_filter_values_cached_v1(text, text, integer) is
  'Unfiltered filter-dropdown values, served from a version-stamped cache. Search still goes to prospect_filter_values_v3.';

revoke execute on function public.prospect_filter_values_cached_v1(text, text, integer) from public, anon, authenticated;
grant execute on function public.prospect_filter_values_cached_v1(text, text, integer) to service_role;

-- A cache that returns something other than what it caches is worse than none.
do $$
declare
  v_direct text;
  v_first text;
  v_second text;
  v_rows integer;
  v_version bigint;
begin
  select string_agg(v.value || ':' || v.match_count, '|' order by v.value) into v_direct
  from public.prospect_filter_values_v3('__company', '', null, 50) v;

  select string_agg(c.value || ':' || c.match_count, '|' order by c.value) into v_first
  from public.prospect_filter_values_cached_v1('__company', null, 50) c;

  -- Second call must come from the row the first one wrote.
  select string_agg(c.value || ':' || c.match_count, '|' order by c.value) into v_second
  from public.prospect_filter_values_cached_v1('__company', null, 50) c;

  if v_first is distinct from v_direct then
    raise exception 'cached values differ from prospect_filter_values_v3';
  end if;
  if v_second is distinct from v_first then
    raise exception 'the cached answer changed between two identical calls';
  end if;

  v_version := coalesce((public.data_versions_v1(array['prospect'])->>'prospect')::bigint, 0);
  select count(*) into v_rows from public.prospect_filter_value_cache
  where field = '__company' and client_id = '' and data_version = v_version;
  if v_rows <> 1 then
    raise exception 'expected exactly one cache row stamped with the current version, found %', v_rows;
  end if;

  -- A limit below the stored ceiling must slice, not recompute or over-return.
  select count(*) into v_rows from public.prospect_filter_values_cached_v1('__company', null, 5);
  if v_rows > 5 then
    raise exception 'limit was not applied to the cached answer: got % rows', v_rows;
  end if;
end;
$$;

commit;
