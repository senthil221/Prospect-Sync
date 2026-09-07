-- Let a company export ask for the columns it wants, and let the workspace find
-- out which uploaded ones exist.
--
-- search_company_export_v1 builds its rows with a hard-coded
-- jsonb_build_object('id', ..., 'name', ..., 'domain', ...). That was the whole
-- company file: two columns, Name and Website. Everything else the import
-- already stores - industry, keywords, description, founded year, technologies,
-- employee range, location, ESP - was in the table and reachable from nowhere.
--
-- v2 takes the same key list the prospect export takes, and for the same
-- reason: lib/company-export.ts derives it by running the CSV renderer against
-- a recording proxy, so the columns fetched cannot drift from the columns
-- written.
--
-- WHY THE KEYS BUILD A SELECT LIST RATHER THAN FILTERING to_jsonb(c). The
-- obvious shape is `select public.jsonb_project_v1(to_jsonb(c), p_keys)`, which
-- is what the prospect export does. It is wrong here: companies.all_data holds
-- the uploaded row and companies.short_description averages about a kilobyte,
-- both TOASTed, and to_jsonb(c) detoasts every one of them before the
-- projection throws them away.
--
-- Measured on production, one 5,000-company page taken past the empty names:
-- to_jsonb(c) renders 16 MB of JSON, naming id, sort_name, name and domain
-- renders 664 kB. The 419,218 companies in the table are 84 such pages, so the
-- projected form would have moved something like 1.3 GB from PostgREST to Node
-- to write a file of names and websites, and discarded almost all of it. Naming
-- the columns in the select list instead means an export that did not ask for
-- the description never reads it.
--
-- The list is safe to interpolate because every key is matched against
-- information_schema first and quoted with %I - a key that is not a column of
-- public.companies cannot reach the statement.

begin;

create or replace function public.search_company_export_v2(
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_websites_only boolean default false,
  p_after_name text default null::text,
  p_after_id text default null::text,
  p_limit integer default 5000,
  p_keys text[] default '{}'::text[]
)
returns table(result_rows jsonb)
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '60s'
as $function$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_scope_cte text := '';
  v_where text;
  v_columns text;
  v_select text;
  v_sql text;
begin
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  v_where := format('(%s)', v_match_clause);
  if coalesce(p_websites_only, false) then
    v_where := v_where || $w$ and btrim(coalesce(c.domain, '')) <> ''$w$;
  end if;
  if p_people_scope is not null then
    v_scope_cte := format($s$with scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(null::text, %L::jsonb)
      ) $s$, p_people_scope::text);
    v_where := v_where || ' and c.id in (select company_id from scope_ids)';
  end if;

  -- Only real columns of public.companies survive this join, so nothing a
  -- caller invents can reach the statement, and %I quotes what does.
  select string_agg(format('c.%I', columns.column_name), ', ' order by columns.column_name)
    into v_columns
  from unnest(coalesce(p_keys, '{}'::text[])) as requested(name)
  join information_schema.columns columns
    on columns.table_schema = 'public'
   and columns.table_name = 'companies'
   and columns.column_name = requested.name
  where columns.column_name <> 'id';

  -- No keys means every column, which is what a caller with nothing to say
  -- meant and what v1 effectively did for the three it knew about.
  if coalesce(cardinality(p_keys), 0) = 0 then
    v_select := 'c.*, lower(c.name) as sort_name';
  else
    v_select := 'c.id, lower(c.name) as sort_name' || coalesce(', ' || v_columns, '');
  end if;

  -- Keyset on (lower(name), id): total, indexed by idx_companies_lower_name_id,
  -- and stable across pages even while companies are being inserted underneath
  -- it. sort_name travels with the row because the cursor has to be the value
  -- PostgreSQL sorted on - lower-casing it again in Node would be a different
  -- function under a different collation, and a cursor that disagrees with the
  -- ORDER BY skips or repeats rows.
  v_sql := format($q$
    %1$s select coalesce((select jsonb_agg(to_jsonb(page) order by page.sort_name, page.id) from (
      select %6$s
      from public.companies c
      where %2$s
        and (%3$L::text is null or (lower(c.name), c.id) > (%3$L::text, coalesce(%4$L, '')))
      order by lower(c.name), c.id
      limit %5$s
    ) page), '[]'::jsonb)
  $q$, v_scope_cte, v_where, p_after_name, p_after_id, v_limit::text, v_select);

  return query execute v_sql;
end;
$function$;

comment on function public.search_company_export_v2(text, jsonb, jsonb, boolean, text, text, integer, text[]) is
  'Keyset page of matching companies carrying only the named columns, plus id and sort_name for the cursor.';

revoke execute on function public.search_company_export_v2(text, jsonb, jsonb, boolean, text, text, integer, text[]) from public, anon, authenticated;
grant execute on function public.search_company_export_v2(text, jsonb, jsonb, boolean, text, text, integer, text[]) to service_role;

-- Which uploaded keys exist on companies.all_data.
--
-- There is no company equivalent of the prospect_fields registry, and adding
-- one would mean a write on every company import for a list that is read when
-- somebody opens an export dialog. So this samples instead: it stops after
-- 20,000 companies that have any uploaded data at all, which is enough to find
-- every column an import brought - a CSV gives the same headers to every row it
-- writes - and is bounded whatever the table grows to. On production today it
-- finds 22 keys in 327 ms, which is a dialog opening rather than a page load.
--
-- The count that comes back is the count within the sample, not the table. It
-- is there to order the list by how often a key is actually populated, which is
-- what makes the picker readable when an import brought thirty of them.
create or replace function public.company_export_field_names_v1(p_limit integer default 200)
returns table(field_name text, populated bigint)
language sql
stable
security definer
set search_path to 'public'
set statement_timeout to '8s'
as $function$
  with scanned as (
    select c.all_data
    from public.companies c
    where c.all_data <> '{}'::jsonb
    limit 20000
  )
  select entry.key::text, count(*)::bigint
  from scanned
  cross join lateral jsonb_each_text(scanned.all_data) entry
  where btrim(coalesce(entry.value, '')) <> ''
  group by entry.key
  order by count(*) desc, entry.key
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$function$;

comment on function public.company_export_field_names_v1(integer) is
  'Uploaded companies.all_data keys, discovered from a bounded sample, ordered by how often they are populated.';

revoke execute on function public.company_export_field_names_v1(integer) from public, anon, authenticated;
grant execute on function public.company_export_field_names_v1(integer) to service_role;

commit;
