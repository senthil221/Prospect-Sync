-- People imports gain the duplicate-handling choice company imports have had
-- since 20260825020000: what to do with a person already in the database.
-- Requested directly, after noticing the company import asks and the people
-- import does not.
--
-- WHAT THE PEOPLE IMPORT DID BEFORE THIS, exactly: fill-the-blanks for name,
-- both emails, mobile, LinkedIn and city/state/country/location - but Job
-- Title, Seniority and Department were overwritten whenever the file carried
-- a value. That was never a decision anyone made; it is just how the UPDATE
-- was written, and nothing in the product said so.
--
-- WHAT IT DOES NOW. The mode is read from imports.merge_mode, so the browser
-- path and the background worker both honour it without either one passing it
-- down (the worker reaches this function through process_staged_batch_v1 ->
-- v5 -> v4 -> v3 -> v2 and never sees the mode at all):
--
--   enrich     keep every stored value, fill only the blanks. NOW INCLUDES
--              title/seniority/department, which is the one behaviour change
--              here: a re-import no longer refreshes a job title unless
--              'overwrite' is chosen. The label promises nothing is
--              overwritten, so it must be true of every field.
--   overwrite  the file wins wherever it supplies a value; a column the file
--              leaves blank is left alone, so a narrow CSV cannot blank out
--              data already held.
--   skip       matched people are not touched at all. They are still linked
--              to the list (membership, list_rows and identifiers are written
--              exactly as before) and still counted as duplicates_linked -
--              only the prospects row is left alone. Counting them as skipped
--              instead would have moved them into "Kept without a People DB
--              link" on the completion screen, which would be a lie: they are
--              linked, they were simply not rewritten.
--
-- company_id stays `coalesce(company_id_value, company_id)` in every mode. It
-- is a relationship, not a collected value: a row that resolves a company
-- should attach the person to it, and the company's OWN fields are governed by
-- the company import's merge mode, not this one.
--
-- SPLICED AGAINST THE LIVE FUNCTION, not reconstructed from a migration file -
-- 20260918150000/20260918160000 failed two deploys learning that a file-based
-- copy misses a later in-place patch. This is pg_get_functiondef's own output,
-- fetched immediately before writing this migration, with one block changed.
-- ---------------------------------------------------------------------------

alter table public.imports
  add column if not exists merge_mode text not null default 'enrich';

do $constraint$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.imports'::regclass and conname = 'imports_merge_mode_valid'
  ) then
    alter table public.imports
      add constraint imports_merge_mode_valid
      check (merge_mode in ('enrich', 'overwrite', 'skip'));
  end if;
end;
$constraint$;

do $patch$
declare
  v_definition text;
  v_count integer;
  -- 1. the variable holding the mode for this import.
  v_declare_anchor constant text := $anchor$  skipped_count integer := 0;
begin$anchor$;
  v_declare_replacement constant text := $repl$  skipped_count integer := 0;
  merge_mode_value text;
begin$repl$;
  -- 2. read it once per batch, not once per row.
  v_lookup_anchor constant text := $anchor$begin
  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))$anchor$;
  v_lookup_replacement constant text := $repl$begin
  select coalesce(nullif(i.merge_mode, ''), 'enrich') into merge_mode_value
  from public.imports i where i.id = p_import_id;
  merge_mode_value := coalesce(merge_mode_value, 'enrich');

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))$repl$;
  -- 3. the merge itself. Every column is NOT NULL DEFAULT '' (checked against
  --    production before writing this), so `coalesce(nullif(col, ''), incoming)`
  --    is exactly the `case when col = '' then incoming else col end` it
  --    replaces - only title/seniority/department change meaning.
  v_merge_anchor constant text := $anchor$      update public.prospects set
        first_name = case when first_name = '' then coalesce(row_data->>'firstName', '') else first_name end,
        last_name = case when last_name = '' then coalesce(row_data->>'lastName', '') else last_name end,
        full_name = case when full_name = '' then coalesce(row_data->>'fullName', '') else full_name end,
        work_email = case when work_email = '' then coalesce(row_data->>'workEmail', '') else work_email end,
        personal_email = case when personal_email = '' then coalesce(row_data->>'personalEmail', '') else personal_email end,
        mobile_number = case when mobile_number = '' then coalesce(row_data->>'mobileNumber', '') else mobile_number end,
        linkedin_url = case when linkedin_url = '' then coalesce(row_data->>'linkedinUrl', '') else linkedin_url end,
        title = case when coalesce(row_data->>'title', '') <> '' then row_data->>'title' else title end,
        seniority = case when coalesce(row_data->>'seniority', '') <> '' then row_data->>'seniority' else seniority end,
        department = case when coalesce(row_data->>'department', '') <> '' then row_data->>'department' else department end,
        city = case when city = '' then coalesce(row_data->>'city', '') else city end,
        state = case when state = '' then coalesce(row_data->>'state', '') else state end,
        country = case when country = '' then coalesce(row_data->>'country', '') else country end,
        location = case when location = '' then location_value else location end,
        company_id = coalesce(company_id_value, company_id),
        all_data = coalesce(row_data->'raw', '{}'::jsonb) || all_data,
        updated_at = now()
      where id = prospect_id_value;
      duplicate_count := duplicate_count + 1;$anchor$;
  v_merge_replacement constant text := $repl$      if merge_mode_value <> 'skip' then
        update public.prospects set
          first_name = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'firstName', ''), first_name) else coalesce(nullif(first_name, ''), coalesce(row_data->>'firstName', '')) end,
          last_name = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'lastName', ''), last_name) else coalesce(nullif(last_name, ''), coalesce(row_data->>'lastName', '')) end,
          full_name = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'fullName', ''), full_name) else coalesce(nullif(full_name, ''), coalesce(row_data->>'fullName', '')) end,
          work_email = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'workEmail', ''), work_email) else coalesce(nullif(work_email, ''), coalesce(row_data->>'workEmail', '')) end,
          personal_email = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'personalEmail', ''), personal_email) else coalesce(nullif(personal_email, ''), coalesce(row_data->>'personalEmail', '')) end,
          mobile_number = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'mobileNumber', ''), mobile_number) else coalesce(nullif(mobile_number, ''), coalesce(row_data->>'mobileNumber', '')) end,
          linkedin_url = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'linkedinUrl', ''), linkedin_url) else coalesce(nullif(linkedin_url, ''), coalesce(row_data->>'linkedinUrl', '')) end,
          title = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'title', ''), title) else coalesce(nullif(title, ''), coalesce(row_data->>'title', '')) end,
          seniority = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'seniority', ''), seniority) else coalesce(nullif(seniority, ''), coalesce(row_data->>'seniority', '')) end,
          department = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'department', ''), department) else coalesce(nullif(department, ''), coalesce(row_data->>'department', '')) end,
          city = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'city', ''), city) else coalesce(nullif(city, ''), coalesce(row_data->>'city', '')) end,
          state = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'state', ''), state) else coalesce(nullif(state, ''), coalesce(row_data->>'state', '')) end,
          country = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'country', ''), country) else coalesce(nullif(country, ''), coalesce(row_data->>'country', '')) end,
          location = case when merge_mode_value = 'overwrite' then coalesce(nullif(location_value, ''), location) else coalesce(nullif(location, ''), coalesce(location_value, '')) end,
          company_id = coalesce(company_id_value, company_id),
          all_data = case when merge_mode_value = 'overwrite' then all_data || coalesce(row_data->'raw', '{}'::jsonb) else coalesce(row_data->'raw', '{}'::jsonb) || all_data end,
          updated_at = now()
        where id = prospect_id_value;
      end if;
      duplicate_count := duplicate_count + 1;$repl$;
begin
  select pg_get_functiondef('public.import_prospect_batch_v2(text,text,jsonb)'::regprocedure) into v_definition;

  if position('merge_mode_value' in v_definition) > 0 then
    return;
  end if;

  v_count := (length(v_definition) - length(replace(v_definition, v_declare_anchor, ''))) / length(v_declare_anchor);
  if v_count <> 1 then
    raise exception 'import_prospect_batch_v2 declare anchor appears % times, expected exactly 1', v_count;
  end if;
  v_count := (length(v_definition) - length(replace(v_definition, v_lookup_anchor, ''))) / length(v_lookup_anchor);
  if v_count <> 1 then
    raise exception 'import_prospect_batch_v2 loop anchor appears % times, expected exactly 1', v_count;
  end if;
  v_count := (length(v_definition) - length(replace(v_definition, v_merge_anchor, ''))) / length(v_merge_anchor);
  if v_count <> 1 then
    raise exception 'import_prospect_batch_v2 merge anchor appears % times, expected exactly 1', v_count;
  end if;

  v_definition := replace(v_definition, v_declare_anchor, v_declare_replacement);
  v_definition := replace(v_definition, v_lookup_anchor, v_lookup_replacement);
  v_definition := replace(v_definition, v_merge_anchor, v_merge_replacement);
  execute v_definition;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- The three modes, asserted as the expressions the function now runs rather
-- than by importing anything: a live fire would have to create a prospect, a
-- list and an import to say what these four rows say.
do $verify$
declare
  v_stored text;
  v_incoming text;
  v_mode text;
  v_result text;
begin
  foreach v_mode in array array['enrich', 'overwrite'] loop
    foreach v_stored in array array['', 'Head of Talent'] loop
      foreach v_incoming in array array['', 'VP Talent'] loop
        v_result := case when v_mode = 'overwrite'
          then coalesce(nullif(v_incoming, ''), v_stored)
          else coalesce(nullif(v_stored, ''), coalesce(v_incoming, '')) end;

        -- Neither mode may ever blank a value the file did not supply.
        if v_stored <> '' and v_incoming = '' and v_result <> v_stored then
          raise exception 'mode % blanked a stored value', v_mode;
        end if;
        -- enrich never replaces something already there.
        if v_mode = 'enrich' and v_stored <> '' and v_result <> v_stored then
          raise exception 'enrich overwrote %', v_stored;
        end if;
        -- overwrite always takes what the file supplied.
        if v_mode = 'overwrite' and v_incoming <> '' and v_result <> v_incoming then
          raise exception 'overwrite ignored %', v_incoming;
        end if;
        -- Both fill a blank.
        if v_stored = '' and v_incoming <> '' and v_result <> v_incoming then
          raise exception 'mode % left a blank unfilled', v_mode;
        end if;
      end loop;
    end loop;
  end loop;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'imports'
      and column_name = 'merge_mode' and column_default like '%enrich%'
  ) then
    raise exception 'imports.merge_mode is missing or does not default to enrich';
  end if;

  if position($$merge_mode_value = 'overwrite'$$ in
      pg_get_functiondef('public.import_prospect_batch_v2(text,text,jsonb)'::regprocedure)) = 0 then
    raise exception 'import_prospect_batch_v2 was not rewritten';
  end if;

  raise notice 'people import merge modes: enrich/overwrite/skip in force, default enrich';
end;
$verify$;
