-- Disposable parity for the client-only People cursor. The runner wraps this
-- file in a transaction and rolls it back.

create or replace function pg_temp.assert_client_cursor_v2(
  p_label text,
  p_client_id text,
  p_filters jsonb
) returns void
language plpgsql
as $assert$
declare
  v_offset record;
  v_cursor record;
  v_expected text[] := '{}'::text[];
  v_actual text[] := '{}'::text[];
  v_page_ids text[];
  v_offset_value integer := 0;
  v_after_created_at timestamptz;
  v_after_id text;
  v_known_versions jsonb;
  v_length integer;
  v_first_total bigint;
  v_first_capped boolean;
begin
  -- v13 remains page-one authority and the OFFSET fallback. Build the complete
  -- expected order from it, including an empty page after an exact multiple.
  loop
    select * into strict v_offset
    from public.search_prospect_workspace_v13(
      '', p_filters, 'created_at', 'desc', 50, v_offset_value, p_client_id,
      '{}'::jsonb, v_offset_value = 0, v_known_versions);
    select coalesce(array_agg(value->>'id' order by ordinal), '{}'::text[])
      into v_page_ids
    from jsonb_array_elements(v_offset.result_rows) with ordinality rows(value, ordinal);
    v_expected := v_expected || v_page_ids;
    v_length := cardinality(v_page_ids);
    if v_offset_value = 0 then
      v_known_versions := v_offset.data_versions;
      v_first_total := v_offset.total_count;
      v_first_capped := v_offset.total_capped;
    end if;
    exit when v_length < 50;
    v_offset_value := v_offset_value + v_length;
  end loop;

  if cardinality(v_expected) = 0 then
    raise exception '% positive control matched no rows', p_label;
  end if;

  v_known_versions := null;
  loop
    select * into strict v_cursor
    from public.search_prospect_workspace_cursor_v2(
      '', p_filters, 50, p_client_id, v_after_created_at, v_after_id,
      v_known_versions is null, v_known_versions);
    select coalesce(array_agg(value->>'id' order by ordinal), '{}'::text[])
      into v_page_ids
    from jsonb_array_elements(v_cursor.result_rows) with ordinality rows(value, ordinal);
    v_length := cardinality(v_page_ids);
    if v_known_versions is null then
      if v_cursor.total_count is distinct from v_first_total
         or v_cursor.total_capped is distinct from v_first_capped then
        raise exception '% first-page count contract differs: v13=(%,%), cursor=(%,%)',
          p_label, v_first_total, v_first_capped, v_cursor.total_count, v_cursor.total_capped;
      end if;
      v_known_versions := v_cursor.data_versions;
    elsif v_cursor.total_count is not null then
      raise exception '% recounted despite an unchanged dependency vector', p_label;
    end if;
    if v_actual && v_page_ids then
      raise exception '% repeated ids across cursor pages', p_label;
    end if;
    v_actual := v_actual || v_page_ids;
    exit when v_length < 50;
    v_after_id := v_page_ids[v_length];
    v_after_created_at := (v_cursor.result_rows->(v_length - 1)->>'created_at')::timestamptz;
  end loop;

  if v_actual is distinct from v_expected then
    raise exception '% full ordered ids differ: expected %, got %', p_label, v_expected, v_actual;
  end if;
end
$assert$;

do $parity$
begin
  perform pg_temp.assert_client_cursor_v2('client membership', 'cursor-client-a', '[]'::jsonb);
  perform pg_temp.assert_client_cursor_v2(
    'list membership', 'cursor-client-a',
    '[{"field":"__list_ids","operator":"contains","values":["cursor-list-a"]}]'::jsonb);
  perform pg_temp.assert_client_cursor_v2(
    'complete profile exact multiple', 'cursor-client-a',
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb);
  perform pg_temp.assert_client_cursor_v2(
    'incomplete profile', 'cursor-client-a',
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb);
  perform pg_temp.assert_client_cursor_v2(
    'company keyword', 'cursor-client-a',
    '[{"field":"__company_keywords","operator":"contains","values":["saas"]}]'::jsonb);
end
$parity$;

-- Mutations that change dependency vectors must force a recount, and the
-- client-first cursor must keep matching v13 after company enrichment,
-- companyless reassignment, blocked membership and SEG policy changes.
do $mutations$
declare
  v_company_filter jsonb := '[{"field":"__company_keywords","operator":"contains","values":["saas"]}]'::jsonb;
  v_before record;
  v_after record;
begin
  select * into strict v_before from public.search_prospect_workspace_cursor_v2(
    '', v_company_filter, 1, 'cursor-client-a', null, null, true, null);
  update public.companies
  set short_description = short_description || ' enriched'
  where id = 'cursor-company-complete';
  select * into strict v_after from public.search_prospect_workspace_cursor_v2(
    '', v_company_filter, 1, 'cursor-client-a', null, null, false, v_before.data_versions);
  if v_after.total_count is null
     or v_after.data_versions is not distinct from v_before.data_versions then
    raise exception 'company enrichment did not invalidate the client cursor count';
  end if;

  select * into strict v_before from public.search_prospect_workspace_cursor_v2(
    '', '[]'::jsonb, 1, 'cursor-client-a', null, null, true, null);
  update public.prospects set company_id = null
  where id = 'cursor-fixture-a-130';
  perform public.reindex_prospects(array['cursor-fixture-a-130']::text[]);
  select * into strict v_after from public.search_prospect_workspace_cursor_v2(
    '', '[]'::jsonb, 1, 'cursor-client-a', null, null, false, v_before.data_versions);
  if v_after.total_count is null
     or v_after.data_versions is not distinct from v_before.data_versions then
    raise exception 'companyless reassignment did not invalidate the client cursor count';
  end if;

  update public.client_prospects set status = 'blocked'
  where client_id = 'cursor-client-a' and prospect_id = 'cursor-fixture-a-129';
  perform public.reindex_prospects(array['cursor-fixture-a-129']::text[]);
  perform pg_temp.assert_client_cursor_v2('blocked membership', 'cursor-client-a', '[]'::jsonb);

  update public.companies set email_provider_type = 'SEG'
  where id = 'cursor-company-complete';
  insert into public.client_settings(client_id, seg_emails)
  values ('cursor-client-a', 'discard')
  on conflict (client_id) do update set seg_emails = excluded.seg_emails;
  perform public.reindex_prospects(array_agg(id order by id))
  from public.prospects where company_id = 'cursor-company-complete';
  perform pg_temp.assert_client_cursor_v2(
    'SEG discarded', 'cursor-client-a',
    '[{"field":"__client_seg_policy","operator":"equals","values":["cursor-client-a"]}]'::jsonb);
  update public.client_settings set seg_emails = 'keep'
  where client_id = 'cursor-client-a';
  perform pg_temp.assert_client_cursor_v2(
    'SEG kept', 'cursor-client-a',
    '[{"field":"__client_seg_policy","operator":"equals","values":["cursor-client-a"]}]'::jsonb);
end
$mutations$;

-- Exercise the real v12 cap boundary without comparing 1,001 OFFSET pages.
-- The canonical and projection rows are disposable and schema-valid; the
-- cursor count is compared directly with v13 for both capped and exact shapes.
insert into public.clients(id, name, normalized_name)
values ('cursor-v2-scale-client', 'Cursor V2 Scale Client', 'cursor v2 scale client');

insert into public.prospects(id, full_name, work_email, company_id, all_data, created_at, updated_at)
select 'cursor-v2-scale-' || lpad(n::text, 5, '0'),
  'Cursor V2 Scale ' || n,
  'cursor-v2-scale-' || n || '@example.test',
  'cursor-company-complete',
  jsonb_build_object('fixture', 'client-cursor-v2', 'ordinal', n),
  '2025-01-01 00:00:00+00'::timestamptz + make_interval(secs => n),
  '2025-01-01 00:00:00+00'::timestamptz + make_interval(secs => n)
from generate_series(1, 50001) n;

insert into public.client_prospects(client_id, prospect_id, added_via)
select 'cursor-v2-scale-client', id, 'manual'
from public.prospects
where id like 'cursor-v2-scale-%';

insert into public.prospect_index(
  id, full_name, work_email, company_id, company_name, company_domain,
  all_data, created_at, updated_at, client_count, client_names, client_ids,
  search_text
)
select p.id, p.full_name, p.work_email, p.company_id,
  'Cursor Systems', 'cursor.example', p.all_data, p.created_at, p.updated_at,
  1, array['Cursor V2 Scale Client'], array['cursor-v2-scale-client'],
  lower(p.full_name || ' ' || p.work_email || ' Cursor Systems cursor.example')
from public.prospects p
where p.id like 'cursor-v2-scale-%'
on conflict (id) do update set
  client_count = excluded.client_count,
  client_names = excluded.client_names,
  client_ids = excluded.client_ids;

do $cap$
declare
  v_filter jsonb := '[{"field":"__company_keywords","operator":"contains","values":["saas"]}]'::jsonb;
  v13 record;
  v2 record;
  v_exact record;
  v_boundary record;
  v_deep record;
  v_expected_ids text[];
  v_actual_ids text[];
begin
  select * into strict v13 from public.search_prospect_workspace_v13(
    '', v_filter, 'created_at', 'desc', 50, 0, 'cursor-v2-scale-client',
    '{}'::jsonb, true, null);
  select * into strict v2 from public.search_prospect_workspace_cursor_v2(
    '', v_filter, 50, 'cursor-v2-scale-client', null, null, true, null);
  if (v13.total_count, v13.total_capped) is distinct from (50000::bigint, true)
     or v2.total_count is distinct from v13.total_count
     or v2.total_capped is distinct from v13.total_capped
     or v2.result_rows is distinct from v13.result_rows then
    raise exception 'client cursor v2 lost the >50,000 company-filter cap or first-page parity';
  end if;

  select * into strict v_exact from public.search_prospect_workspace_cursor_v2(
    '', '[]'::jsonb, 1, 'cursor-v2-scale-client', null, null, true, null);
  if v_exact.total_count is distinct from 50001::bigint or v_exact.total_capped is distinct from false then
    raise exception 'ordinary client cursor count is not exact: total=%, capped=%',
      v_exact.total_count, v_exact.total_capped;
  end if;

  select pi.created_at, pi.id into strict v_boundary
  from public.prospect_index pi
  where pi.client_ids @> array['cursor-v2-scale-client']
  order by pi.created_at desc, pi.id
  offset 24999 limit 1;
  select array_agg(pi.id order by pi.created_at desc, pi.id) into v_expected_ids
  from (
    select pi.id, pi.created_at
    from public.prospect_index pi
    where pi.client_ids @> array['cursor-v2-scale-client']
      and pi.created_at <= v_boundary.created_at
      and (pi.created_at < v_boundary.created_at
        or (pi.created_at = v_boundary.created_at and pi.id > v_boundary.id))
    order by pi.created_at desc, pi.id
    limit 50
  ) pi;
  select * into strict v_deep from public.search_prospect_workspace_cursor_v2(
    '', '[]'::jsonb, 50, 'cursor-v2-scale-client',
    v_boundary.created_at, v_boundary.id, false, v_exact.data_versions);
  select array_agg(value->>'id' order by ordinal) into v_actual_ids
  from jsonb_array_elements(v_deep.result_rows) with ordinality rows(value, ordinal);
  if v_actual_ids is distinct from v_expected_ids or v_deep.total_count is not null then
    raise exception 'large-client deep cursor boundary differs or recounted: expected %, got %, total %',
      v_expected_ids, v_actual_ids, v_deep.total_count;
  end if;
end
$cap$;

do $security$
declare
  v_signature text := 'public.search_prospect_workspace_cursor_v2(text,jsonb,integer,text,timestamp with time zone,text,boolean,jsonb)';
begin
  if not has_function_privilege('service_role', v_signature, 'execute')
     or has_function_privilege('anon', v_signature, 'execute')
     or has_function_privilege('authenticated', v_signature, 'execute') then
    raise exception 'client cursor v2 must remain service-role only';
  end if;
end
$security$;
