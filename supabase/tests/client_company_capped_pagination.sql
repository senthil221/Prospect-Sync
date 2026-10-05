\set ON_ERROR_STOP on

-- A deterministic result larger than the interactive 50,000-count budget.
-- It proves that count capping does not cap ordered page access or exports.
do $$ begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'Refusing capped-pagination fixture outside its disposable database.';
  end if;
end $$;

insert into public.clients(id, name, normalized_name)
values ('stored-count-scale-client', 'Stored Count Scale Client', 'stored count scale client');
insert into public.client_settings(client_id, seg_emails)
values ('stored-count-scale-client', 'keep');

insert into public.companies(
  id, name, normalized_name, domain, normalized_domain, keywords, short_description
)
select
  'stored-count-scale-' || lpad(n::text, 5, '0'),
  'Stored Count Scale ' || lpad(n::text, 5, '0'),
  'stored count scale ' || lpad(n::text, 5, '0'),
  'stored-count-scale-' || n || '.test',
  'stored-count-scale-' || n || '.test',
  array['software'], 'Complete scale fixture'
from generate_series(1, 50051) n;

insert into public.client_companies(client_id, company_id, added_by)
select 'stored-count-scale-client', id, 'scale-fixture'
from public.companies where id like 'stored-count-scale-%';

do $cap$
declare
  v_filters jsonb := jsonb_build_array(
    jsonb_build_object('field','__client_company_scope','operator','equals','values',jsonb_build_array('stored-count-scale-client')),
    jsonb_build_object('field','__incomplete_company_profile','operator','equals','values',jsonb_build_array('false')),
    jsonb_build_object('field','__client_seg_policy','operator','equals','values',jsonb_build_array('stored-count-scale-client'))
  );
  v_workspace record;
  v_rows jsonb;
  v_exported integer := 0;
  v_after_name text := null;
  v_after_id text := null;
  v_last jsonb;
begin
  select * into v_workspace from public.client_company_workspace_v2(
    'stored-count-scale-client', 'Stored Count Scale', v_filters, null, 51, 49950);
  if v_workspace.total_count <> 50000 or not v_workspace.total_capped
     or jsonb_array_length(v_workspace.result_rows) <> 51 then
    raise exception 'capped full page mismatch: total %, capped %, rows %',
      v_workspace.total_count, v_workspace.total_capped, jsonb_array_length(v_workspace.result_rows);
  end if;
  if v_workspace.covered_count <> 0 or v_workspace.prospect_count <> 0 then
    raise exception 'zero-person scale summaries changed: covered %, people %',
      v_workspace.covered_count, v_workspace.prospect_count;
  end if;

  -- The route supports pageSize=100, which is also the RPC's maximum. There is
  -- deliberately no 101st look-ahead row at this boundary; a full page must
  -- still be returned so the UI can use its capped-total fallback for Next.
  -- p_limit=100 boundary
  select * into v_workspace from public.client_company_workspace_v2(
    'stored-count-scale-client', 'Stored Count Scale', v_filters, null, 100, 49900);
  if jsonb_array_length(v_workspace.result_rows) <> 100 then
    raise exception '100-row RPC boundary returned % rows', jsonb_array_length(v_workspace.result_rows);
  end if;

  select * into v_workspace from public.client_company_workspace_v2(
    'stored-count-scale-client', 'Stored Count Scale', v_filters, null, 51, 50050);
  if jsonb_array_length(v_workspace.result_rows) <> 1
     or v_workspace.result_rows->0->>'id' <> 'stored-count-scale-50051' then
    raise exception 'page access stopped at the count cap: %', v_workspace.result_rows;
  end if;

  -- The stream's keyset cursor must traverse the complete client scope, not the
  -- interactive count budget.  Eleven bounded pages cover all 50,051 rows.
  loop
    select result_rows into v_rows from public.search_company_export_v2(
      'Stored Count Scale', v_filters, null, false,
      v_after_name, v_after_id, 5000, array['name']);
    exit when jsonb_array_length(v_rows) = 0;
    v_exported := v_exported + jsonb_array_length(v_rows);
    v_last := v_rows->(jsonb_array_length(v_rows) - 1);
    v_after_name := v_last->>'sort_name';
    v_after_id := v_last->>'id';
    if v_exported > 50051 then
      raise exception 'company export cursor repeated rows';
    end if;
  end loop;
  if v_exported <> 50051 then
    raise exception 'company export stopped at %, expected 50051', v_exported;
  end if;
end;
$cap$;
