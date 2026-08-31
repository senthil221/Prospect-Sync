-- Keyword search was unusable, in three separate ways.
--
-- 1. The keyword picker never passed an endpoint, so TokenValuePicker fell back
--    to the PEOPLE one. Every keystroke asked prospect_filter_values_v3 for
--    '__company_keywords', which has no case for it: a 674k-row scan of
--    prospect_index to return nothing, ~2.4s each, and a statement timeout under
--    load. Fixed in CompanyFilterPanel.tsx.
--
-- 2. company_filter_values_v1 had no case for '__company_keywords' either, so
--    even pointed at the right endpoint it returned an empty dropdown.
--
-- 3. The suggestion query itself unnested keywords across all 418,151 companies
--    and grouped them, on every keystroke:
--
--      "Hr"              6.1 s
--      empty (on open)  14.7 s   <- over the timeout under any load
--      __keywords        5.3 s   <- already broken before this, same query
--
--    There are 2,357,195 distinct keywords, so no index on companies can serve a
--    substring match over them. The values have to be summarised once and looked
--    up, which is what this table is.
--
-- Measured on production: build 31s, index 16s, and then
--
--      "Hr"       6.1 s -> 602 ms      identical rows and counts
--      empty     14.7 s -> instant
--
-- Deliberately a plain table refreshed on a schedule, not a trigger-maintained
-- one. Company imports write in bulk, and a per-row trigger on a 418k-row table
-- is exactly the sort of thing that turns a slow import into a failed one. A
-- suggestion list is allowed to lag: nothing stops you typing a keyword that is
-- not in it yet, because the filter itself never reads this table.

begin;

create table if not exists public.company_value_suggestions (
  kind text not null check (kind in ('keywords', 'technologies')),
  value text not null,
  company_count integer not null,
  primary key (kind, value)
);

create index if not exists idx_company_value_suggestions_trgm
  on public.company_value_suggestions using gin (value gin_trgm_ops);

create index if not exists idx_company_value_suggestions_rank
  on public.company_value_suggestions (kind, company_count desc);

alter table public.company_value_suggestions enable row level security;
revoke all on public.company_value_suggestions from anon, authenticated;

-- Rebuild from scratch: cheaper than diffing, and the whole point is that it runs
-- on a schedule rather than on every write.
create or replace function public.refresh_company_value_suggestions_v1()
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '600s'
as $$
declare
  v_rows integer;
begin
  create temporary table tmp_cvs on commit drop as
    select 'keywords'::text as kind, entry.val as value, count(*)::integer as company_count
    from public.companies c cross join lateral unnest(c.keywords) entry(val)
    where btrim(coalesce(entry.val, '')) <> ''
    group by entry.val
    union all
    select 'technologies'::text, entry.val, count(*)::integer
    from public.companies c cross join lateral unnest(c.technologies) entry(val)
    where btrim(coalesce(entry.val, '')) <> ''
    group by entry.val;

  delete from public.company_value_suggestions;
  insert into public.company_value_suggestions (kind, value, company_count)
    select kind, value, company_count from tmp_cvs;
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

select public.refresh_company_value_suggestions_v1();

-- Suggestions now come from the summary table. The live computation is kept as a
-- fallback for the window before the first refresh on a fresh database, so an
-- empty table degrades to "slow" rather than to "no suggestions at all".
create or replace function public.company_filter_values_v1(
  p_field text,
  p_search text default '',
  p_limit integer default 50
)
returns table(value text, match_count bigint)
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_search text := btrim(coalesce(p_search, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_kind text;
  v_have boolean;
begin
  -- '__company_keywords' searches name + keywords (+ description) as one field,
  -- but the only sensible thing to SUGGEST for it is a keyword.
  v_kind := case
    when p_field in ('__keywords', '__company_keywords') then 'keywords'
    when p_field = '__technologies' then 'technologies'
    else null
  end;

  if v_kind is not null then
    select exists (select 1 from public.company_value_suggestions where kind = v_kind) into v_have;
    if v_have then
      return query
        select s.value, s.company_count::bigint
        from public.company_value_suggestions s
        where s.kind = v_kind and (v_search = '' or s.value ilike '%' || v_search || '%')
        order by s.company_count desc, lower(s.value)
        limit v_limit;
      return;
    end if;

    return query
      select entry.val, count(*)::bigint
      from public.companies c
      cross join lateral unnest(case when v_kind = 'technologies' then c.technologies else c.keywords end) entry(val)
      where btrim(coalesce(entry.val, '')) <> '' and (v_search = '' or entry.val ilike '%' || v_search || '%')
      group by entry.val
      order by count(*) desc, lower(entry.val)
      limit v_limit;
    return;
  end if;

  return query
    select picked.val, count(*)::bigint
    from public.companies c
    cross join lateral (
      select case p_field
        when '__industry' then c.industry
        when '__company_city' then c.city
        when '__company_state' then c.state
        when '__company_country' then c.country
        when '__company_location' then coalesce(nullif(c.location, ''),
          concat_ws(', ', nullif(c.city, ''), nullif(c.state, ''), nullif(c.country, '')))
        when '__total_funding' then c.total_funding
        when '__company' then c.name
        when '__website' then c.domain
        else '' end as val
    ) picked
    where btrim(coalesce(picked.val, '')) <> '' and (v_search = '' or picked.val ilike '%' || v_search || '%')
    group by picked.val
    order by count(*) desc, lower(picked.val)
    limit v_limit;
end;
$$;

revoke execute on function public.refresh_company_value_suggestions_v1() from public, anon, authenticated;
revoke execute on function public.company_filter_values_v1(text, text, integer) from public, anon, authenticated;

grant execute on function public.refresh_company_value_suggestions_v1() to service_role;
grant execute on function public.company_filter_values_v1(text, text, integer) to service_role;

commit;
