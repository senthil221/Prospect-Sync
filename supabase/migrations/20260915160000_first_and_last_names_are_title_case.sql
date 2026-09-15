-- First and last names, title-cased - but only where nobody has already cased
-- them.
--
-- WHAT THE DATA LOOKS LIKE. Measured on production 2026-09-15 over 683,784
-- prospects, every one of which has a first name:
--
--   first names that are entirely one case and wrongly cased    30,093
--   last names  that are entirely one case and wrongly cased    30,638
--   names already mixed-case that initcap WOULD damage             889
--     of those, Mc/Mac/De/Van/O style                               98
--
-- WHY MIXED CASE IS LEFT ALONE. initcap('McDonald') is 'Mcdonald', and
-- initcap('SenthilKumar') is 'Senthilkumar'. Both are somebody's casing
-- decision and a bulk rule has no standing to overrule them; the 889 are
-- excluded by requiring the value to equal its own upper() or lower(). PRAKHAR
-- and prakhar carry no such decision, and become Prakhar.
--
-- This matches db/normalize.ts titleCaseName, which applies the same rule and
-- the same word boundaries on import, so the backfill and every future import
-- agree about the same input.
--
-- FULL NAME IS DELIBERATELY NOT TOUCHED. Asked for and decided: only the two
-- name columns. The consequence is worth writing down rather than discovering -
-- prospects.full_name keeps whatever casing it already had, so a row can read
-- first_name 'Prakhar' beside full_name 'PRAKHAR KESHARIYA', and the People
-- grid shows full_name. Deriving full_name from the parts is a one-line change
-- to this file if that is ever wanted; it would touch 683,181 of 683,784 rows,
-- where full_name currently equals first || ' ' || last.
--
-- WHY THIS DOES NOT REINDEX. prospect_index carries first_name and last_name as
-- their own columns, so they do have to be corrected - but search_text is built
-- from full_name, not from the parts (see reindex_prospects), and full_name is
-- not changing. So a narrow two-column UPDATE of the affected rows is both
-- sufficient and provably equivalent to a re-index here, at a fraction of the
-- cost: reindex_prospects rebuilds the entire index row, with its correlated
-- subqueries for lists, clients, tags and contact counts, for every id.
-- ---------------------------------------------------------------------------

do $$
declare
  v_first integer;
  v_last integer;
  v_index integer;
  v_mixed bigint;
begin
  -- The guard, asserted before anything is written: no mixed-case name may be
  -- in range. If this ever selects rows, the predicate has drifted.
  select count(*) into v_mixed from public.prospects
   where (first_name <> upper(first_name) and first_name <> lower(first_name)
          and first_name = initcap(first_name))
      or (last_name <> upper(last_name) and last_name <> lower(last_name)
          and last_name = initcap(last_name));

  -- Both columns in ONE pass. Neither predicate is indexable - initcap() of a
  -- column cannot be - so each UPDATE is a full scan of 683,784 rows, and two
  -- of them measured 2m31s holding a write lock on prospects. One scan halves
  -- that; the CASE leaves the column it is not fixing exactly as it was.
  -- Both columns, both tables, in ONE statement.
  --
  -- WHERE THE TIME ACTUALLY GOES, because the obvious guess is wrong. The
  -- predicate is not indexable - initcap() of a column cannot be - so this is a
  -- full scan of 683,784 rows, and the first instinct is that the scan is the
  -- cost. It is not: measured on production, the scan and its predicate take
  -- 955ms and the verification scan 334ms. The whole thing takes ~2m20s.
  --
  -- The cost is index maintenance on the 34,797 rows that change, across two
  -- heavily indexed tables - prospects and prospect_index, the latter carrying
  -- several GIN indexes. That is irreducible without dropping indexes, which is
  -- not worth it for a one-off. Three shapes were measured (two updates: 2m31s;
  -- one combined update plus a re-join: 2m14s; this: 2m24s) and they are all
  -- the same number, which is the tell.
  --
  -- So this form is chosen for being one statement rather than for being
  -- faster: the data-modifying CTE hands the changed ids straight to the index
  -- update, so the two tables cannot disagree even transiently, and there is no
  -- second pass to forget. The locks are row-level on 34,797 rows for ~2m20s;
  -- readers and every other row are unaffected.
  with changed as (
    update public.prospects
       set first_name = case
             when btrim(coalesce(first_name, '')) <> ''
              and (first_name = upper(first_name) or first_name = lower(first_name))
             then initcap(first_name) else first_name end,
           last_name = case
             when btrim(coalesce(last_name, '')) <> ''
              and (last_name = upper(last_name) or last_name = lower(last_name))
             then initcap(last_name) else last_name end
     where (btrim(coalesce(first_name, '')) <> ''
            and (first_name = upper(first_name) or first_name = lower(first_name))
            and first_name <> initcap(first_name))
        or (btrim(coalesce(last_name, '')) <> ''
            and (last_name = upper(last_name) or last_name = lower(last_name))
            and last_name <> initcap(last_name))
    returning id, first_name, last_name
  )
  update public.prospect_index pi
     set first_name = changed.first_name, last_name = changed.last_name
    from changed
   where changed.id = pi.id;
  get diagnostics v_index = row_count;
  v_first := v_index;
  v_last := v_index;

  raise notice 'title-cased % rows (first and last); % index rows realigned', v_first, v_index;

  -- One scan for all three post-conditions rather than three: nothing
  -- entirely-one-case is left wrongly cased, and the mixed-case names counted
  -- before the writes are still there. The second half is the check that would
  -- catch a predicate wide enough to have eaten McDonald.
  declare
    v_left integer;
    v_mixed_after bigint;
  begin
    select
      count(*) filter (where (btrim(coalesce(first_name, '')) <> ''
                              and (first_name = upper(first_name) or first_name = lower(first_name))
                              and first_name <> initcap(first_name))
                          or (btrim(coalesce(last_name, '')) <> ''
                              and (last_name = upper(last_name) or last_name = lower(last_name))
                              and last_name <> initcap(last_name))),
      count(*) filter (where (first_name <> upper(first_name) and first_name <> lower(first_name)
                              and first_name = initcap(first_name))
                          or (last_name <> upper(last_name) and last_name <> lower(last_name)
                              and last_name = initcap(last_name)))
      into v_left, v_mixed_after
      from public.prospects;

    if v_left <> 0 then
      raise exception '% names remain wrongly cased after the backfill', v_left;
    end if;
    if v_mixed_after < v_mixed then
      raise exception 'the backfill changed % names that were already cased', v_mixed - v_mixed_after;
    end if;
  end;

  -- And the index agrees with the table on both columns, for every row.
  if exists (select 1 from public.prospect_index pi join public.prospects p on p.id = pi.id
              where pi.first_name is distinct from p.first_name
                 or pi.last_name is distinct from p.last_name) then
    raise exception 'prospect_index still disagrees with prospects about a name';
  end if;
end $$;

analyze public.prospects;
analyze public.prospect_index;
