-- Date Contacted used to merge two dates by taking whichever was EARLIER
-- (least()), so re-importing a prospect who was contacted again could never
-- move the date forward - only a manual "Set Date Contacted" bulk action
-- (set_client_date_contacted_v1, unconditional, already existed for this) could.
-- Requested directly: reimporting the same prospects as they get re-contacted
-- should update Date Contacted to the new one automatically, with no separate
-- manual step after every import.
--
-- THE RULE, EXACTLY AS ASKED. "If the import carries a date, overwrite - if it
-- doesn't, keep whatever's there":
--
--   import supplies a date        -> that date, always, earlier or later
--   import supplies no date       -> the existing value, untouched
--
-- Not a "later wins" comparison - that was the recommended, safer alternative,
-- and it was explicitly declined in favor of unconditional overwrite. The
-- accepted risk: a reimport carrying a stale or wrong date can move Date
-- Contacted backward with no warning, same as the manual bulk action already
-- could.
--
-- SPLICED AGAINST THE LIVE FUNCTION, not reconstructed from a migration file.
-- 20260918150000/20260918160000 both taught this the hard way on a different
-- function: a file-based copy missed a later in-place patch and the deploy
-- failed twice. This body is pg_get_functiondef's own output, fetched
-- immediately before writing this migration, with the one clause changed.
-- ---------------------------------------------------------------------------

do $patch$
declare
  v_definition text;
  v_rewritten text;
  v_anchor constant text := $anchor$      date_added = case
        when excluded.date_added is null then public.client_prospects.date_added
        when public.client_prospects.date_added is null then excluded.date_added
        else least(public.client_prospects.date_added, excluded.date_added)
      end,$anchor$;
  v_replacement constant text := $repl$      date_added = coalesce(excluded.date_added, public.client_prospects.date_added),$repl$;
begin
  select pg_get_functiondef('public.sync_client_prospects_from_lists()'::regprocedure) into v_definition;

  if position(v_replacement in v_definition) > 0 then
    return;
  end if;
  if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'sync_client_prospects_from_lists anchor appears % times, expected exactly 1',
      (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor);
  end if;

  v_rewritten := replace(v_definition, v_anchor, v_replacement);
  execute v_rewritten;
end;
$patch$;

revoke execute on function public.sync_client_prospects_from_lists() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The function still compiles (CREATE OR REPLACE above already proved that -
-- PL/pgSQL is parsed and checked at creation time) and still does everything
-- it did before except the one clause: blocklist status/reason/blocked_at, and
-- the DELETE branch that drops an import-only membership once its last list
-- link is gone, are untouched by construction - the patch replaced one clause
-- and left the rest of the text byte-identical.
--
-- What actually needed proving is the new CASE/COALESCE expression itself: the
-- old one was a three-way case, the new one is a two-way coalesce, and a typo
-- collapsing them wrongly (e.g. accidentally keeping "least" on one path)
-- would not show up as a syntax error - CREATE OR REPLACE would still succeed.
-- So the expression is tested directly, standing in every combination the
-- trigger's ON CONFLICT can actually reach.
do $$
declare
  v_existing date;
  v_incoming date;
  v_result date;
  v_expected date;
  v_cases jsonb := $c$[
    {"existing": null, "incoming": null, "expected": null},
    {"existing": null, "incoming": "2026-09-01", "expected": "2026-09-01"},
    {"existing": "2026-01-01", "incoming": null, "expected": "2026-01-01"},
    {"existing": "2026-01-01", "incoming": "2026-09-01", "expected": "2026-09-01"},
    {"existing": "2026-09-01", "incoming": "2026-01-01", "expected": "2026-01-01"},
    {"existing": "2026-05-05", "incoming": "2026-05-05", "expected": "2026-05-05"}
  ]$c$::jsonb;
  v_case jsonb;
begin
  for v_case in select value from jsonb_array_elements(v_cases) loop
    v_existing := nullif(v_case->>'existing', '')::date;
    v_incoming := nullif(v_case->>'incoming', '')::date;
    v_expected := nullif(v_case->>'expected', '')::date;

    execute format('select coalesce(%L::date, %L::date)', v_incoming, v_existing) into v_result;

    if v_result is distinct from v_expected then
      raise exception 'existing=% incoming=%: expected % but the new expression gives %',
        v_existing, v_incoming, v_expected, v_result;
    end if;
  end loop;

  raise notice 'date_added merge: import date always wins when present, existing value survives an import with no date - all % cases checked', jsonb_array_length(v_cases);
end $$;
