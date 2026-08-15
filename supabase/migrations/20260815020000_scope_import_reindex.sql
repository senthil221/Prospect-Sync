-- Fix O(N^2) reindex that made large prospect imports time out.
--
-- WHY
-- import_prospect_batch_v5 reindexed EVERY prospect imported so far for the whole
-- import on each chunk:
--   reindex_prospects(select distinct prospect_id from list_rows where import_id = p_import_id)
-- so chunk 1 reindexed 100 rows, chunk 2 reindexed 200, ... chunk N reindexed
-- N*100. On a large list the later chunks reindex thousands of prospects inside a
-- single request and blow PostgREST's 8s authenticator cap ("canceling statement
-- due to statement timeout"). The company-count trigger added alongside the
-- Company DB fix amplified it (every reindexed row also recomputes its company),
-- tipping borderline imports over.
--
-- FIX
-- Reindex only the CURRENT chunk's rows (matched by this import's source row
-- numbers, which the chunk always sends), turning each chunk back into O(chunk).
-- Also give the import RPC an explicit statement_timeout so a pathological chunk
-- fails slow instead of at 8s -- same pattern as the search RPCs.

create or replace function public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb)
returns table(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
language plpgsql
security definer
set search_path = public
set statement_timeout = '20s'
as $function$
declare
  base_result record;
begin
  select * into base_result
  from public.import_prospect_batch_v4(p_import_id, p_list_id, p_rows);

  -- Only the prospects touched by THIS chunk, not every row of the import.
  perform public.reindex_prospects(array(
    select distinct lr.prospect_id
    from public.list_rows lr
    where lr.import_id = p_import_id
      and lr.prospect_id is not null
      and lr.source_row_number = any(
        select (elem->>'sourceRowNumber')::integer
        from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as elem
        where nullif(elem->>'sourceRowNumber', '') is not null
      )
  ));

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$function$;
