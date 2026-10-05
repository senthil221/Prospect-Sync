\set ON_ERROR_STOP on

-- Disposable full-ID parity for the indexed Company Keywords compiler path.
-- The caller wraps this fixture in a transaction and rolls it back.
do $$ begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'Refusing company-keyword parity fixture outside its disposable database.';
  end if;
end $$;

insert into public.clients(id, name, normalized_name)
values ('keyword-index-client', 'Keyword Index Client', 'keyword index client');
insert into public.client_settings(client_id, seg_emails)
values ('keyword-index-client', 'discard');

insert into public.companies(
  id, name, normalized_name, domain, normalized_domain, keywords,
  short_description, email_provider_type
) values
  ('keyword-index-name', 'Blockchain Atlas', 'blockchain atlas', 'kw-name.test', 'kw-name.test', array['finance'], 'Ordinary profile', 'Mailbox provider'),
  ('keyword-index-description', 'Description Match', 'description match', 'kw-description.test', 'kw-description.test', array['finance'], 'Builds BLOCKCHAIN infrastructure', 'Mailbox provider'),
  -- Stored tags use the production-normalized lowercase form. The case battery
  -- below still proves an uppercase user term reaches this tag through
  -- keyword_tag_variants_v1(original + lower(input)).
  ('keyword-index-tag', 'Tag Match', 'tag match', 'kw-tag.test', 'kw-tag.test', array['blockchain'], 'Ordinary profile', 'Mailbox provider'),
  ('keyword-index-duplicate', 'Duplicate blockchain', 'duplicate blockchain', 'kw-duplicate.test', 'kw-duplicate.test', array['blockchain'], 'blockchain twice', 'Mailbox provider'),
  -- Production models missing keyword/description data with schema-valid empty
  -- values; both columns are NOT NULL. The companyless person below covers a
  -- genuinely missing company join.
  ('keyword-index-null', 'Blank Profile', 'blank profile', 'kw-null.test', 'kw-null.test', '{}'::text[], '', 'Mailbox provider'),
  ('keyword-index-special', 'Pipe|Blockchain 100%', 'pipe blockchain 100', 'kw-special.test', 'kw-special.test', array['pipe|blockchain'], 'Literal under_score and back\\slash', 'Mailbox provider'),
  ('keyword-index-seg', 'Blockchain SEG', 'blockchain seg', 'kw-seg.test', 'kw-seg.test', array['blockchain'], 'Complete SEG profile', 'SEG'),
  ('keyword-index-incomplete', 'Blockchain Incomplete', 'blockchain incomplete', '', '', '{}'::text[], '', 'Mailbox provider');

insert into public.prospects(id, full_name, work_email, company_id)
select 'keyword-person-' || replace(id, 'keyword-index-', ''), name || ' Person',
       replace(id, 'keyword-index-', '') || '@keyword.test', id
from public.companies where id like 'keyword-index-%';
insert into public.prospects(id, full_name, work_email, company_id)
values ('keyword-person-companyless', 'Companyless Person', 'companyless@keyword.test', null);

insert into public.client_prospects(client_id, prospect_id, status)
select 'keyword-index-client', id, 'active'
from public.prospects where id like 'keyword-person-%';
insert into public.lists(id, client_id, name)
values ('keyword-index-list', 'keyword-index-client', 'Keyword Fixture');
insert into public.imports(
  id, client_id, list_id, file_name, status, total_rows, processed_rows,
  unique_added, duplicates_linked, completed_at
) values (
  'keyword-index-import', 'keyword-index-client', 'keyword-index-list',
  'keyword-index-fixture.csv', 'completed', 4, 4, 4, 0, now()
);
insert into public.list_memberships(list_id, prospect_id, import_id)
select 'keyword-index-list', id, 'keyword-index-import' from public.prospects
where id in ('keyword-person-name', 'keyword-person-description', 'keyword-person-tag', 'keyword-person-seg');

select public.reindex_prospects(array_agg(id order by id))
from public.prospects where id like 'keyword-person-%';

create function pg_temp.assert_keyword_parity(p_label text, p_filters jsonb)
returns void language plpgsql as $$
declare
  v_compiled text[];
  v_matched text[];
begin
  execute format(
    'select coalesce(array_agg(pi.id order by pi.id), array[]::text[]) from public.prospect_index pi where pi.id like %L and (%s)',
    'keyword-person-%', public.prospect_filter_sql_v1('', p_filters)) into v_compiled;
  select coalesce(array_agg(pi.id order by pi.id), array[]::text[]) into v_matched
  from public.prospect_index pi
  where pi.id like 'keyword-person-%'
    and public.prospect_index_matches_v1(pi, '', p_filters);
  if v_compiled is distinct from v_matched then
    raise exception '% full-ID mismatch: compiler %, matcher %', p_label, v_compiled, v_matched;
  end if;
end $$;

do $parity$
declare
  v_scopes jsonb;
  v_operator text;
  v_filters jsonb;
  v_sql text;
  v_expected text[];
  v_page text[];
  v_full_page text[];
  v_export text[];
  v_frozen text[];
  v_rows jsonb;
  v_total bigint;
  v_set uuid;
  v_values jsonb;
begin
  -- Every non-empty subset of the three scopes, both polarities. This includes
  -- keywords-only, which intentionally stays on the pre-existing overlap path.
  foreach v_scopes in array array[
    '["name"]'::jsonb, '["keywords"]'::jsonb, '["description"]'::jsonb,
    '["name","keywords"]'::jsonb, '["name","description"]'::jsonb,
    '["keywords","description"]'::jsonb,
    '["name","keywords","description"]'::jsonb
  ] loop
    foreach v_operator in array array['contains', 'not_contains'] loop
      v_filters := jsonb_build_array(jsonb_build_object(
        'field', '__company_keywords', 'operator', v_operator,
        'values', jsonb_build_array('blockchain'), 'scopes', v_scopes));
      perform pg_temp.assert_keyword_parity(v_operator || ' ' || v_scopes::text, v_filters);
    end loop;
  end loop;

  -- Case, duplicate values, null/companyless rows, and reserved syntax all use
  -- exact full-ID comparison. Reserved terms must remain on the compatibility
  -- expression because %, _, backslash and | carry ILIKE/separator semantics.
  foreach v_filters in array array[
    '[{"field":"__company_keywords","operator":"contains","values":["BLOCKCHAIN","blockchain"],"scopes":["name","keywords","description"]}]'::jsonb,
    '[{"field":"__company_keywords","operator":"contains","values":["blockchain","missingordinary"],"scopes":["name","keywords","description"]}]'::jsonb,
    '[{"field":"__company_keywords","operator":"not_contains","values":["missing"],"scopes":["name","keywords","description"]}]'::jsonb,
    '[{"field":"__company_keywords","operator":"not_contains","values":["blockchain"],"scopes":["name","keywords","description"]}]'::jsonb
  ] loop
    perform pg_temp.assert_keyword_parity('ordinary edge ' || v_filters::text, v_filters);
  end loop;

  select jsonb_agg(value order by ordinal) into v_values
  from (
    select 0 as ordinal, 'blockchain'::text as value
    union all
    select n, 'missingordinary' || n from generate_series(1, 40) n
  ) terms;
  v_filters := jsonb_build_array(jsonb_build_object(
    'field','__company_keywords','operator','contains','values',v_values,
    'scopes',jsonb_build_array('name','keywords','description')));
  perform pg_temp.assert_keyword_parity('41-term compatibility path', v_filters);
  if position('exists (select 1 from unnest' in public.prospect_filter_sql_v1('', v_filters)) = 0 then
    raise exception '41-term company-keyword search escaped the compatibility path';
  end if;
  foreach v_filters in array array[
    '[{"field":"__company_keywords","operator":"contains","values":["100%"],"scopes":["name","description"]}]'::jsonb,
    '[{"field":"__company_keywords","operator":"contains","values":["under_score"],"scopes":["description"]}]'::jsonb,
    '[{"field":"__company_keywords","operator":"contains","values":["back\\\\slash"],"scopes":["description"]}]'::jsonb,
    '[{"field":"__company_keywords","operator":"contains","values":["pipe|blockchain"],"scopes":["name","keywords"]}]'::jsonb,
    '[{"field":"__company_keywords","operator":"contains","values":["ab"],"scopes":["name","keywords"]}]'::jsonb
  ] loop
    perform pg_temp.assert_keyword_parity('edge ' || v_filters::text, v_filters);
    v_sql := public.prospect_filter_sql_v1('', v_filters);
    if position('concat_ws' in v_sql) = 0 then
      raise exception 'reserved/short term did not use compatibility path: %', v_sql;
    end if;
  end loop;

  -- The optimized predicate composes with actual People scope filters: client,
  -- list, SEG policy and completeness. A discarded SEG row and incomplete row
  -- exercise the negative side of those constraints.
  v_filters := jsonb_build_array(
    jsonb_build_object('field','__client_ids','operator','contains','values',jsonb_build_array('keyword-index-client')),
    jsonb_build_object('field','__list_ids','operator','contains','values',jsonb_build_array('keyword-index-list')),
    jsonb_build_object('field','__client_seg_policy','operator','equals','values',jsonb_build_array('keyword-index-client')),
    jsonb_build_object('field','__incomplete_company_profile','operator','equals','values',jsonb_build_array('false')),
    jsonb_build_object('field','__company_keywords','operator','contains','values',jsonb_build_array('blockchain'),
      'scopes',jsonb_build_array('name','keywords','description'))
  );
  perform pg_temp.assert_keyword_parity('mixed client/list/SEG/completeness', v_filters);

  -- The actual interactive listing, exact capped count, export and durable
  -- result-set builder all consume the same filter compiler. Compare complete
  -- ordered ID sets, not merely totals.
  execute format(
    'select coalesce(array_agg(pi.id order by pi.id), array[]::text[]) from public.prospect_index pi where pi.id like %L and (%s)',
    'keyword-person-%', public.prospect_filter_sql_v1('', v_filters)) into v_expected;
  if v_expected is distinct from array[
    'keyword-person-description', 'keyword-person-name', 'keyword-person-tag'
  ]::text[] then
    raise exception 'mixed positive control returned unexpected IDs: %', v_expected;
  end if;
  select result_rows, total_count into v_rows, v_total
  from public.search_prospect_workspace_v13(
    '', v_filters, 'created_at', 'desc', 2, 0,
    'keyword-index-client', null, true, null);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_page from jsonb_array_elements(v_rows);
  if v_total is distinct from cardinality(v_expected) or cardinality(v_page) <> least(2, cardinality(v_expected)) then
    raise exception 'workspace exact/capped result mismatch: total %, page %, expected %', v_total, v_page, v_expected;
  end if;
  select result_rows, total_count into v_rows, v_total
  from public.search_prospect_workspace_v13(
    '', v_filters, 'created_at', 'desc', 100, 0,
    'keyword-index-client', null, true, null);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_full_page from jsonb_array_elements(v_rows);
  if v_total is distinct from cardinality(v_expected) or v_full_page is distinct from v_expected then
    raise exception 'workspace full-ID mismatch: total %, page %, expected %', v_total, v_full_page, v_expected;
  end if;

  select result_rows, total_count into v_rows, v_total
  from public.search_prospect_export_v6(
    '', v_filters, 'keyword-index-client', null, null, null, 50, true, array['id']);
  select coalesce(array_agg(value->>'id' order by value->>'id'), array[]::text[])
    into v_export from jsonb_array_elements(v_rows);
  if v_total is distinct from cardinality(v_expected) or v_export is distinct from v_expected then
    raise exception 'export full-ID mismatch: total %, export %, expected %', v_total, v_export, v_expected;
  end if;

  select set_id into v_set from public.request_result_set_v1(
    'keyword-index-owner', 'prospect', 'keyword-index-client', '', v_filters,
    md5('keyword index parity'), null, '{}'::jsonb);
  perform * from prospect_results.build_batch_v1(v_set, 1000);
  select coalesce(array_agg(entity_id order by entity_id), array[]::text[])
    into v_frozen from prospect_results.result_set_items where result_set_id = v_set;
  if v_frozen is distinct from v_expected then
    raise exception 'frozen full-ID mismatch: frozen %, expected %', v_frozen, v_expected;
  end if;

  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_keywords","operator":"not_contains","values":["blockchain"],"scopes":["name","keywords","description"]}]'::jsonb);
  if position('not exists' in v_sql) = 0 or position('co.name ilike' in v_sql) = 0
     or position('co.short_description ilike' in v_sql) = 0 or position('co.keywords &&' in v_sql) = 0
     or position('concat_ws' in v_sql) > 0 then
    raise exception 'ordinary negative filter did not retain indexed NOT EXISTS shape: %', v_sql;
  end if;
end
$parity$;
