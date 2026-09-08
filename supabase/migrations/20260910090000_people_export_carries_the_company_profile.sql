-- Let a People export carry the company profile, not just the company name.
--
-- The People export can already write Company, Website, # Employees and the
-- company city/state/country, because prospect_index carries those columns. It
-- cannot write Industry, Keywords, Description, Founded Year, Technologies or
-- Total Funding, because those live only on public.companies - so the same
-- fields that are exportable from the Companies tab are missing from the People
-- tab, for the same company.
--
-- WHY A VIEW RATHER THAN SIX MORE COLUMNS ON prospect_index. prospect_index is
-- the hot path: every search, every filter, every listing reads it, and it is
-- deliberately narrow (20260825030000 exists purely to shrink it). Adding a
-- kilobyte of description per row to 681,785 rows would slow every read in the
-- product to serve exports, and would need a backfill and a trigger change to
-- stay correct.
--
-- The view costs nothing when the columns are not asked for. PostgreSQL
-- eliminates a LEFT JOIN whose columns go unused when the join is on a unique
-- key, and companies.id is the primary key - verified on production:
--
--   select pi.id, pi.full_name from ... left join companies  ->  Seq Scan on prospect_index
--   select pi.id, c.industry  from ... left join companies  ->  Nested Loop + Memoize + companies_pkey
--
-- So an export of Full Name and Email plans exactly as it does today, and only
-- an export that asks for Industry pays for the join - which is then an indexed,
-- memoised lookup rather than a scan.
--
-- WHY THE TWO FUNCTIONS ARE PATCHED RATHER THAN RESTATED. search_prospect_export_v5
-- and prospect_exports.build_batch_v1 each read prospect_index in exactly one
-- place, and each has been redefined by later migrations than the one that
-- introduced it. Restating a 113-line body from an older migration would ship
-- whichever version that file happened to hold and silently undo anything added
-- since. Instead each definition is read back from the catalogue as deployed,
-- one identifier is replaced, and the result is re-executed - so the patch
-- applies to whatever is actually running.
--
-- Both patches assert that the marker was found. 20260825030000 is the
-- cautionary tale here: it spliced into already-deployed function bodies and
-- SKIPPED SILENTLY when it could not find the arm to splice after, leaving
-- columns that existed and nothing that could filter on them. A missing marker
-- here raises instead.
--
-- v5 is patched in place rather than forked to a v6. The view is a superset of
-- prospect_index, and the function projects by an explicit key list, so a caller
-- that never asks for a company_ key sees byte-identical output. That keeps
-- blue/green releases safe without a version nobody needs.

begin;

create or replace view public.prospect_export_source as
select pi.*,
  c.industry as company_industry,
  c.keywords as company_keywords,
  c.short_description as company_short_description,
  c.founded_year as company_founded_year,
  c.technologies as company_technologies,
  c.total_funding as company_total_funding
from public.prospect_index pi
left join public.companies c on c.id = pi.company_id;

comment on view public.prospect_export_source is
  'prospect_index plus the company profile columns, for exports only. The join disappears when no company_ column is selected.';

revoke all on public.prospect_export_source from public, anon, authenticated;
grant select on public.prospect_export_source to service_role;

-- 1. The direct export path ---------------------------------------------------

do $patch$
declare
  v_def text;
  v_marker constant text := 'from page join public.prospect_index pi on pi.id = page.id';
  v_replacement constant text := 'from page join public.prospect_export_source pi on pi.id = page.id';
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'search_prospect_export_v5';

  if v_def is null then
    raise exception 'search_prospect_export_v5 is not deployed; nothing to patch';
  end if;

  -- Already patched by an earlier run of this migration.
  if position(v_replacement in v_def) > 0 then
    return;
  end if;
  if position(v_marker in v_def) = 0 then
    raise exception 'search_prospect_export_v5 no longer hydrates from prospect_index in the expected shape; refusing to patch blindly';
  end if;

  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- 2. The background export path -----------------------------------------------
--
-- Without this, a People export small enough to stream would carry Industry and
-- the same export one row larger would silently drop it.

do $patch$
declare
  v_def text;
  v_marker constant text := 'join public.prospect_index pi on pi.id = b.entity_id';
  v_replacement constant text := 'join public.prospect_export_source pi on pi.id = b.entity_id';
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'prospect_exports' and p.proname = 'build_batch_v1';

  if v_def is null then
    raise exception 'prospect_exports.build_batch_v1 is not deployed; nothing to patch';
  end if;

  if position(v_replacement in v_def) > 0 then
    return;
  end if;
  if position(v_marker in v_def) = 0 then
    raise exception 'prospect_exports.build_batch_v1 no longer joins prospect_index in the expected shape; refusing to patch blindly';
  end if;

  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- 3. Prove both paths can actually see the new columns -------------------------

do $$
declare
  v_missing text[] := array[]::text[];
  v_column text;
begin
  foreach v_column in array array[
    'company_industry', 'company_keywords', 'company_short_description',
    'company_founded_year', 'company_technologies', 'company_total_funding'
  ] loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'prospect_export_source'
        and column_name = v_column
    ) then
      v_missing := array_append(v_missing, v_column);
    end if;
  end loop;
  if cardinality(v_missing) > 0 then
    raise exception 'prospect_export_source is missing %', array_to_string(v_missing, ', ');
  end if;

  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'search_prospect_export_v5')
     not like '%prospect_export_source%' then
    raise exception 'search_prospect_export_v5 was not patched';
  end if;

  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'prospect_exports' and p.proname = 'build_batch_v1')
     not like '%prospect_export_source%' then
    raise exception 'prospect_exports.build_batch_v1 was not patched';
  end if;
end;
$$;

commit;
