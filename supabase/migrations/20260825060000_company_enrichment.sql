-- Fill empty fields from other records that share the same website.
--
-- The website is the anchor: canonical_company_identity already resolves every
-- prospect to a company keyed on normalized domain, so "elsewhere in the master
-- database for this company" is just that company's other rows.
--
-- Only company-level facts propagate. Title, seniority, email and LinkedIn are
-- person-level — two people at one company legitimately differ, and copying
-- those between them would corrupt the database rather than enrich it.

-- ---------------------------------------------------------------------------
-- 1. What could be filled (preview)
-- ---------------------------------------------------------------------------
-- Nothing writes until the user has seen this. Silent bulk mutation of a master
-- database is the kind of feature you only regret once.

create or replace function public.enrichment_preview_v1(p_limit integer default 25)
returns jsonb
language sql
stable
security definer
set search_path = public
set statement_timeout = '60s'
as $$
  with candidates as (
    select
      c.id as company_id,
      c.name as company_name,
      c.domain,
      -- The best available value for each company field, taken from whichever
      -- of this company's own records actually has one.
      nullif(c.industry, '') as industry,
      max(nullif(p.city, '')) filter (where c.city = '') as fill_city,
      max(nullif(p.state, '')) filter (where c.state = '') as fill_state,
      max(nullif(p.country, '')) filter (where c.country = '') as fill_country,
      max(nullif(p.location, '')) filter (where c.location = '') as fill_location
    from public.companies c
    join public.prospects p on p.company_id = c.id
    where c.normalized_domain <> ''
    group by c.id
  ), fillable as (
    select company_id, company_name, domain,
      (case when fill_city is not null then 1 else 0 end
       + case when fill_state is not null then 1 else 0 end
       + case when fill_country is not null then 1 else 0 end
       + case when fill_location is not null then 1 else 0 end) as fields
    from candidates
  )
  select jsonb_build_object(
    'companies', (select count(*) from fillable where fields > 0),
    'fields', (select coalesce(sum(fields), 0) from fillable where fields > 0),
    'sample', coalesce((
      select jsonb_agg(jsonb_build_object(
        'companyId', company_id, 'company', company_name, 'domain', domain, 'fields', fields)
        order by fields desc, company_name)
      from (select * from fillable where fields > 0 order by fields desc, company_name
            limit greatest(1, least(coalesce(p_limit, 25), 100))) top
    ), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. Apply
-- ---------------------------------------------------------------------------
-- Fills blanks only — a populated value is never overwritten — and records what
-- was inferred so a filled value stays distinguishable from an uploaded one.

create or replace function public.enrich_from_company_v1(
  p_company_ids text[] default null,
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_updated integer := 0;
  v_ids text[];
begin
  with sourced as (
    select
      c.id as company_id,
      max(nullif(p.city, '')) as city,
      max(nullif(p.state, '')) as state,
      max(nullif(p.country, '')) as country,
      max(nullif(p.location, '')) as location
    from public.companies c
    join public.prospects p on p.company_id = c.id
    where c.normalized_domain <> ''
      and (p_company_ids is null or c.id = any(p_company_ids))
    group by c.id
  ), applied as (
    update public.companies c set
      city = case when c.city = '' then coalesce(sourced.city, '') else c.city end,
      state = case when c.state = '' then coalesce(sourced.state, '') else c.state end,
      country = case when c.country = '' then coalesce(sourced.country, '') else c.country end,
      location = case when c.location = '' then coalesce(sourced.location, '') else c.location end,
      all_data = c.all_data || jsonb_build_object(
        '_enriched_from', 'company_records', '_enriched_at', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSZ')),
      updated_at = now()
    from sourced
    where c.id = sourced.company_id
      and (
        (c.city = '' and sourced.city is not null)
        or (c.state = '' and sourced.state is not null)
        or (c.country = '' and sourced.country is not null)
        or (c.location = '' and sourced.location is not null)
      )
    returning c.id
  )
  select count(*)::integer, coalesce(array_agg(id), array[]::text[]) into v_updated, v_ids from applied;

  if cardinality(v_ids) > 0 then
    perform public.reindex_scope_v1(p_company_ids => v_ids);
  end if;

  perform public.record_operation('enrich_from_company', null, p_actor,
    format('Filled company gaps on %s companies', v_updated), v_updated, array[]::text[]);

  return jsonb_build_object('companies', v_updated);
end;
$$;

revoke execute on function public.enrichment_preview_v1(integer) from public, anon, authenticated;
revoke execute on function public.enrich_from_company_v1(text[], text) from public, anon, authenticated;
grant execute on function public.enrichment_preview_v1(integer) to service_role;
grant execute on function public.enrich_from_company_v1(text[], text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Smoke test
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_preview jsonb;
  v_result jsonb;
begin
  insert into public.companies (id, name, normalized_name, domain, normalized_domain)
    values ('domain:enrich-smoke.invalid', 'Enrich Smoke', 'enrich smoke', 'enrich-smoke.invalid', 'enrich-smoke.invalid')
    on conflict (id) do nothing;
  -- One record knows the country, the other does not: the company should learn it.
  insert into public.prospects (id, full_name, work_email, company_id, city, country)
    values ('__enrich_smoke_a__', 'Knows Location', 'a@enrich-smoke.invalid', 'domain:enrich-smoke.invalid', 'Chennai', 'India')
    on conflict (id) do nothing;
  insert into public.prospects (id, full_name, work_email, company_id)
    values ('__enrich_smoke_b__', 'Knows Nothing', 'b@enrich-smoke.invalid', 'domain:enrich-smoke.invalid')
    on conflict (id) do nothing;

  v_preview := public.enrichment_preview_v1(5);
  if v_preview->'companies' is null or v_preview->'sample' is null then
    raise exception 'enrichment_preview_v1 returned an unexpected shape: %', v_preview;
  end if;

  v_result := public.enrich_from_company_v1(array['domain:enrich-smoke.invalid'], 'smoke');
  if not exists (select 1 from public.companies where id = 'domain:enrich-smoke.invalid' and country = 'India' and city = 'Chennai') then
    raise exception 'enrichment did not fill the company location from its own records';
  end if;

  -- A populated value must never be overwritten.
  update public.companies set country = 'Singapore' where id = 'domain:enrich-smoke.invalid';
  perform public.enrich_from_company_v1(array['domain:enrich-smoke.invalid'], 'smoke');
  if (select country from public.companies where id = 'domain:enrich-smoke.invalid') <> 'Singapore' then
    raise exception 'enrichment overwrote a populated value';
  end if;

  delete from public.operation_log where action = 'enrich_from_company' and summary like '%1 companies%';
  delete from public.prospects where id in ('__enrich_smoke_a__', '__enrich_smoke_b__');
  delete from public.companies where id = 'domain:enrich-smoke.invalid';
end;
$smoke$;
