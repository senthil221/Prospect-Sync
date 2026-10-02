-- SEG emails per client, an ESP filter on companies, and MX scanning that runs
-- on its own.
--
-- 1. client_settings.seg_emails: 'keep' (default, today's behaviour) or
--    'discard'. A discarding client does not see people or companies whose
--    mail goes through a secure email gateway (email_provider_type = 'SEG':
--    Mimecast, Proofpoint, ...). Like Incomplete Info (20260929120000) it is a
--    partition of the client workspace, not a delete: memberships stay, so
--    switching back to keep shows them again, and a company whose MX is only
--    detected after it was brought in drops out the moment it is classified.
--
--    Every client-scoped read already carries an internal filter the app adds
--    (lib/client-workspace-completeness.ts). It now also carries
--    __client_seg_policy = [client id], which compiles to
--      not (email_provider_type = 'SEG' and <the client discards SEG>)
--    with the setting read when the query runs, as a one-row sub-select. So
--    the compiled SQL does not change when the setting does; the caches keyed
--    on it are moved on by the setting's trigger below instead.
--
--    The same rule is applied where the database picks a client's companies
--    without a filter: ICP checks over "ICP unverified" / "All companies" and
--    the Clients list counts.
--
-- 2. Companies can be filtered by ESP: __esp_type (provider name or provider
--    type, e.g. "Proofpoint" or "SEG"), __esp and __email_provider_type, the
--    same fields and semantics the People compiler has had since 20260902000280.
--
-- 3. claim_mx_scan_batch_v1 / apply_email_provider_scan_v2 let the ICP worker
--    scan MX records continuously. Until now a scan ran only while someone
--    held the "Detect ESPs" menu open: 221,103 of 449,328 companies (118,638
--    with a domain) had never been scanned, so an ESP filter silently missed
--    half the database. v2 also writes the ESP columns straight onto the
--    company's prospect_index rows instead of a full re-index per prospect.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- 1. The setting
alter table public.client_settings
  add column if not exists seg_emails text not null default 'keep';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'client_settings_seg_emails_check') then
    alter table public.client_settings
      add constraint client_settings_seg_emails_check check (seg_emails in ('keep', 'discard'));
  end if;
end $$;

comment on column public.client_settings.seg_emails is
  'keep | discard: whether this client''s workspace shows people and companies whose email goes through a secure email gateway (companies.email_provider_type = ''SEG'').';

-- Flipping the setting changes what every cached People/Company count and the
-- Clients list mean for this client, without changing their filters.
create or replace function public.client_settings_seg_changed_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' and new.seg_emails = 'keep' then return null; end if;
  if tg_op = 'UPDATE' and new.seg_emails is not distinct from old.seg_emails then return null; end if;
  perform nextval('public.data_version_prospect');
  perform nextval('public.data_version_company');
  perform nextval('public.data_version_client_counts');
  return null;
end;
$$;

revoke execute on function public.client_settings_seg_changed_v1() from public, anon, authenticated;

drop trigger if exists trg_client_settings_seg_changed on public.client_settings;
create trigger trg_client_settings_seg_changed
  after insert or update of seg_emails on public.client_settings
  for each row execute function public.client_settings_seg_changed_v1();

-- ---------------------------------------------------------------------------
-- 2. The filter compilers. Spliced the way Date Contacted and the ICP check
-- filter were: read the deployed body, replace an anchor that occurs exactly
-- once, raise if it is missing.
do $patch$
declare
  v_definition text;
  v_rewritten text;
  v_anchor text;
begin
  -- People, compiled SQL.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if position('__client_seg_policy' in v_definition) = 0 then
    v_anchor := $old$    if field_key in ('__lead', '__contactable') then$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1: Lead/Contactable anchor is not unique';
    end if;
    v_rewritten := replace(v_definition, v_anchor,
      $new$    -- The client's SEG emails setting, read when the query runs (20261003100000).
    if field_key = '__client_seg_policy' then
      if cardinality(raw_values) < 1 then continue; end if;
      conjuncts := conjuncts || format($seg$(not (pi.email_provider_type = 'SEG' and (select coalesce(bool_or(s.seg_emails = 'discard'), false) from public.client_settings s where s.client_id = %L)))$seg$, raw_values[1]);
      continue;
    end if;

    if field_key in ('__lead', '__contactable') then$new$);
    execute v_rewritten;
  end if;

  -- People, row matcher.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  if position('__client_seg_policy' in v_definition) = 0 then
    v_anchor := $old$      when filter_item->>'field' = '__lead' then ($old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_index_matches_v1: Lead anchor is not unique';
    end if;
    v_rewritten := replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__client_seg_policy' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or not ((p_row).email_provider_type = 'SEG'
                and coalesce((select bool_or(s.seg_emails = 'discard') from public.client_settings s
                               where s.client_id = filter_item->'values'->>0), false))
      )
      when filter_item->>'field' = '__lead' then ($new$);
    execute v_rewritten;
  end if;

  -- Companies, compiled SQL: the SEG policy and the three ESP fields.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  if position('__client_seg_policy' in v_definition) = 0 then
    v_anchor := $old$      if field_key = '__company_tags' then$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_filter_sql_v3: company tags anchor is not unique';
    end if;
    v_rewritten := replace(v_definition, v_anchor,
      $new$      -- The client's SEG emails setting, read when the query runs (20261003100000).
      if field_key = '__client_seg_policy' then
        if cardinality(raw_values) = 0 then continue; end if;
        conjuncts := conjuncts || format($seg$(not (c.email_provider_type = 'SEG' and (select coalesce(bool_or(s.seg_emails = 'discard'), false) from public.client_settings s where s.client_id = %L)))$seg$, raw_values[1]);
        continue;
      end if;
      -- ESP. Equality tests the provider name and the provider type, so
      -- "Proofpoint" and "SEG" both work; contains matches either as a substring.
      if field_key in ('__esp_type', '__esp', '__email_provider_type') then
        if cardinality(raw_values) = 0 then continue; end if;
        match_cols := case field_key
          when '__esp' then array['c.esp']
          when '__email_provider_type' then array['c.email_provider_type']
          else array['c.esp', 'c.email_provider_type'] end;
        if operator_key in ('equals', 'not_equals') then
          lowered := array(select lower(value) from unnest(raw_values) value);
          value_parts := array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
        else
          value_parts := array(select format('%s ilike %L', col, '%' || value || '%')
                                 from unnest(match_cols) col cross join unnest(raw_values) value);
        end if;
        conjuncts := conjuncts || format('(%s(%s))',
          case when operator_key in ('not_equals', 'not_contains') then 'not ' else '' end,
          array_to_string(value_parts, ' or '));
        continue;
      end if;
      if field_key = '__company_tags' then$new$);
    execute v_rewritten;
  end if;

  -- Companies, row matcher.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  if position('__client_seg_policy' in v_definition) = 0 then
    v_anchor := $old$      when filter_item->>'field' = '__company_tags' then ($old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'company_matches_filters_v1: company tags anchor is not unique';
    end if;
    v_rewritten := replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__client_seg_policy' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or not ((p_row).email_provider_type = 'SEG'
                and coalesce((select bool_or(s.seg_emails = 'discard') from public.client_settings s
                               where s.client_id = filter_item->'values'->>0), false))
      )
      when filter_item->>'field' in ('__esp_type', '__esp', '__email_provider_type') then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from jsonb_array_elements_text(filter_item->'values') selected(value)
                  where case when coalesce(filter_item->>'operator', 'contains') in ('equals', 'not_equals')
                    then (filter_item->>'field' <> '__email_provider_type' and lower((p_row).esp) = lower(selected.value))
                      or (filter_item->>'field' <> '__esp' and lower((p_row).email_provider_type) = lower(selected.value))
                    else (filter_item->>'field' <> '__email_provider_type' and (p_row).esp ilike '%' || selected.value || '%')
                      or (filter_item->>'field' <> '__esp' and (p_row).email_provider_type ilike '%' || selected.value || '%')
                    end)))
      )
      when filter_item->>'field' = '__company_tags' then ($new$);
    execute v_rewritten;
  end if;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 3. Where the database picks a client's companies without a filter.

-- The Clients list: visible counts are the totals minus Incomplete Info and,
-- for a discarding client, minus its complete SEG slice. Only discarding
-- clients pay the extra joins.
create or replace view public.client_summaries as
with incomplete_company_ids as materialized (
  select company.id
  from public.companies company
  where btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
    and btrim(coalesce(company.short_description, '')) = ''
), incomplete_prospect_ids as materialized (
  select prospect.id
  from incomplete_company_ids incomplete_company
  join public.prospects prospect on prospect.company_id = incomplete_company.id
), active_client_memberships as materialized (
  select membership.client_id, membership.prospect_id, membership.icp_verified
  from public.client_prospects membership
  where membership.status = 'active'
), incomplete_people_counts as (
  select membership.client_id,
    count(*)::integer as prospect_count,
    count(*) filter (where membership.icp_verified)::integer as icp_verified_count
  from active_client_memberships membership
  join incomplete_prospect_ids incomplete_prospect on incomplete_prospect.id = membership.prospect_id
  group by membership.client_id
), incomplete_company_counts as (
  select membership.client_id, count(*)::integer as company_count
  from incomplete_company_ids incomplete_company
  join public.client_companies membership on membership.company_id = incomplete_company.id
  group by membership.client_id
), seg_clients as materialized (
  select setting.client_id from public.client_settings setting where setting.seg_emails = 'discard'
), seg_company_ids as materialized (
  -- Complete profiles only: incomplete ones are already subtracted above.
  select company.id
  from public.companies company
  where company.email_provider_type = 'SEG'
    and exists (select 1 from seg_clients)
    and not (btrim(coalesce(public.tag_array_text_v1(company.keywords), '')) = ''
             and btrim(coalesce(company.short_description, '')) = '')
), seg_people_counts as (
  select membership.client_id,
    count(*)::integer as prospect_count,
    count(*) filter (where membership.icp_verified)::integer as icp_verified_count
  from seg_clients seg_client
  join active_client_memberships membership on membership.client_id = seg_client.client_id
  join public.prospects prospect on prospect.id = membership.prospect_id
  join seg_company_ids seg_company on seg_company.id = prospect.company_id
  group by membership.client_id
), seg_company_counts as (
  select membership.client_id, count(*)::integer as company_count
  from seg_clients seg_client
  join public.client_companies membership on membership.client_id = seg_client.client_id
  join seg_company_ids seg_company on seg_company.id = membership.company_id
  group by membership.client_id
)
select client.id, client.name, client.created_at,
  (select count(*)::integer from public.lists list_row where list_row.client_id = client.id) as list_count,
  (select count(*)::integer from public.client_prospects membership
    where membership.client_id = client.id and membership.status = 'active')
    - coalesce(incomplete_people_counts.prospect_count, 0)
    - coalesce(seg_people_counts.prospect_count, 0) as prospect_count,
  (select count(*)::integer from public.client_prospects membership
    where membership.client_id = client.id and membership.status = 'active' and membership.icp_verified)
    - coalesce(incomplete_people_counts.icp_verified_count, 0)
    - coalesce(seg_people_counts.icp_verified_count, 0) as icp_verified_count,
  (select count(*)::integer from public.client_prospects membership
    where membership.client_id = client.id and membership.status = 'blocked') as blocked_count,
  (select count(*)::integer from public.client_companies membership where membership.client_id = client.id)
    - coalesce(incomplete_company_counts.company_count, 0)
    - coalesce(seg_company_counts.company_count, 0) as company_count,
  client.folder_id,
  client.archived_at
from public.clients client
left join incomplete_people_counts on incomplete_people_counts.client_id = client.id
left join incomplete_company_counts on incomplete_company_counts.client_id = client.id
left join seg_people_counts on seg_people_counts.client_id = client.id
left join seg_company_counts on seg_company_counts.client_id = client.id;

revoke all on public.client_summaries from public, anon, authenticated;
grant select on public.client_summaries to service_role;

-- ICP checks over "ICP unverified" / "All companies" / a pasted list: a
-- discarding client's SEG companies are not checked (and not paid for).
do $patch$
declare
  v_definition text;
  v_anchor text;
begin
  select pg_get_functiondef('public.start_icp_strategy_check_v2(text,text,text,text,text[],text,jsonb,jsonb,text[],boolean,text,text)'::regprocedure)
    into v_definition;
  if position('client_settings' in v_definition) = 0 then
    v_anchor := E'     where public.company_has_icp_text_v1(c.keywords, c.short_description)\n     group by ids.company_id';
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'start_icp_strategy_check_v2: checkable anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      E'     where public.company_has_icp_text_v1(c.keywords, c.short_description)\n'
      || E'       and not (c.email_provider_type = ''SEG'' and exists (select 1 from public.client_settings s\n'
      || E'                 where s.client_id = p_client_id and s.seg_emails = ''discard''))\n'
      || E'     group by ids.company_id');
  end if;

  select pg_get_functiondef('public.icp_strategy_scope_counts_v2(text,text)'::regprocedure) into v_definition;
  if position('client_settings' in v_definition) = 0 then
    v_anchor := E'           and public.company_has_icp_text_v1(c.keywords, c.short_description)) x);';
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'icp_strategy_scope_counts_v2: anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      E'           and public.company_has_icp_text_v1(c.keywords, c.short_description)\n'
      || E'           and not (c.email_provider_type = ''SEG'' and exists (select 1 from public.client_settings s\n'
      || E'                     where s.client_id = p_client_id and s.seg_emails = ''discard''))) x);');
  end if;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 4. Continuous MX scanning (worker/icp-worker.mjs, mxScanLoop).

-- The next companies with a domain that were never scanned, in id order:
-- idx_companies_pending_mx_scan is exactly this predicate.
create or replace function public.claim_mx_scan_batch_v1(p_limit integer default 100)
returns table (id text, domain text)
language sql
stable
security definer
set search_path = public
set statement_timeout = '10s'
as $$
  select c.id, c.normalized_domain
    from public.companies c
   where c.normalized_domain <> '' and c.mx_checked_at is null
   order by c.id
   limit greatest(1, least(coalesce(p_limit, 100), 500))
$$;

-- One scan batch: the companies in one UPDATE, then their people's ESP columns
-- on prospect_index in another. The ESP columns are all prospect_index needs
-- from a scan, so this skips the full re-index (about 20ms a prospect) that
-- the dashboard's scan route used to run for every person at every company.
-- search_text still carries the ESP words from the last full re-index; filters
-- read the columns.
create or replace function public.apply_email_provider_scan_v2(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_ids text[];
  v_seg_changed boolean;
  v_people integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('updated', 0, 'people', 0);
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception using errcode = '22023', message = 'At most 500 companies per scan batch.';
  end if;

  select exists (
    select 1
      from jsonb_to_recordset(p_rows) as s(id text, email_provider_type text)
      join public.companies c on c.id = s.id
     where (c.email_provider_type = 'SEG') <> (s.email_provider_type = 'SEG'))
    into v_seg_changed;

  with scanned as (
    select * from jsonb_to_recordset(p_rows) as s(
      id text, esp text, email_provider_type text, mx_records text[], mx_status text, mx_checked_at timestamptz)
  ), updated as (
    update public.companies c
       set esp = coalesce(s.esp, ''),
           email_provider_type = s.email_provider_type,
           mx_records = coalesce(s.mx_records, array[]::text[]),
           mx_status = s.mx_status,
           mx_checked_at = coalesce(s.mx_checked_at, now())
      from scanned s
     where c.id = s.id
    returning c.id
  )
  select coalesce(array_agg(id), array[]::text[]) into v_ids from updated;

  if cardinality(v_ids) > 0 then
    update public.prospect_index pi
       set esp = c.esp,
           email_provider_type = c.email_provider_type,
           mx_records = c.mx_records,
           mx_status = c.mx_status,
           mx_checked_at = c.mx_checked_at
      from public.companies c
     where c.id = any(v_ids)
       and pi.company_id = c.id
       and (pi.esp, pi.email_provider_type, pi.mx_records, pi.mx_status, pi.mx_checked_at)
           is distinct from (c.esp, c.email_provider_type, c.mx_records, c.mx_status, c.mx_checked_at);
    get diagnostics v_people = row_count;
  end if;

  -- A company entering or leaving SEG changes a discarding client's counts.
  if v_seg_changed then
    perform nextval('public.data_version_client_counts');
  end if;

  return jsonb_build_object('updated', cardinality(v_ids), 'people', v_people);
end;
$$;

revoke execute on function public.claim_mx_scan_batch_v1(integer) from public, anon, authenticated;
revoke execute on function public.apply_email_provider_scan_v2(jsonb) from public, anon, authenticated;
grant execute on function public.claim_mx_scan_batch_v1(integer) to service_role;
grant execute on function public.apply_email_provider_scan_v2(jsonb) to service_role;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'prospect_icp_validator') then
    execute 'grant execute on function public.claim_mx_scan_batch_v1(integer) to prospect_icp_validator';
    execute 'grant execute on function public.apply_email_provider_scan_v2(jsonb) to prospect_icp_validator';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Proof, rolled back.
do $proof$
declare
  v_filters jsonb;
  v_client text;
  v_seg_company text;
  v_plain_company text;
  v_seg_person text;
  v_plain_person text;
  v_sql text;
  v_count integer;
  v_version bigint;
  v_esp jsonb := '[{"field":"__esp_type","operator":"equals","values":["SEG"]}]';
  v_esp_out jsonb := '[{"field":"__esp_type","operator":"not_equals","values":["Google Workspace","SEG"]}]';
  v_mismatch integer;
begin
  -- Every compiler knows the new fields.
  if public.prospect_filter_sql_v1('', '[{"field":"__client_seg_policy","operator":"equals","values":["x"]}]'::jsonb)
       not like '%pi.email_provider_type = ''SEG''%client_settings%'
    or public.company_filter_sql_v3('', '[{"field":"__client_seg_policy","operator":"equals","values":["x"]}]'::jsonb, false)
       not like '%c.email_provider_type = ''SEG''%client_settings%'
    or public.company_filter_sql_v3('', v_esp, false) not like '%lower(c.esp) = any%lower(c.email_provider_type) = any%'
    or public.company_full_scan_filter_sql_v1('', v_esp) is null
    or public.company_effective_filter_sql_v1('', v_esp_out) is null then
    raise exception 'SEG/ESP proof: a compiler did not learn the new fields';
  end if;

  -- The ESP filter: compiled SQL and the row matcher agree on 2,000 companies.
  foreach v_filters in array array[v_esp, v_esp_out] loop
    execute format($q$
      select count(*) from (select * from public.companies order by id limit 2000) c
       where (%s) is distinct from public.company_matches_filters_v1(c, '', %L::jsonb)$q$,
      public.company_filter_sql_v3('', v_filters, false), v_filters) into v_mismatch;
    if v_mismatch <> 0 then
      raise exception 'SEG/ESP proof: % companies disagree on %', v_mismatch, v_filters;
    end if;
  end loop;

  select c.id into v_seg_company from public.companies c where c.email_provider_type = 'SEG' limit 1;
  select c.id into v_plain_company from public.companies c where c.email_provider_type <> 'SEG' limit 1;
  select pi.id into v_seg_person from public.prospect_index pi where pi.email_provider_type = 'SEG' limit 1;
  select pi.id into v_plain_person from public.prospect_index pi where pi.email_provider_type <> 'SEG' limit 1;
  select id into v_client from public.clients order by created_at limit 1;
  if v_client is null or v_seg_company is null or v_plain_company is null or v_seg_person is null or v_plain_person is null then
    raise notice 'SEG/ESP proof: no data to check the policy against - compile checks only.';
    return;
  end if;
  v_filters := jsonb_build_array(jsonb_build_object(
    'field', '__client_seg_policy', 'operator', 'equals', 'values', jsonb_build_array(v_client)));

  begin
    -- discard: the SEG rows drop out, the others stay, in all four paths.
    insert into public.client_settings (client_id, seg_emails) values (v_client, 'discard')
      on conflict (client_id) do update set seg_emails = 'discard';

    execute format('select count(*) from public.companies c where c.id in (%L, %L) and (%s)',
      v_seg_company, v_plain_company, public.company_filter_sql_v3('', v_filters, false)) into v_count;
    if v_count <> 1
      or (select public.company_matches_filters_v1(c, '', v_filters) from public.companies c where c.id = v_seg_company)
      or not (select public.company_matches_filters_v1(c, '', v_filters) from public.companies c where c.id = v_plain_company) then
      raise exception 'SEG/ESP proof: discard did not hide exactly the SEG company';
    end if;
    execute format('select count(*) from public.prospect_index pi where pi.id in (%L, %L) and (%s)',
      v_seg_person, v_plain_person, public.prospect_filter_sql_v1('', v_filters)) into v_count;
    if v_count <> 1
      or (select public.prospect_index_matches_v1(pi, '', v_filters) from public.prospect_index pi where pi.id = v_seg_person)
      or not (select public.prospect_index_matches_v1(pi, '', v_filters) from public.prospect_index pi where pi.id = v_plain_person) then
      raise exception 'SEG/ESP proof: discard did not hide exactly the SEG person';
    end if;

    -- keep: both visible again, with the same compiled SQL.
    v_version := pg_sequence_last_value('public.data_version_prospect'::regclass);
    update public.client_settings set seg_emails = 'keep' where client_id = v_client;
    if pg_sequence_last_value('public.data_version_prospect'::regclass) = v_version then
      raise exception 'SEG/ESP proof: changing the setting did not move the cache version';
    end if;
    execute format('select count(*) from public.companies c where c.id in (%L, %L) and (%s)',
      v_seg_company, v_plain_company, public.company_filter_sql_v3('', v_filters, false)) into v_count;
    if v_count <> 2 then
      raise exception 'SEG/ESP proof: keep still hides a company';
    end if;
    execute format('select count(*) from public.prospect_index pi where pi.id in (%L, %L) and (%s)',
      v_seg_person, v_plain_person, public.prospect_filter_sql_v1('', v_filters)) into v_count;
    if v_count <> 2 then
      raise exception 'SEG/ESP proof: keep still hides a person';
    end if;

    raise exception 'seg-esp-proof-passed';
  exception when others then
    if sqlerrm <> 'seg-esp-proof-passed' then raise; end if;
  end;
  raise notice 'SEG/ESP proof passed and was rolled back.';
end;
$proof$;
