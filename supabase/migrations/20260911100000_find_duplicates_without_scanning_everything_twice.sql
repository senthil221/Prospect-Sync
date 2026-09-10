-- find_duplicate_candidates is the heaviest query in the application: 38,240ms
-- mean and 60,747ms max against real traffic, and it degrades worse than
-- linearly because it is a self-join. Tier 1 stopped it hurting anyone else by
-- capping its concurrency and giving it a deadline. This makes it stop being
-- slow.
--
-- WHAT IT WAS DOING. Measured with EXPLAIN (analyze, buffers) on production:
--
--   Merge Join   Rows Removed by Join Filter: 681,808   (to keep 25)
--   Sort         external merge  Disk: 69,912kB
--   GroupAggregate rows=681,743                          6,262ms
--   Buffers: shared hit=2,022,431 read=13,460
--
-- Two million buffer accesses - about 16GB of traffic through a 2GB cache - a
-- 70MB on-disk sort, and a GroupAggregate materialising all 681,743 rows of
-- prospect_summaries, which is a live aggregating view. All of it to join
-- everything against everything, discard 681,808 rows, and keep 25.
--
-- WHAT IT DOES NOW. The same answer is a grouping, not a join: names that occur
-- more than once inside one company are the only possible duplicates, and there
-- are 45 such groups. Group first on prospect_index - the denormalized table
-- that exists for exactly this - then pair up only inside those groups.
--
-- MATERIALIZED is load-bearing, the same way it is in prospect_title_taxonomy_v1:
-- two CTEs read `candidates`, and since PostgreSQL 12 a CTE read more than once
-- is inlined by default, so the scan ran twice. Measured: 6,252ms inlined
-- against 2,064ms materialised.
--
-- Hydration is the other half. prospect_summaries pushes a filter down when it
-- is given a literal or an array parameter, and does not when it is given a
-- join or a subquery - 29ms and 4.5ms against 4,228ms for the same 200 rows. So
-- the pairs are collected into arrays first and the view is read with
-- `id = any(...)`, never joined to.
--
--   26,276ms -> 2,064ms, and the output is unchanged.
--
-- DELIBERATELY NO INDEX. An expression index on (lower(btrim(full_name)),
-- company_id) would take the remaining 2s down further, but prospect_index
-- already carries 45 indexes and is written continuously by the import and
-- classification workers. Taxing every write on the busiest path in the system
-- to save a second on a tab nobody opens twice a day is the wrong trade.
--
-- ORDERING. The old function had no ORDER BY inside its jsonb_agg, so the array
-- order was whatever the executor produced and was undefined whenever two rows
-- shared an updated_at. This orders by updated_at desc then id. Verified on
-- production: the 25 elements are byte-identical as a set (md5 of the sorted
-- elements matches exactly), only the array order is now deterministic.

begin;

-- Prove it on this database's own data, not just on the one I measured. The old
-- answer is captured before the replacement exists, and compared after.
create temp table duplicate_baseline on commit drop as
select count(*) as element_count,
       md5(string_agg(e::text, '|' order by e::text)) as sorted_fingerprint
from public.find_duplicate_candidates(100) f, jsonb_array_elements(f.result_rows) e;

create or replace function public.find_duplicate_candidates(p_limit integer default 100)
returns table(result_rows jsonb)
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '120s'
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 250));
  v_left text[];
  v_right text[];
  v_summaries jsonb;
begin
  with candidates as materialized (
    select pi.id, pi.company_id, lower(btrim(pi.full_name)) as k, pi.updated_at, pi.client_ids
    from public.prospect_index pi
    where btrim(coalesce(pi.full_name, '')) <> '' and pi.company_id is not null
  ),
  -- The whole saving: a name that occurs once inside its company cannot be a
  -- duplicate of anything, so 681,743 rows collapse to 45 groups before any
  -- pairing happens.
  grouped as (
    select k, company_id from candidates group by k, company_id having count(*) > 1
  ),
  members as (
    select c.* from candidates c join grouped g on g.k = c.k and g.company_id = c.company_id
  ),
  pairs as (
    select l.id as left_id, r.id as right_id, l.updated_at as left_updated
    from members l
    join members r on r.k = l.k and r.company_id = l.company_id and l.id < r.id
    -- Same person under two different clients is the thing worth surfacing.
    where exists (
      select 1 from unnest(l.client_ids) left_client(id)
      cross join unnest(r.client_ids) right_client(id)
      where left_client.id <> right_client.id
    )
  )
  select array_agg(left_id order by left_updated desc, left_id),
         array_agg(right_id order by left_updated desc, left_id)
  into v_left, v_right
  from (select left_id, right_id, left_updated from pairs order by left_updated desc, left_id limit v_limit) ranked;

  if v_left is null then
    return query select '[]'::jsonb;
    return;
  end if;

  -- `= any(array)` and not a join: the view pushes this down, and pushes a join
  -- down not at all.
  select coalesce(jsonb_object_agg(s.id, to_jsonb(s)), '{}'::jsonb)
  into v_summaries
  from public.prospect_summaries s
  where s.id = any(v_left || v_right);

  return query
  select coalesce(jsonb_agg(jsonb_build_object(
    'left', v_summaries -> v_left[i],
    'right', v_summaries -> v_right[i],
    'reason', 'Same person found in different clients',
    'confidence', 90
  ) order by i), '[]'::jsonb)
  -- Both sides must have hydrated, which is what the old inner join enforced.
  from generate_subscripts(v_left, 1) i
  where v_summaries ? v_left[i] and v_summaries ? v_right[i];
end;
$function$;

comment on function public.find_duplicate_candidates(integer) is
  'Cross-client duplicate people. Groups prospect_index by name within company, then hydrates only the winning pairs from prospect_summaries.';

revoke execute on function public.find_duplicate_candidates(integer) from public, anon, authenticated;
grant execute on function public.find_duplicate_candidates(integer) to service_role;

do $$
declare
  v_count integer;
  v_fingerprint text;
  v_baseline record;
  v_config text[];
begin
  select * into v_baseline from duplicate_baseline;

  select count(*), md5(string_agg(e::text, '|' order by e::text))
  into v_count, v_fingerprint
  from public.find_duplicate_candidates(100) f, jsonb_array_elements(f.result_rows) e;

  if v_count <> v_baseline.element_count then
    raise exception 'duplicate candidates changed: % pairs, was %', v_count, v_baseline.element_count;
  end if;
  if v_fingerprint is distinct from v_baseline.sorted_fingerprint then
    raise exception 'duplicate candidate contents changed (sorted fingerprint % vs %)',
      v_fingerprint, v_baseline.sorted_fingerprint;
  end if;

  -- The timeout Tier 1 added must survive CREATE OR REPLACE, which drops proconfig.
  select proconfig into v_config from pg_proc
  where oid = to_regprocedure('public.find_duplicate_candidates(integer)');
  if v_config is null or not (v_config @> array['statement_timeout=120s']) then
    raise exception 'the 120s statement timeout did not survive the replace: %', v_config;
  end if;
end;
$$;

commit;
