-- Disposable ordered-ID parity for the count-free client People page reader.
-- The production-hardening runner wraps this file in a transaction and rolls it
-- back, so the mutation case cannot survive the gate.

create or replace function pg_temp.assert_client_page_v1(
  p_label text,
  p_client_id text,
  p_search text,
  p_filters jsonb
) returns void
language plpgsql
as $assert$
declare
  v_offset record;
  v_page record;
  v_expected text[] := '{}'::text[];
  v_actual text[] := '{}'::text[];
  v_ids text[];
  v_offset_value integer := 0;
  v_after_created_at timestamptz;
  v_after_id text;
  v_length integer;
  v_guard integer := 0;
begin
  loop
    select * into strict v_offset
    from public.search_prospect_workspace_v13(
      p_search, p_filters, 'created_at', 'desc', 50, v_offset_value,
      p_client_id, '{}'::jsonb, false, null);
    select coalesce(array_agg(value->>'id' order by ordinal), '{}'::text[])
      into v_ids
    from jsonb_array_elements(v_offset.result_rows) with ordinality rows(value, ordinal);
    v_expected := v_expected || v_ids;
    exit when cardinality(v_ids) < 50;
    v_offset_value := v_offset_value + cardinality(v_ids);
  end loop;

  loop
    v_guard := v_guard + 1;
    if v_guard > 20 then raise exception '% page reader did not terminate', p_label; end if;
    select * into strict v_page
    from public.search_prospect_workspace_page_v1(
      p_search, p_filters, 50, p_client_id, v_after_created_at, v_after_id);
    select coalesce(array_agg(value->>'id' order by ordinal), '{}'::text[])
      into v_ids
    from jsonb_array_elements(v_page.result_rows) with ordinality rows(value, ordinal);
    v_length := cardinality(v_ids);
    if v_length > 50 then raise exception '% returned more than 50 rows', p_label; end if;
    if v_actual && v_ids then raise exception '% repeated ids across pages', p_label; end if;
    v_actual := v_actual || v_ids;
    if v_page.has_more is distinct from (cardinality(v_actual) < cardinality(v_expected)) then
      raise exception '% has_more differs at page %', p_label, v_guard;
    end if;
    exit when not v_page.has_more;
    if v_length = 0 then raise exception '% advertised another page after an empty page', p_label; end if;
    v_after_id := v_ids[v_length];
    v_after_created_at := (v_page.result_rows->(v_length - 1)->>'created_at')::timestamptz;
  end loop;

  if v_actual is distinct from v_expected then
    raise exception '% full ordered ids differ: expected %, got %', p_label, v_expected, v_actual;
  end if;
  if v_page.data_versions is null then raise exception '% omitted dependency versions', p_label; end if;
end
$assert$;

do $parity$
begin
  perform pg_temp.assert_client_page_v1(
    'name search', 'cursor-client-a', 'Cursor Fixture',
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb);
  perform pg_temp.assert_client_page_v1(
    'list filter', 'cursor-client-a', '',
    '[{"field":"__list_ids","operator":"contains","values":["cursor-list-a"]},{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb);
  perform pg_temp.assert_client_page_v1(
    'incomplete company', 'cursor-client-a', '',
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb);
  perform pg_temp.assert_client_page_v1(
    'company keyword', 'cursor-client-a', '',
    '[{"field":"__company_keywords","operator":"contains","values":["saas"]},{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb);
end
$parity$;

-- A write newer than the issued boundary must not be spliced into page two.
-- The dependency vector does change, so callers can invalidate any separately
-- frozen count, while the current traversal remains duplicate-free.
do $write_between_pages$
declare
  v_first record;
  v_second record;
  v_before_versions jsonb;
  v_boundary_id text;
  v_boundary_created_at timestamptz;
  v_first_ids text[];
  v_second_ids text[];
begin
  select * into strict v_first from public.search_prospect_workspace_page_v1(
    'Cursor Fixture',
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb,
    50, 'cursor-client-a', null, null);
  if v_first.has_more is distinct from true then
    raise exception 'write-between-pages positive control needs a second page';
  end if;
  select array_agg(value->>'id' order by ordinal),
    (v_first.result_rows->49->>'id'),
    (v_first.result_rows->49->>'created_at')::timestamptz
  into v_first_ids, v_boundary_id, v_boundary_created_at
  from jsonb_array_elements(v_first.result_rows) with ordinality rows(value, ordinal);
  v_before_versions := v_first.data_versions;

  insert into public.prospects(id, full_name, work_email, company_id, all_data, created_at, updated_at)
  values ('page-first-concurrent', 'Cursor Fixture Concurrent', 'page-first-concurrent@example.test',
    'cursor-company-complete', '{"fixture":"page-first"}'::jsonb, now(), now());
  insert into public.client_prospects(client_id, prospect_id, added_via)
  values ('cursor-client-a', 'page-first-concurrent', 'manual');
  perform public.reindex_prospects(array['page-first-concurrent']::text[]);

  select * into strict v_second from public.search_prospect_workspace_page_v1(
    'Cursor Fixture',
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb,
    50, 'cursor-client-a', v_boundary_created_at, v_boundary_id);
  select coalesce(array_agg(value->>'id' order by ordinal), '{}'::text[])
    into v_second_ids
  from jsonb_array_elements(v_second.result_rows) with ordinality rows(value, ordinal);
  if v_first_ids && v_second_ids
     or 'page-first-concurrent' = any(v_second_ids)
     or v_second.data_versions is not distinct from v_before_versions then
    raise exception 'write-between-pages lost boundary isolation or version invalidation';
  end if;
end
$write_between_pages$;

do $acl$
declare
  v_proc regprocedure := 'public.search_prospect_workspace_page_v1(text,jsonb,integer,text,timestamptz,text)'::regprocedure;
begin
  if not has_function_privilege('service_role', v_proc, 'execute')
     or has_function_privilege('anon', v_proc, 'execute')
     or has_function_privilege('authenticated', v_proc, 'execute') then
    raise exception 'client People page v1 ACL differs from service-role-only contract';
  end if;
end
$acl$;
