-- Partition every client workspace by company-profile completeness.
--
-- Incomplete means BOTH keywords and short_description are blank. The client
-- People/Company databases show the complement; Incomplete Info shows exactly
-- those companies and their linked people. Membership rows are deliberately
-- unchanged, so enriching either field promotes the company and linked people
-- automatically. Master workspaces do not carry this internal predicate and
-- therefore remain unchanged.

-- The People compiler previously treated every spelling of the internal filter
-- as "true". Make equals false the exact complement, and reject ambiguous
-- shapes instead of silently broadening a client query.
do $patch$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_old constant text := $old$    if field_key = '__incomplete_company_profile' then
      conjuncts := array_append(conjuncts, 'exists (select 1 from public.companies co'
        || ' where co.id = pi.company_id'
        || ' and btrim(coalesce(array_to_string(co.keywords, '' | ''), '''')) = '''''
        || ' and btrim(coalesce(co.short_description, '''')) = '''')');
      continue;
    end if;$old$;
  v_new constant text := $new$    if field_key = '__incomplete_company_profile' then
      if operator_key not in ('equals', 'not_equals')
        or cardinality(raw_values) <> 1
        or lower(raw_values[1]) not in ('true', 'false') then
        raise exception '__incomplete_company_profile requires equals/not_equals and one true/false value'
          using errcode = '22023';
      end if;
      value_text := lower(raw_values[1]);
      if operator_key = 'not_equals' then
        value_text := case value_text when 'true' then 'false' else 'true' end;
      end if;
      conjuncts := array_append(conjuncts,
        case when value_text = 'true' then '' else 'not ' end
        || '(exists (select 1 from public.companies co'
        || ' where co.id = pi.company_id'
        || ' and btrim(coalesce(public.tag_array_text_v1(co.keywords), '''')) = '''''
        || ' and btrim(coalesce(co.short_description, '''')) = ''''))');
      continue;
    end if;$new$;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 incomplete-profile branch changed';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$patch$;

-- Durable result sets and fallback bulk paths use the row matcher. Returning a
-- real Boolean word gives equals false the same complement semantics as the
-- compiled predicate above.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  v_old constant text := $old$        when '__incomplete_company_profile' then case when exists (
          select 1 from public.companies co
          where co.id = (p_row).company_id
            and btrim(coalesce(array_to_string(co.keywords, ' | '), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''
        ) then 'true' else '' end
        when '__company_industry'$old$;
  v_new constant text := $new$        when '__incomplete_company_profile' then case when exists (
          select 1 from public.companies co
          where co.id = (p_row).company_id
            and btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''
        ) then 'true' else 'false' end
        when '__company_industry'$new$;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_index_matches_v1 incomplete-profile branch changed';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$patch$;

-- Company reads share this compiler across listing, pivots, streamed exports,
-- durable result sets and all-matching actions. Strip the internal field before
-- the public filter compiler sees it, then append one indexed profile predicate.
create or replace function public.company_effective_filter_sql_v1(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $function$
declare
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_clean jsonb;
  v_import_count integer;
  v_import_id text;
  v_profile_count integer;
  v_profile_operator text;
  v_profile_value text;
  v_profile_incomplete boolean;
  v_prefilter text;
  v_complete text;
  v_base text;
  v_profile_predicate text := '(btrim(coalesce(public.tag_array_text_v1(c.keywords), '''')) = '''''
    || ' and btrim(coalesce(c.short_description, '''')) = '''')';
begin
  select count(*), min(item->'values'->>0) into v_import_count, v_import_id
  from jsonb_array_elements(v_filters) item
  where item->>'field' = '__company_import_id';
  if v_import_count > 1 or (v_import_count = 1 and coalesce(btrim(v_import_id), '') = '') then
    raise exception 'Choose one company import.' using errcode = '22023';
  end if;

  select count(*), min(item->>'operator'), min(lower(item->'values'->>0))
    into v_profile_count, v_profile_operator, v_profile_value
  from jsonb_array_elements(v_filters) item
  where item->>'field' = '__incomplete_company_profile';
  if v_profile_count > 1
    or (v_profile_count = 1 and (
      not exists (
        select 1 from jsonb_array_elements(v_filters) item
        where item->>'field' = '__incomplete_company_profile'
          and case when jsonb_typeof(item->'values') = 'array'
            then jsonb_array_length(item->'values') = 1 else false end
      )
      or
      v_profile_operator not in ('equals', 'not_equals')
      or v_profile_value not in ('true', 'false')
    )) then
    raise exception '__incomplete_company_profile requires equals/not_equals and one true/false value'
      using errcode = '22023';
  end if;
  if v_profile_count = 1 then
    v_profile_incomplete := (v_profile_value = 'true') = (v_profile_operator = 'equals');
  end if;

  select coalesce(jsonb_agg(item order by ordinal), '[]'::jsonb) into v_clean
  from jsonb_array_elements(v_filters) with ordinality entries(item, ordinal)
  where item->>'field' not in ('__company_import_id', '__incomplete_company_profile');

  v_prefilter := public.company_prefilter_sql(p_search, v_clean);
  v_complete := public.company_filter_sql_v3(p_search, v_clean, false);
  if v_complete is null then return null; end if;
  v_base := case
    when v_prefilter <> 'true' and v_prefilter is distinct from v_complete
      then '(' || v_prefilter || ') and (' || v_complete || ')'
    else v_complete end;
  if v_import_count = 1 then
    v_base := '(' || v_base || ') and exists (select 1 from public.company_import_memberships cim'
      || ' where cim.company_id = c.id and cim.import_id = ' || quote_literal(v_import_id) || ')';
  end if;
  if v_profile_count = 1 then
    v_base := '(' || v_base || ') and '
      || case when v_profile_incomplete then '' else 'not ' end
      || v_profile_predicate;
  end if;
  return v_base;
end;
$function$;

-- The probe compiler does not know this private field. The complete compiler
-- above is already an indexed predicate, so the full-scan chooser must retain it
-- instead of sampling or substituting a probe built from an unknown field.
do $patch$
declare
  v_def text := pg_get_functiondef('public.company_full_scan_filter_sql_v1(text,jsonb)'::regprocedure);
  v_old constant text := '  if v_complete is null then return null; end if;';
  v_new constant text := $new$  if v_complete is null then return null; end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__incomplete_company_profile'
  ) then
    return v_complete;
  end if;$new$;
begin
  if position(v_old in v_def) = 0 then
    raise exception 'company_full_scan_filter_sql_v1 chooser anchor changed';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$patch$;

-- Directory/header counts describe the normal client databases, so use the
-- same partition there. Companyless people remain visible in the normal People
-- DB; only people linked to an incomplete company move to Incomplete Info.
create or replace view public.client_summaries as
with list_counts as (
  select list_row.client_id, count(*)::integer as list_count
  from public.lists list_row
  group by list_row.client_id
), people_counts as (
  -- One pass over client memberships for every client summary. The previous
  -- view ran three correlated membership counts per client; joining the company
  -- once keeps the new exact completeness rule bounded by membership volume.
  select membership.client_id,
    count(*) filter (
      where membership.status = 'active'
        and (prospect.company_id is null or not (
          btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
          and btrim(coalesce(company.short_description, '')) = ''
        ))
    )::integer as prospect_count,
    count(*) filter (
      where membership.status = 'active' and membership.icp_verified
        and (prospect.company_id is null or not (
          btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
          and btrim(coalesce(company.short_description, '')) = ''
        ))
    )::integer as icp_verified_count,
    count(*) filter (where membership.status = 'blocked')::integer as blocked_count
  from public.client_prospects membership
  join public.prospects prospect on prospect.id = membership.prospect_id
  left join public.companies company on company.id = prospect.company_id
  group by membership.client_id
), company_counts as (
  select membership.client_id, count(*)::integer as company_count
  from public.client_companies membership
  join public.companies company on company.id = membership.company_id
  where not (
    btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
    and btrim(coalesce(company.short_description, '')) = ''
  )
  group by membership.client_id
)
select client.id, client.name, client.created_at,
  coalesce(list_counts.list_count, 0)::integer as list_count,
  coalesce(people_counts.prospect_count, 0)::integer as prospect_count,
  coalesce(people_counts.icp_verified_count, 0)::integer as icp_verified_count,
  coalesce(people_counts.blocked_count, 0)::integer as blocked_count,
  coalesce(company_counts.company_count, 0)::integer as company_count,
  client.folder_id, client.archived_at
from public.clients client
left join list_counts on list_counts.client_id = client.id
left join people_counts on people_counts.client_id = client.id
left join company_counts on company_counts.client_id = client.id;
revoke all on public.client_summaries from public, anon, authenticated;
grant select on public.client_summaries to service_role;

-- A stale explicit selection must not mark an incomplete record ICP verified.
-- Clearing an existing mark remains allowed, so a company that later becomes
-- incomplete can still be cleaned up.
create or replace function public.set_icp_verified_v1(
  p_client_id text,
  p_verified boolean,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_prospect_ids text[] default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_ids text[];
  v_updated integer := 0;
  v_reindex record;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if p_verified then
    select coalesce(array_agg(prospect.id), array[]::text[]) into v_ids
    from public.prospects prospect
    left join public.companies company on company.id = prospect.company_id
    where prospect.id = any(coalesce(v_ids, array[]::text[]))
      and (prospect.company_id is null or not (
        btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
        and btrim(coalesce(company.short_description, '')) = ''
      ));
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  update public.client_prospects membership set
    icp_verified = p_verified,
    verified_at = case when p_verified then now() else null end,
    verified_by = case when p_verified then left(coalesce(p_actor, ''), 200) else '' end
  where membership.client_id = p_client_id
    and membership.prospect_id = any(v_ids)
    and membership.icp_verified is distinct from p_verified;
  get diagnostics v_updated = row_count;

  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);
  perform public.record_operation(
    case when p_verified then 'icp_verify' else 'icp_unverify' end,
    p_client_id, p_actor,
    format('Marked %s prospects %s', v_updated, case when p_verified then 'ICP verified' else 'not verified' end),
    v_updated, v_ids);
  return jsonb_build_object('updated', v_updated, 'queued', v_reindex.queued);
end;
$function$;

create or replace function public.set_company_icp_verified_v2(
  p_client_id text,
  p_verified boolean,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $function$
declare
  v_ids text[] := array[]::text[];
  v_updated integer := 0;
  v_existing jsonb := '{}'::jsonb;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(
    p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);

  if p_verified then
    select coalesce(array_agg(company.id), array[]::text[]) into v_ids
    from public.companies company
    where company.id = any(v_ids)
      and not (
        btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
        and btrim(coalesce(company.short_description, '')) = ''
      );
    insert into public.client_company_icp_validations (client_id, company_id, validated_at, validated_by)
    select p_client_id, company_id, now(), left(coalesce(p_actor, ''), 200)
    from unnest(v_ids) selected(company_id)
    on conflict (client_id, company_id) do nothing;
  else
    delete from public.client_company_icp_validations validation
    where validation.client_id = p_client_id and validation.company_id = any(v_ids);
  end if;
  get diagnostics v_updated = row_count;
  if cardinality(v_ids) > 0 then
    v_existing := public.set_company_icp_validated_v1(
      p_client_id, p_verified, v_ids, '', '[]'::jsonb, null, null, p_actor);
  end if;
  return v_existing || jsonb_build_object('updated', v_updated, 'selected', cardinality(v_ids));
end;
$function$;

revoke execute on function public.prospect_filter_sql_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.prospect_index_matches_v1(public.prospect_index, text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_effective_filter_sql_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.company_full_scan_filter_sql_v1(text, jsonb) from public, anon, authenticated;
revoke execute on function public.set_icp_verified_v1(text, boolean, text, jsonb, text[], text[], text) from public, anon, authenticated;
revoke execute on function public.set_company_icp_verified_v2(text, boolean, text[], text, jsonb, jsonb, text[], text) from public, anon, authenticated;
grant execute on function public.prospect_filter_sql_v1(text, jsonb) to service_role;
grant execute on function public.prospect_index_matches_v1(public.prospect_index, text, jsonb) to service_role;
grant execute on function public.company_effective_filter_sql_v1(text, jsonb) to service_role;
grant execute on function public.company_full_scan_filter_sql_v1(text, jsonb) to service_role;
grant execute on function public.set_icp_verified_v1(text, boolean, text, jsonb, text[], text[], text) to service_role;
grant execute on function public.set_company_icp_verified_v2(text, boolean, text[], text, jsonb, jsonb, text[], text) to service_role;

-- Compile-time contract: true/false are complements and both compilers retain
-- the indexed definition. Row-level disjoint/union and push/enrich behaviour are
-- exercised by the disposable fixture in supabase/tests.
do $assert$
declare
  v_true jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["true"]}]'::jsonb;
  v_false jsonb := '[{"field":"__incomplete_company_profile","operator":"equals","values":["false"]}]'::jsonb;
  v_people_true text := public.prospect_filter_sql_v1('', v_true);
  v_people_false text := public.prospect_filter_sql_v1('', v_false);
  v_company_true text := public.company_effective_filter_sql_v1('', v_true);
  v_company_false text := public.company_effective_filter_sql_v1('', v_false);
begin
  if v_people_true not like '%exists (select 1 from public.companies co%'
    or v_people_true like '%not (exists%'
    or v_people_false not like '%not (exists (select 1 from public.companies co%' then
    raise exception 'People completeness partition did not compile: true %, false %', v_people_true, v_people_false;
  end if;
  if v_company_true not like '%tag_array_text_v1(c.keywords)%'
    or v_company_true like '%not (btrim%'
    or v_company_false not like '%not (btrim%'
    or public.company_full_scan_filter_sql_v1('', v_false) is distinct from v_company_false then
    raise exception 'Company completeness partition did not compile: true %, false %', v_company_true, v_company_false;
  end if;
end;
$assert$;
