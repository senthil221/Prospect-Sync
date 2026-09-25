-- Incomplete Info -> People used to ask the database the same question twice:
-- first materialize up to 250,000 globally matching companies, then apply two
-- correlated company-profile predicates to the already-scoped people. Apart
-- from doing duplicate work, the saved uncached scope function predates client
-- scoping and ignores p_client_id. The normal People candidate path already
-- owns client authorization, count, export and frozen-selection semantics, so
-- make "has a linked company whose keywords and description are both blank" a
-- single internal filter in that path.
--
-- No customer row is rewritten and no public permission is widened. Existing
-- saved filters remain valid. Roll forward by fixing this internal predicate;
-- rollback is the previous function definitions retained in migration history.

begin;

-- Compile the internal filter to one company lookup. It deliberately requires
-- a linked company: a person with no company was never in the old company
-- scope and must not become "incomplete company information" now.
do $patch$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_marker constant text := $m$    if field_key in ('__company_industry', '__company_keywords', '__company_description',
                     '__company_technologies', '__company_founded_year', '__company_total_funding') then$m$;
  v_replacement constant text := $r$    if field_key = '__incomplete_company_profile' then
      conjuncts := array_append(conjuncts, 'exists (select 1 from public.companies co'
        || ' where co.id = pi.company_id'
        || ' and btrim(coalesce(array_to_string(co.keywords, '' | ''), '''')) = '''''
        || ' and btrim(coalesce(co.short_description, '''')) = '''')');
      continue;
    end if;

    if field_key in ('__company_industry', '__company_keywords', '__company_description',
                     '__company_technologies', '__company_founded_year', '__company_total_funding') then$r$;
begin
  if position(v_marker in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer contains the company-profile branch expected by this migration';
  end if;
  if position(v_marker in substring(v_def from position(v_marker in v_def) + length(v_marker))) > 0 then
    raise exception 'prospect_filter_sql_v1 contains the company-profile anchor more than once';
  end if;
  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- First-page company-profile counts are intentionally bounded at 50,000 by
-- prospect_filters_need_company_lookup_v1. Classify the new internal spelling
-- the same way as the two public company filters it replaces; otherwise the
-- broadest client would ask for an exact count on every cold cache.
do $patch$
declare
  v_def text := pg_get_functiondef('public.prospect_filters_need_company_lookup_v1(jsonb)'::regprocedure);
  v_marker constant text :=
    '      ''__company_technologies'', ''__company_founded_year'', ''__company_total_funding'')';
  v_replacement constant text :=
    '      ''__company_technologies'', ''__company_founded_year'', ''__company_total_funding'',' || chr(10)
      || '      ''__incomplete_company_profile'')';
begin
  if position(v_marker in v_def) = 0 then
    raise exception 'prospect_filters_need_company_lookup_v1 no longer contains its company-field anchor';
  end if;
  execute replace(v_def, v_marker, v_replacement);
  if not public.prospect_filters_need_company_lookup_v1(
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb) then
    raise exception 'the incomplete-company predicate was not classified for a bounded first-page count';
  end if;
end;
$patch$;

-- Durable result sets and a few maintenance paths use the row matcher. Keep it
-- exactly equivalent to the compiled predicate so a grid, export and all-pages
-- bulk action can never resolve different records.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  v_marker constant text :=
    '        when ''__company_industry'' then (select co.industry from public.companies co where co.id = (p_row).company_id)';
  v_replacement constant text := $r$        when '__incomplete_company_profile' then case when exists (
          select 1 from public.companies co
          where co.id = (p_row).company_id
            and btrim(coalesce(array_to_string(co.keywords, ' | '), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''
        ) then 'true' else '' end
        when '__company_industry' then (select co.industry from public.companies co where co.id = (p_row).company_id)$r$;
begin
  if position(v_marker in v_def) = 0 then
    raise exception 'prospect_index_matches_v1 no longer contains the company-profile candidate anchor';
  end if;
  if position(v_marker in substring(v_def from position(v_marker in v_def) + length(v_marker))) > 0 then
    raise exception 'prospect_index_matches_v1 contains the company-profile candidate anchor more than once';
  end if;
  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- A cached People count that reads companies must be invalidated by company
-- enrichment. Previously only companyScope added the company version. Once the
-- redundant scope is gone, explicitly include it for this internal predicate.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'::regprocedure);
  v_declaration constant text :=
    '  v_has_people boolean := (btrim(v_search) <> '''' or v_filters <> ''[]''::jsonb);';
  v_declaration_replacement constant text := $r$  v_has_people boolean := (btrim(v_search) <> '' or v_filters <> '[]'::jsonb);
  v_has_company_filter boolean := exists (
    select 1 from jsonb_array_elements(v_filters) item
    where item->>'field' = '__incomplete_company_profile'
  );$r$;
  v_versions constant text := $m$  v_versions := public.data_versions_v1(
    case when v_has_scope then array['prospect', 'company'] else array['prospect'] end);$m$;
  v_versions_replacement constant text := $r$  v_versions := public.data_versions_v1(
    case when v_has_scope or v_has_company_filter
      then array['prospect', 'company'] else array['prospect'] end);$r$;
begin
  if position(v_declaration in v_def) = 0 or position(v_versions in v_def) = 0 then
    raise exception 'search_prospect_workspace_v12 dependency-vector anchors changed';
  end if;
  execute replace(replace(v_def, v_declaration, v_declaration_replacement),
    v_versions, v_versions_replacement);
end;
$patch$;

-- v13 normally delegates to v12. Its max-people-per-company branch has its own
-- version calculation, so keep the same dependency if both filters are ever
-- combined by an export or saved view.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'public.search_prospect_workspace_v13(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'::regprocedure);
  v_declaration constant text := '  v_has_scope boolean;';
  v_declaration_replacement constant text := $r$  v_has_scope boolean;
  v_has_company_filter boolean := exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__incomplete_company_profile'
  );$r$;
  v_versions constant text := $m$  v_versions := public.data_versions_v1(
    case when v_has_scope then array['prospect', 'company'] else array['prospect'] end);$m$;
  v_versions_replacement constant text := $r$  v_versions := public.data_versions_v1(
    case when v_has_scope or v_has_company_filter
      then array['prospect', 'company'] else array['prospect'] end);$r$;
begin
  if position(v_declaration in v_def) = 0 or position(v_versions in v_def) = 0 then
    raise exception 'search_prospect_workspace_v13 dependency-vector anchors changed';
  end if;
  execute replace(replace(v_def, v_declaration, v_declaration_replacement),
    v_versions, v_versions_replacement);
end;
$patch$;

-- Prove the invariant on representative live rows without scanning the whole
-- database twice. The sample includes no-company rows, incomplete companies and
-- complete companies when each exists.
do $assert$
declare
  v_filter constant jsonb :=
    '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb;
  v_sql text := public.prospect_filter_sql_v1('', v_filter);
  v_ids text[];
  v_compiled bigint;
  v_matched bigint;
  v_expected bigint;
  v_companyless boolean;
  v_versions jsonb;
begin
  if v_sql not like '%exists (select 1 from public.companies co%'
    or v_sql not like '%array_to_string(co.keywords%'
    or v_sql not like '%co.short_description%'
    or v_sql like '%company_scope_ids%' then
    raise exception 'incomplete-company predicate did not compile to the intended single linked-company lookup: %', v_sql;
  end if;

  select array_agg(id) into v_ids from (
    (select pi.id from public.prospect_index pi where pi.company_id is null order by pi.id limit 500)
    union
    (select pi.id from public.prospect_index pi join public.companies co on co.id = pi.company_id
      where btrim(coalesce(array_to_string(co.keywords, ' | '), '')) = ''
        and btrim(coalesce(co.short_description, '')) = '' order by pi.id limit 2500)
    union
    (select pi.id from public.prospect_index pi join public.companies co on co.id = pi.company_id
      where btrim(coalesce(array_to_string(co.keywords, ' | '), '')) <> ''
         or btrim(coalesce(co.short_description, '')) <> '' order by pi.id limit 2500)
  ) sampled;

  if coalesce(cardinality(v_ids), 0) > 0 then
    execute format('select count(*) from public.prospect_index pi where pi.id = any(%L::text[]) and (%s)',
      v_ids, v_sql) into v_compiled;
    select count(*) into v_matched from public.prospect_index pi
      where pi.id = any(v_ids) and public.prospect_index_matches_v1(pi, '', v_filter);
    select count(*) into v_expected from public.prospect_index pi
      join public.companies co on co.id = pi.company_id
      where pi.id = any(v_ids)
        and btrim(coalesce(array_to_string(co.keywords, ' | '), '')) = ''
        and btrim(coalesce(co.short_description, '')) = '';
    if v_compiled <> v_matched or v_compiled <> v_expected then
      raise exception 'incomplete-company selection disagrees: compiled %, row matcher %, direct linked-company %',
        v_compiled, v_matched, v_expected;
    end if;
  end if;

  select public.prospect_index_matches_v1(pi, '', v_filter) into v_companyless
  from public.prospect_index pi where pi.company_id is null limit 1;
  if found and v_companyless then
    raise exception 'a person without a linked company was classified as an incomplete company';
  end if;

  select data_versions into v_versions
  from public.search_prospect_workspace_v12('', v_filter, 'created_at', 'desc', 1, 0,
    null, '{}'::jsonb, false, public.data_versions_v1(array['prospect', 'company']));
  if not (coalesce(v_versions, '{}'::jsonb) ? 'prospect')
    or not (coalesce(v_versions, '{}'::jsonb) ? 'company') then
    raise exception 'incomplete-company People results do not depend on both prospect and company versions: %', v_versions;
  end if;
end;
$assert$;

-- CREATE OR REPLACE must retain the least-privilege boundary and pinned
-- execution settings of every function it touched.
do $assert$
declare
  v_name text;
  v_cfg text[];
begin
  foreach v_name in array array[
    'prospect_filter_sql_v1', 'prospect_index_matches_v1',
    'search_prospect_workspace_v12', 'search_prospect_workspace_v13'
  ] loop
    select p.proconfig into v_cfg from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_name;
    if v_cfg is null or not exists (select 1 from unnest(v_cfg) setting where setting like 'search_path=%') then
      raise exception '% lost its pinned search_path', v_name;
    end if;
    if has_function_privilege('anon', format('public.%s', v_name), 'EXECUTE')
      or has_function_privilege('authenticated', format('public.%s', v_name), 'EXECUTE') then
      raise exception '% became executable by a browser role', v_name;
    end if;
  end loop;
end;
$assert$;

commit;
