-- 673,859 prospects carry a Client Date Contacted that nobody ever set.
--
-- WHAT HAPPENED. 20260828010000 added client_prospects.date_added as
--
--   add column if not exists date_added date not null default current_date;
--
-- so every membership written while that default existed was stamped with the
-- day it was imported, whether or not anybody had been contacted.
-- 20260829004125 dropped the default the following day - correctly - but only
-- fixed the schema. The rows already stamped were never corrected, and have
-- been reading as "contacted on the day they were imported" ever since.
--
-- THE EVIDENCE, measured on production 2026-09-15:
--
--   imported on   rows      date_added set   equal to the import date
--   2026-08-25    631,780   631,780          631,780
--   2026-08-27        945       945                0     <- real dates
--   2026-08-28     42,079    42,079           42,079
--   2026-09-05        700         0                0     <- after the fix
--   2026-09-13        999         0                0
--   2026-09-14      1,000         0                0
--
-- Two things fall out of that table. The default was live on the 25th and the
-- 28th and gone by September, which is exactly the window 20260828010000 and
-- 20260829004125 bracket. And on the 27th, 945 rows carry dates that differ
-- from their import date - so when a real Date Contacted was supplied it was
-- stored, which is why "equal to the import date" is a sound test for the
-- stamped rows rather than a guess.
--
-- The two real clients are untouched by this: 8,768 and 2,085 rows, none of
-- which has date_added equal to its import date. Every one of the 673,859 is in
-- the prospect-sync-no-client bucket, which is not a client at all - nobody has
-- ever run a campaign for "no client", so none of them can have been contacted
-- for it.
--
-- WHAT IT COSTS TODAY. cp.date_added is the cooldown clock: list_workspace
-- computes next_eligible_at from it, lib/client-idle-age.ts renders the row
-- badge from it, and 20260915110000's __contactable filter reads it. So all
-- 673,859 show a cooldown that never started, and the Contactable tab reports
-- 2,699 of 677,503 when the honest answer is all of them.
--
-- WHY NULL AND NOT A BETTER GUESS. Null is what the column means by "never
-- contacted", and it is the truth here. Substituting any other date would be
-- the original bug in a different shape.
--
-- WHY THIS IS SAFE TO RUN. The value being removed is derivable - it IS
-- added_at::date - so if this turns out to be wrong it is restorable by the
-- same rule that finds it. Pinning the update to the two affected import days
-- is what keeps a genuine contact date that happened to equal its import date
-- out of range; without that predicate this would be a guess about 11,798 rows
-- it has no business touching.
--
-- WHY IT DOES NOT NEED BATCHING OR RE-INDEXING. Neither trigger on
-- client_prospects fires: both are UPDATE OF specific columns and neither lists
-- date_added. That is asserted below rather than assumed, because a future
-- trigger added without a column list would turn this file's UPDATE into
-- 673,859 trigger invocations. And prospect_index carries no copy of
-- date_added - the client workspace reads it live - so nothing here queues a
-- re-index.
-- ---------------------------------------------------------------------------

do $$
declare
  v_attnum smallint;
  v_offender text;
  v_stamped bigint;
  v_genuine_before bigint;
  v_genuine_after bigint;
  v_cleared bigint;
begin
  select attnum into v_attnum from pg_attribute
   where attrelid = 'public.client_prospects'::regclass and attname = 'date_added' and not attisdropped;
  if v_attnum is null then
    raise exception 'client_prospects.date_added does not exist';
  end if;

  -- No trigger may fire for a date_added-only UPDATE. tgtype bit 4 (16) is
  -- UPDATE; an empty tgattr means "any column".
  select string_agg(t.tgname, ', ') into v_offender
    from pg_trigger t
   where t.tgrelid = 'public.client_prospects'::regclass
     and not t.tgisinternal
     and (t.tgtype::integer & 16) <> 0
     and (cardinality(t.tgattr::smallint[]) = 0 or v_attnum = any(t.tgattr::smallint[]));
  if v_offender is not null then
    raise exception 'trigger(s) % would fire once per row for this update; batch it or exclude them', v_offender;
  end if;

  -- The schema fix must already be in place, or this repair would be undone by
  -- the next import.
  if exists (select 1 from pg_attribute a
              join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
             where a.attrelid = 'public.client_prospects'::regclass and a.attname = 'date_added') then
    raise exception 'client_prospects.date_added still has a default; 20260829004125 has not been applied';
  end if;

  select count(*) into v_stamped from public.client_prospects
   where date_added is not null and date_added = added_at::date
     and added_at::date in (date '2026-08-25', date '2026-08-28');
  select count(*) into v_genuine_before from public.client_prospects
   where date_added is not null
     and (date_added <> added_at::date or added_at::date not in (date '2026-08-25', date '2026-08-28'));

  raise notice 'clearing % stamped dates, preserving % genuine ones', v_stamped, v_genuine_before;

  update public.client_prospects
     set date_added = null
   where date_added is not null
     and date_added = added_at::date
     and added_at::date in (date '2026-08-25', date '2026-08-28');
  get diagnostics v_cleared = row_count;

  if v_cleared <> v_stamped then
    raise exception 'expected to clear % rows, cleared %', v_stamped, v_cleared;
  end if;

  -- Nothing outside the stamped window may have moved. This is the assertion
  -- that would catch a predicate wide enough to eat real contact dates.
  select count(*) into v_genuine_after from public.client_prospects where date_added is not null;
  if v_genuine_after <> v_genuine_before then
    raise exception 'genuine contact dates changed: % before, % after', v_genuine_before, v_genuine_after;
  end if;

  -- Re-running must be a no-op: added_at is untouched, so the predicate finds
  -- nothing the second time.
  if exists (select 1 from public.client_prospects
              where date_added is not null and date_added = added_at::date
                and added_at::date in (date '2026-08-25', date '2026-08-28')) then
    raise exception 'the repair is not idempotent; stamped rows remain';
  end if;

  raise notice 'cleared %, % genuine contact dates intact', v_cleared, v_genuine_after;
end $$;

-- 673,859 dead tuples and a rewritten index range. The planner should not go on
-- believing date_added is dense on this table.
analyze public.client_prospects;
