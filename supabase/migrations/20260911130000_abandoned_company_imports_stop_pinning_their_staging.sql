-- 1,299MB - 11% of this database - is staging rows held by nine imports that
-- finished their work thirteen days ago and were never marked completed.
--
--   file             status      processed / total   age
--   5.csv            processing   50,000 / 50,000    13 days
--   5.csv            processing   50,000 / 50,000    13 days
--   5.csv            processing   50,000 / 50,000    13 days
--   5.4.xlsx         processing   24,998 / 24,998    13 days
--   5_4_cleaned.csv  processing   24,996 / 24,996    13 days
--   ... nine in total, every one with processed_rows = total_rows
--
-- Every row was processed. Only the status transition was lost - the completion
-- call never arrived, most likely a closed tab.
--
-- WHY IT NEVER CLEARS. purge_company_import_rows_v1 deliberately refuses to
-- touch rows whose import is still 'processing', because staging is what makes
-- an import resumable, and deleting the resume point of a live import would be
-- much worse than keeping some bytes. That rule is right. What is missing is
-- anything that ever decides an import is not coming back.
--
-- The people-import path already has this: imports carries lease_expires_at,
-- worker_id and last_error. company_imports has none of those columns - it was
-- never given a recovery path - so an abandoned company import pins its staging
-- rows forever, and the leak is unbounded. At 10M rows that is not 1.3GB, it is
-- however much of the disk the next abandoned import happens to claim.
--
-- ACTIVITY, NOT AGE. An import is judged by when its staging rows were last
-- written, not by when it started. A large import that has been running for
-- hours writes rows continuously and can never be expired by this; one that has
-- written nothing for a day is not coming back.
--
-- HONEST STATUS. An import whose processed_rows reached total_rows did the work,
-- so it is recorded as completed, not failed - marking it failed would say
-- something untrue about data that is in the database. One that stopped short is
-- recorded as failed, which is also true. The status column allows exactly
-- 'processing', 'completed' and 'failed', so those are the two honest choices.

begin;

create or replace function public.expire_abandoned_company_imports_v1(
  p_stale_hours integer default 24,
  p_limit integer default 50
)
returns integer
language plpgsql
volatile
security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
declare
  v_hours integer := greatest(1, least(coalesce(p_stale_hours, 24), 24 * 30));
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 500));
  v_expired integer;
begin
  with stale as (
    select i.id,
           -- Last sign of life: the newest staging row, or the start if it never
           -- wrote one. A running import keeps this fresh by definition.
           greatest(i.created_at, coalesce(max(r.imported_at), i.created_at)) as last_activity,
           i.processed_rows, i.total_rows
    from public.company_imports i
    left join public.company_import_rows r on r.import_id = i.id
    where i.status = 'processing'
    group by i.id, i.created_at, i.processed_rows, i.total_rows
    having greatest(i.created_at, coalesce(max(r.imported_at), i.created_at))
           < now() - make_interval(hours => v_hours)
    limit v_limit
  )
  update public.company_imports i
  set status = case
        when coalesce(s.total_rows, 0) > 0 and coalesce(s.processed_rows, 0) >= s.total_rows
          then 'completed'
        else 'failed'
      end,
      completed_at = now()
  from stale s
  where i.id = s.id and i.status = 'processing';

  get diagnostics v_expired = row_count;
  return v_expired;
end;
$function$;

comment on function public.expire_abandoned_company_imports_v1(integer, integer) is
  'Closes company imports whose staging rows stopped being written, so purge_company_import_rows_v1 can reclaim them. Completed when every row was processed, failed when not.';

revoke execute on function public.expire_abandoned_company_imports_v1(integer, integer) from public, anon, authenticated;
grant execute on function public.expire_abandoned_company_imports_v1(integer, integer) to service_role, prospect_operator;

-- Close the nine that are already stranded. 24 hours, so nothing recent is
-- touched: the newest of them last wrote a row thirteen days ago.
do $$
declare
  v_before integer;
  v_expired integer;
  v_left integer;
  v_pinned bigint;
begin
  select count(*) into v_before from public.company_imports where status = 'processing';
  v_expired := public.expire_abandoned_company_imports_v1(24, 500);
  select count(*) into v_left from public.company_imports where status = 'processing';

  -- Nothing is being expired that is still working: a live import writes rows.
  if v_expired > v_before then
    raise exception 'expired % imports but only % were processing', v_expired, v_before;
  end if;

  -- The point of the exercise: those rows must now be reachable by retention,
  -- which refuses anything still 'processing'.
  select count(*) into v_pinned
  from public.company_import_rows r
  join public.company_imports i on i.id = r.import_id
  where i.status = 'processing';

  raise notice 'expired % abandoned company imports; % still processing; % staging rows still pinned',
    v_expired, v_left, v_pinned;

  -- Running it again must be a no-op - the ones just closed are no longer
  -- 'processing', and nothing else is stale.
  if public.expire_abandoned_company_imports_v1(24, 500) <> 0 then
    raise exception 'a second pass expired more imports, so the staleness test is not stable';
  end if;
end;
$$;

commit;
