begin;
set local statement_timeout = '30s';

create or replace function pg_temp.assert_cursor_case(
  p_label text,
  p_filters jsonb,
  p_client_id text,
  p_expected_total integer
) returns void
language plpgsql
as $assert$
declare
  v_offset_page record;
  v_cursor_page record;
  v_page_ids text[];
  v_all_ids text[] := '{}'::text[];
  v_after_created_at timestamptz;
  v_after_id text;
  v_known_versions jsonb;
  v_offset integer := 0;
  v_page_length integer;
  v_expected_page_length integer;
  v_last_page_length integer;
  v_previous_last_id text;
begin
  loop
    select * into strict v_offset_page
    from public.search_prospect_workspace_v13(
      '', p_filters, 'created_at', 'desc', 50, v_offset, p_client_id,
      '{}'::jsonb, v_offset = 0, v_known_versions);
    select * into strict v_cursor_page
    from public.search_prospect_workspace_cursor_v1(
      '', p_filters, 50, p_client_id, v_after_created_at, v_after_id,
      v_offset = 0, v_known_versions);

    if v_cursor_page.result_rows is distinct from v_offset_page.result_rows
       or v_cursor_page.total_count is distinct from v_offset_page.total_count
       or v_cursor_page.scope_capped is distinct from v_offset_page.scope_capped
       or v_cursor_page.total_capped is distinct from v_offset_page.total_capped
       or v_cursor_page.data_versions is distinct from v_offset_page.data_versions then
      raise exception '% page at offset % differs from workspace v13', p_label, v_offset;
    end if;

    v_page_length := jsonb_array_length(v_cursor_page.result_rows);
    v_expected_page_length := least(50, p_expected_total - v_offset);
    if v_page_length <> v_expected_page_length then
      raise exception '% page at offset % has % rows, expected %',
        p_label, v_offset, v_page_length, v_expected_page_length;
    end if;
    if v_offset = 0 then
      if v_cursor_page.total_count <> p_expected_total then
        raise exception '% total is %, expected %', p_label,
          v_cursor_page.total_count, p_expected_total;
      end if;
      v_known_versions := v_cursor_page.data_versions;
    elsif v_cursor_page.total_count is not null then
      raise exception '% recounted an unchanged total at offset %', p_label, v_offset;
    end if;

    select array_agg(value->>'id' order by ordinal) into v_page_ids
    from jsonb_array_elements(v_cursor_page.result_rows)
      with ordinality rows(value, ordinal);
    if v_all_ids && v_page_ids then
      raise exception '% repeated a row by offset %', p_label, v_offset;
    end if;
    if v_offset = 50 and (
      v_previous_last_id <> 'cursor-fixture-a-050'
      or v_page_ids[1] <> 'cursor-fixture-a-051'
    ) then
      raise exception '% did not preserve created_at DESC, id ASC at the tie boundary: % -> %',
        p_label, v_previous_last_id, v_page_ids[1];
    end if;

    v_all_ids := v_all_ids || v_page_ids;
    v_last_page_length := v_page_length;
    v_offset := v_offset + v_page_length;
    exit when v_offset = p_expected_total;
    if v_offset > p_expected_total or v_page_length = 0 then
      raise exception '% traversal did not terminate exactly at % rows', p_label, p_expected_total;
    end if;

    v_previous_last_id := v_page_ids[v_page_length];
    v_after_id := v_previous_last_id;
    v_after_created_at := (v_cursor_page.result_rows->(v_page_length - 1)->>'created_at')::timestamptz;
  end loop;

  if cardinality(v_all_ids) <> p_expected_total
     or v_last_page_length <> (p_expected_total % 50) then
    raise exception '% did not traverse a final partial page: rows=%, last_page=%',
      p_label, cardinality(v_all_ids), v_last_page_length;
  end if;
end
$assert$;

do $cursor_contract$
declare
  v_known jsonb;
  v_after jsonb;
  v_offset record;
  v_cursor record;
  v_proc record;
  v_public_execute boolean;
  v_legacy_public_execute boolean;
  v_signature text := 'public.search_prospect_workspace_cursor_v1(text,jsonb,integer,text,timestamp with time zone,text,boolean,jsonb)';
  v_legacy_signature text := 'public.search_prospect_workspace_v13(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)';
begin
  if (select count(*) from public.prospect_index where id like 'cursor-fixture-%') <> 151 then
    raise exception 'cursor fixture is not present after the schema baseline restore';
  end if;

  perform pg_temp.assert_cursor_case('global', '[]'::jsonb, null, 151);
  perform pg_temp.assert_cursor_case('client A', '[]'::jsonb, 'cursor-client-a', 130);
  perform pg_temp.assert_cursor_case(
    'person filter',
    '[{"field":"__title","operator":"contains","values":["er"]}]'::jsonb,
    null, 130);
  perform pg_temp.assert_cursor_case(
    'list A filter',
    '[{"field":"__list_ids","operator":"contains","values":["cursor-list-a"]}]'::jsonb,
    null, 110);

  v_known := public.data_versions_v1(array['prospect']);
  select * into strict v_offset from public.search_prospect_workspace_v13(
    '', '[]'::jsonb, 'created_at', 'desc', 50, 0, null, '{}'::jsonb, false, v_known);
  select * into strict v_cursor from public.search_prospect_workspace_cursor_v1(
    '', '[]'::jsonb, 50, null, null, null, false, v_known);
  if v_offset.total_count is not null or v_cursor.total_count is not null
     or v_cursor.data_versions is distinct from v_offset.data_versions then
    raise exception 'an unchanged prospect version did not reuse the cached total contract';
  end if;

  perform nextval('public.data_version_prospect');
  v_after := public.data_versions_v1(array['prospect']);
  if v_after = v_known then
    raise exception 'prospect version did not advance';
  end if;
  select * into strict v_offset from public.search_prospect_workspace_v13(
    '', '[]'::jsonb, 'created_at', 'desc', 50, 0, null, '{}'::jsonb, false, v_known);
  select * into strict v_cursor from public.search_prospect_workspace_cursor_v1(
    '', '[]'::jsonb, 50, null, null, null, false, v_known);
  if v_cursor.total_count is distinct from v_offset.total_count
     or v_cursor.total_count <> 151
     or v_cursor.data_versions is distinct from v_offset.data_versions
     or v_cursor.data_versions is distinct from v_after then
    raise exception 'a stale prospect version did not force the equivalent recount';
  end if;

  if has_function_privilege('service_role', v_signature, 'execute') is distinct from
       has_function_privilege('service_role', v_legacy_signature, 'execute')
     or has_function_privilege('anon', v_signature, 'execute') is distinct from
       has_function_privilege('anon', v_legacy_signature, 'execute')
     or has_function_privilege('authenticated', v_signature, 'execute') is distinct from
       has_function_privilege('authenticated', v_legacy_signature, 'execute')
     or not has_function_privilege('service_role', v_signature, 'execute')
     or has_function_privilege('anon', v_signature, 'execute')
     or has_function_privilege('authenticated', v_signature, 'execute') then
    raise exception 'cursor RPC execute privileges differ from workspace v13 or violate service-role-only access';
  end if;

  select exists (
    select 1
    from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl_entry
    where p.oid = to_regprocedure(v_signature)
      and acl_entry.grantee = 0
      and acl_entry.privilege_type = 'EXECUTE'
  ) into v_public_execute;
  select exists (
    select 1
    from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl_entry
    where p.oid = to_regprocedure(v_legacy_signature)
      and acl_entry.grantee = 0
      and acl_entry.privilege_type = 'EXECUTE'
  ) into v_legacy_public_execute;
  if v_public_execute is distinct from v_legacy_public_execute or v_public_execute then
    raise exception 'cursor RPC PUBLIC execute privilege differs from workspace v13 or remains granted';
  end if;

  select p.prosecdef, p.provolatile, p.proconfig, r.rolname as owner
  into strict v_proc
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_roles r on r.oid = p.proowner
  where n.nspname = 'public'
    and p.proname = 'search_prospect_workspace_cursor_v1'
    and pg_get_function_identity_arguments(p.oid) =
      'p_search text, p_filters jsonb, p_limit integer, p_client_id text, p_after_created_at timestamp with time zone, p_after_id text, p_with_total boolean, p_known_versions jsonb';
  if not v_proc.prosecdef or v_proc.provolatile <> 's' or v_proc.owner <> current_user
     or not ('search_path=pg_catalog, public' = any(v_proc.proconfig))
     or not ('statement_timeout=20s' = any(v_proc.proconfig)) then
    raise exception 'cursor RPC security/runtime attributes are wrong: %', row_to_json(v_proc);
  end if;
end
$cursor_contract$;

rollback;
