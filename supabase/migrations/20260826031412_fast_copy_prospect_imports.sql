-- Fast path for large prospect CSVs. The worker streams normalized rows into a
-- private staging table with COPY, then feeds the existing, proven v5 import
-- function locally. This removes the second file pass and PostgREST round trip
-- per 250 rows without changing canonical identity or membership semantics.
create schema if not exists prospect_import;
revoke all on schema prospect_import from public, anon, authenticated;

create table if not exists prospect_import.staged_rows (
  import_id text not null references public.imports(id) on delete cascade,
  row_offset integer not null check (row_offset >= 0),
  payload jsonb not null,
  primary key (import_id, row_offset)
);
revoke all on prospect_import.staged_rows from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'prospect_importer') then
    raise exception 'prospect_importer role is missing; run postgres/init/00-prospect-bootstrap.sh before migrations';
  end if;
end
$$;

grant usage on schema prospect_import to prospect_importer;
grant select, insert, delete on prospect_import.staged_rows to prospect_importer;

create or replace function prospect_import.process_staged_batch_v1(
  p_import_id text,
  p_list_id text,
  p_row_offset integer,
  p_batch_size integer default 1000
)
returns table(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_import
set statement_timeout = '120s'
as $function$
declare
  rows_payload jsonb;
  selected_count integer;
  first_offset integer;
  last_offset integer;
  base_result record;
begin
  if p_row_offset is null or p_row_offset < 0 then
    raise exception 'A non-negative row offset is required' using errcode = '22023';
  end if;
  if p_batch_size < 100 or p_batch_size > 5000 then
    raise exception 'Batch size must be between 100 and 5000' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.imports i
    where i.id = p_import_id and i.list_id = p_list_id
      and i.status = 'processing' and i.committed_row_offset = p_row_offset
  ) then
    raise exception 'Import cursor does not match the requested staged batch' using errcode = 'P0002';
  end if;

  select jsonb_agg(batch.payload order by batch.row_offset), count(*)::integer,
    min(batch.row_offset), max(batch.row_offset)
  into rows_payload, selected_count, first_offset, last_offset
  from (
    select sr.row_offset, sr.payload
    from prospect_import.staged_rows sr
    where sr.import_id = p_import_id and sr.row_offset >= p_row_offset
    order by sr.row_offset
    limit p_batch_size
  ) batch;

  if selected_count = 0 then
    return query select 0, 0, 0, 0;
    return;
  end if;
  if first_offset <> p_row_offset or last_offset <> p_row_offset + selected_count - 1 then
    raise exception 'Staged import rows are not contiguous at offset %', p_row_offset using errcode = 'P0002';
  end if;

  select * into base_result
  from public.import_prospect_batch_v5(p_import_id, p_list_id, rows_payload, p_row_offset);

  delete from prospect_import.staged_rows
  where import_id = p_import_id and row_offset between first_offset and last_offset;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$function$;

revoke execute on function prospect_import.process_staged_batch_v1(text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function prospect_import.process_staged_batch_v1(text, text, integer, integer)
  to prospect_importer;
