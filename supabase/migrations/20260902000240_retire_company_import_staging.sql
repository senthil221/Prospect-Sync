-- Give company import staging a retention policy. Three days, completed only.
--
-- company_import_rows holds the raw spreadsheet cells every company import was
-- built from. Nothing reads it: no application code references the table, its
-- statistics show 4 sequential scans and zero index scans for its lifetime, and
-- its one index on company_id has never been used. It is the third-largest
-- object in the database at 1,299 MB, of which 951 MB is raw_data jsonb, and it
-- sits in a 2 GB shared_buffers competing with tables that are actually queried.
--
-- WHY IT IS NOT SIMPLY "OLDER THAN THREE DAYS". At the time of writing, 262,484
-- of the 646,873 staged rows belong to nine imports still marked 'processing',
-- created 28-29 August. Import staging is what makes an import resumable
-- (20260816013930), so deleting the rows out from under a job that has not
-- finished would turn a stalled import into an unrecoverable one. Age alone is
-- the wrong test; age AND a finished parent is the right one.
--
-- Those nine imports are themselves worth a look -- a week in 'processing' is
-- almost certainly abandoned rather than running -- but that is a decision about
-- data, not a thing a migration should assume. They are left untouched, and this
-- function will collect them the moment their status moves off 'processing'.
--
-- BATCHED, because a single delete of several hundred thousand rows holds one
-- transaction open long enough to block autovacuum across the database and
-- leaves a bloat spike behind it. Each batch commits on its own.
--
-- The space comes back as reusable space, not as free disk. Almost every row
-- qualifies, so a plain VACUUM afterwards will truncate the trailing empty pages
-- and most of it does return to the filesystem; a full reclaim would need
-- VACUUM FULL and an exclusive lock, which is not worth a maintenance window
-- for a table that is about to start refilling anyway.

begin;

create or replace function public.purge_company_import_rows_v1(
  p_keep_days integer default 3,
  p_batch_size integer default 25000,
  p_max_batches integer default 200
)
returns integer
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_cutoff timestamptz := now() - make_interval(days => greatest(1, coalesce(p_keep_days, 3)));
  v_batch integer := greatest(1000, least(coalesce(p_batch_size, 25000), 100000));
  v_deleted integer := 0;
  v_round integer := 0;
  v_removed integer;
begin
  loop
    v_round := v_round + 1;
    exit when v_round > greatest(1, coalesce(p_max_batches, 200));

    -- Only rows whose import has actually finished. A row belonging to an
    -- import still in 'processing' is the resume point for that import and is
    -- never eligible, however old it is.
    with doomed as (
      select r.import_id, r.source_row_number
      from public.company_import_rows r
      join public.company_imports i on i.id = r.import_id
      where r.imported_at < v_cutoff
        and i.status <> 'processing'
      limit v_batch
    )
    delete from public.company_import_rows r
    using doomed d
    where r.import_id = d.import_id and r.source_row_number = d.source_row_number;

    get diagnostics v_removed = row_count;
    v_deleted := v_deleted + v_removed;
    exit when v_removed = 0;
  end loop;

  return v_deleted;
end;
$function$;

comment on function public.purge_company_import_rows_v1(integer, integer, integer) is
  'Deletes company import staging rows older than p_keep_days whose parent import has finished. Rows belonging to imports still in ''processing'' are never removed, because staging is what makes an import resumable.';

-- Deliberately not granted to service_role. It deletes rows, nothing in the
-- application needs it, and maintenance.sh runs as postgres.
revoke execute on function public.purge_company_import_rows_v1(integer, integer, integer) from public, anon, authenticated;

commit;
