-- Controlled, read-only post-deploy canary. It intentionally checks only two
-- indexed global pages and never discovers client/list samples by scanning
-- membership tables. Scoped equivalence is covered non-skippably in disposable
-- CI with the reviewed synthetic fixture.
begin transaction read only;
set local statement_timeout = '15s';
set local lock_timeout = '2s';

do $canary$
declare
  v_versions jsonb := public.data_versions_v1(array['prospect']);
  v_first jsonb;
  v_boundary jsonb;
  v_cursor jsonb;
  v_offset jsonb;
begin
  select result_rows into strict v_first
  from public.search_prospect_workspace_v13(
    '', '[]'::jsonb, 'created_at', 'desc', 50, 0, null,
    '{}'::jsonb, false, v_versions
  );
  if jsonb_array_length(v_first) < 50 then
    raise exception 'live cursor canary requires at least 50 global People rows';
  end if;

  v_boundary := v_first->49;
  select result_rows into strict v_cursor
  from public.search_prospect_workspace_cursor_v1(
    '', '[]'::jsonb, 50, null,
    (v_boundary->>'created_at')::timestamptz, v_boundary->>'id', false, v_versions
  );
  select result_rows into strict v_offset
  from public.search_prospect_workspace_v13(
    '', '[]'::jsonb, 'created_at', 'desc', 50, 50, null,
    '{}'::jsonb, false, v_versions
  );

  if (select array_agg(item->>'id') from jsonb_array_elements(v_cursor) item)
     is distinct from
     (select array_agg(item->>'id') from jsonb_array_elements(v_offset) item) then
    raise exception 'live cursor canary differs from workspace v13 page two';
  end if;
end
$canary$;

rollback;
