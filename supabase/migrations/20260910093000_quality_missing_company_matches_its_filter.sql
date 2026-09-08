-- Count "Missing company" the way the workspace can select it.
--
-- The quality tiles are becoming clickable: each one opens the People workspace
-- filtered to the records it counted. That only works if the number and the
-- filter agree, and five of the six already do exactly, checked on production:
--
--   missing work email  23      __work_email empty AND __personal_email empty  23
--   missing website     23,568  __website empty                                23,568
--   missing title       2,115   __title empty                                  2,115
--   missing LinkedIn    82,322  __linkedin empty                               82,322
--   missing company     42      __company empty                                113   <-- disagrees
--
-- The odd one out counts `p.company_id is null`, while every filter in the
-- product matches on the company NAME. 71 prospects have a company_id pointing
-- at a company row that has a domain and no name, so they are missing a company
-- by any definition a user would recognise - they cannot be filtered by company,
-- they show blank in the grid, and they are invisible in the Company database -
-- but the tile did not count them.
--
-- So the tile moves to the definition the rest of the product already uses,
-- rather than the button being wired to a number it cannot reproduce. The count
-- goes 42 -> 113: not 71 new problems, 71 that were always there and unreported.
--
-- Patched by reading the deployed definition and replacing one filter, for the
-- reason given in 20260910090000: this function has outlived the migration that
-- created it, and restating an older body would silently revert anything since.

begin;

do $patch$
declare
  v_def text;
  v_marker constant text := '''missingCompany'', count(*) filter (where p.company_id is null)';
  v_replacement constant text := '''missingCompany'', count(*) filter (where btrim(coalesce(c.name, '''''''')) = '''''''')';
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'data_quality_overview';

  if v_def is null then
    raise exception 'data_quality_overview is not deployed; nothing to patch';
  end if;
  if position(v_replacement in v_def) > 0 then
    return;
  end if;
  if position(v_marker in v_def) = 0 then
    raise exception 'data_quality_overview no longer counts missingCompany in the expected shape; refusing to patch blindly';
  end if;

  execute replace(v_def, v_marker, v_replacement);
end;
$patch$;

-- The tile and the filter must now return the same number.
do $$
declare
  v_tile bigint;
  v_filter bigint;
begin
  select (public.data_quality_overview()->>'missingCompany')::bigint into v_tile;
  select count(*) into v_filter from public.prospect_index where btrim(coalesce(company_name, '')) = '';
  if v_tile is distinct from v_filter then
    raise exception 'missingCompany tile (%) still disagrees with the __company empty filter (%)', v_tile, v_filter;
  end if;
end;
$$;

commit;
