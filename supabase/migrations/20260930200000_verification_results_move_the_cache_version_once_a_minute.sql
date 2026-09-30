-- Verification results move the prospect cache version at most once a minute.
--
-- MEASURED on production 2026-09-30: public.data_version_prospect advanced 76
-- times in 30 seconds. Every count and page cache keyed on it - dashboard
-- counts (dashboard_workspace), People and Company totals, result sets,
-- filter values, snapshots - was thrown away continuously, so pages that
-- should answer from cache recomputed (Overview ~3s, People ~3.5s) on nearly
-- every load. Nothing a person did caused it: the email verification worker
-- reconciles ~130 results a minute, prospect_verification.sync_index_projection
-- copies each result into prospect_index with its own UPDATE, and every UPDATE
-- on prospect_index fires the statement-level bump_data_version_prospect.
--
-- THE CHANGE, without touching any of the version's ~15 consumers:
--   * sync_index_projection marks its own UPDATE with a transaction-local
--     setting, prospect_verification.projection_only = 'on', and clears it
--     after the statement (the AFTER STATEMENT trigger has fired by then);
--   * bump_data_version_prospect, seeing the mark, advances the version only if
--     it has not done so for a verification result in the current minute
--     (data_version_verification_minute holds that minute).
-- Every other write to prospect_index - imports, edits, reindexing, deletes -
-- still bumps immediately, exactly as before. A cached count that filters on
-- verification status is at most a minute behind while verification runs;
-- one that does not is no longer invalidated by verification at all.
-- Two sessions in the same new minute may both bump: one extra bump, harmless.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create sequence if not exists public.data_version_verification_minute minvalue 0 start 0;
comment on sequence public.data_version_verification_minute is
  'The epoch minute in which a verification result last advanced data_version_prospect.';

create or replace function public.bump_data_version_prospect()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_minute bigint;
begin
  -- Once per statement, not once per row: an import batch of 5,000 rows bumps
  -- this once. The value carries no meaning beyond "something moved".
  --
  -- A verification result copied into prospect_index moves it at most once a
  -- minute (20260930200000); everything else moves it every time.
  if current_setting('prospect_verification.projection_only', true) = 'on' then
    v_minute := floor(extract(epoch from clock_timestamp()) / 60)::bigint;
    if coalesce(pg_sequence_last_value('public.data_version_verification_minute'::regclass), 0) >= v_minute then
      return null;
    end if;
    perform setval('public.data_version_verification_minute', v_minute);
  end if;
  perform nextval('public.data_version_prospect');
  return null;
end;
$function$;

revoke execute on function public.bump_data_version_prospect() from public, anon, authenticated;

create or replace function prospect_verification.sync_index_projection()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  -- Marked so the prospect cache version moves at most once a minute for
  -- verification results (public.bump_data_version_prospect, 20260930200000).
  perform set_config('prospect_verification.projection_only', 'on', true);
  update public.prospect_index set
    work_email_revision = new.work_email_revision,
    verification_checked_email = new.verification_checked_email,
    verification_status = new.verification_status,
    verification_reason = new.verification_reason,
    verification_provider = new.verification_provider,
    verification_checked_at = new.verification_checked_at,
    verification_generation = new.verification_generation,
    verification_result_id = new.verification_result_id
  where id = new.id;
  perform set_config('prospect_verification.projection_only', '', true);
  return null;
end $function$;

revoke execute on function prospect_verification.sync_index_projection() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: a burst of verification projections moves the version
-- at most twice (a minute boundary may fall inside the burst); an ordinary
-- prospect_index update still moves it every time. Sequences are not
-- transactional, so the proof advances the real version by a handful - the
-- same as any write, and harmless.
do $$
declare
  v_ids text[];
  v_before bigint;
  v_after bigint;
  v_id text;
begin
  select array_agg(id) into v_ids from (select id from public.prospects order by id limit 20) p;
  if coalesce(array_length(v_ids, 1), 0) < 2 then
    raise notice 'Cache version proof skipped: fewer than two prospects.';
    return;
  end if;

  begin
    v_before := pg_sequence_last_value('public.data_version_prospect'::regclass);
    -- The real trigger path: touching verification_result_id on prospects fires
    -- sync_index_projection once per row.
    update public.prospects set verification_result_id = verification_result_id where id = any(v_ids);
    foreach v_id in array v_ids loop
      update public.prospects set verification_result_id = verification_result_id where id = v_id;
    end loop;
    v_after := pg_sequence_last_value('public.data_version_prospect'::regclass);
    if v_after - v_before > 2 then
      raise exception 'Cache version proof: % verification projections moved the version % times', array_length(v_ids, 1) * 2, v_after - v_before;
    end if;
    if current_setting('prospect_verification.projection_only', true) = 'on' then
      raise exception 'Cache version proof: the projection mark leaked past its statement';
    end if;

    v_before := pg_sequence_last_value('public.data_version_prospect'::regclass);
    update public.prospect_index set full_name = full_name where id = v_ids[1];
    update public.prospect_index set full_name = full_name where id = v_ids[2];
    v_after := pg_sequence_last_value('public.data_version_prospect'::regclass);
    if v_after - v_before <> 2 then
      raise exception 'Cache version proof: two ordinary updates moved the version % times', v_after - v_before;
    end if;

    raise exception 'proof-ok';
  exception when others then
    if sqlerrm = 'proof-ok' then
      raise notice 'Cache version proof passed and was rolled back.';
    else
      raise;
    end if;
  end;
end $$;
