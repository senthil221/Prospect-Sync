-- Remove the minimal rows used only by 20260902000280's fixed 20,000-row
-- historical assertion. Deleting the canonical rows cascades to prospect_index.
delete from public.prospects
where id like 'cursor-history-volume-%';

do $history_volume_cleanup$
declare
  v_synthetic bigint;
  v_cursor_rows bigint;
  v_total_indexed bigint;
begin
  select count(*) into v_synthetic from public.prospects
    where id like 'cursor-history-volume-%';
  select count(*) into v_cursor_rows from public.prospect_index
    where id like 'cursor-fixture-%';
  select count(*) into v_total_indexed from public.prospect_index;

  if (v_synthetic, v_cursor_rows, v_total_indexed)
     is distinct from (0::bigint, 151::bigint, 151::bigint) then
    raise exception 'historical volume cleanup failed: synthetic=%, cursor=%, total=%',
      v_synthetic, v_cursor_rows, v_total_indexed;
  end if;
end
$history_volume_cleanup$;
